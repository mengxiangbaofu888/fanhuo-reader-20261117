/// QuickJS 引擎池：给子集解释器跑不了的书源 JS 兜底。
///
/// 为什么要有池：`flutter_js` 每次 `JavascriptRuntime()` 都要建一个 QuickJS 实例，
/// 冷启动几十毫秒；而搜索是 8 路并发、每条源可能触发好几段脚本。
/// 每次新建会明显拖慢，所以复用 2 个实例轮流用。
///
/// 安全策略（书源是陌生人写的脚本）：
///   1. 只注入 [buildJsGlue] 里那几个函数，没别的全局
///   2. 网络请求过 [HostAllowList]，不在白名单直接抛
///   3. 单次执行 5 秒硬超时，超时就丢弃该实例（QuickJS 没法安全中断）
///   4. 单次执行最多 16 个网络请求
///
/// 平台：Android / iOS / macOS / Windows / Linux 都支持；单元测试环境下
/// 没有原生库，[JsEnginePool.available] 会是 false，调用方回落成「不支持」。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';

import 'js_host_api.dart';
import 'multi_source_search.dart';

/// 引擎执行失败（和「超出子集」区分开）。
class JsEngineFailure implements Exception {
  const JsEngineFailure(this.message);
  final String message;
  @override
  String toString() => 'JsEngineFailure: $message';
}

/// 单个引擎实例的包装：记录它的回调是否已注册、是否还可用。
///
/// ⚠️ 两条硬约束（踩过，别再犯）：
///   1. `flutter_js` 的桥接回调是**同步**的（FFI 直调），
///      返回 `Future` 会被当成值，最后在 `"'$result';"` 那里炸成
///      `type 'List<dynamic>' is not a subtype of type 'String'`。
///      —— 第一版就是 `async` 回调，自检直接报这个错。
///   2. 回调返回值会被插进 `"'$result';"`，所以**只能返回 String**，
///      不能返回 null / List / Map。
/// 因此宿主 API 在这里只能给「同步值」，异步的 `java.ajax` 走 Promise 桥（见 [_nativeCallJs]）。
class _Worker {
  _Worker(this.runtime) {
    runtime.onMessage('__host__', (dynamic args) {
      // ⚠️ 铁律：**桥上的参数和返回值都必须是 String**。
      //
      // Android 走的是 `QuickJsRuntime2`，它的桥接这样写：
      //   return channelFunctions[channelName]!.call(jsonDecode(message));
      // 而 `_jsToDart` 把 JS 数组转成 `List<dynamic>` 直接塞进 FFI 返回值通道，
      // 于是 JS 传一个数组过来就会炸：
      //   type 'List<dynamic>' is not a subtype of type 'String'
      //
      // 所以 JS 侧一律 `JSON.stringify([...])` 传字符串，这里解成 List。
      // 兼容老路径：万一是 List 也认。
      final dynamic decoded = args is String ? _tryDecode(args) : args;
      final list = decoded is List ? decoded : <dynamic>[decoded];
      final id = list.isNotEmpty ? list[0]?.toString() ?? '' : '';
      final method = list.length > 1 ? list[1]?.toString() ?? '' : '';
      final params = list.length > 2 ? list[2] : null;
      if (method.startsWith('__req__')) {
        // 异步请求：立刻返回空串，结果稍后通过 __jsResolve 回填
        unawaited(_request(id, method.substring(7), params));
        return '';
      }
      final value = _dispatchSync(method, params);
      // ⚠️ 不能在这里再调 `runtime.evaluate` —— 我们正处在桥的**同步回调**里，
      // QuickJsRuntime2 会拒绝重入（或静默失败），于是 `__nativeResolve`
      // 永远跑不到，JS 那边拿到的就是 `instance of 'Future<dynamic>'`。
      // 改成：把结果塞进待办队列，由 [takePending] 在**脚本执行之外**统一回填。
      _pending.add('if (window.__nativeResolve) '
          'window.__nativeResolve(${_jsString(id)}, ${_jsString(value)});');
      // 必须返回 String
      return value;
    });
  }

  /// 桥上传过来的是 JSON 字符串；解析失败就当成单个参数。
  static dynamic _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  final JavascriptRuntime runtime;
  JsHostApi? host;
  DateTime lastUsed = DateTime.now();
  bool broken = false;

  /// 待回填的 JS 语句（宿主回调不能在桥里执行 evaluate，先攒着）。
  final List<String> _pending = [];

  /// 在**脚本执行之外**把攒下的回填语句跑掉。返回跑了几条。
  int takePending() {
    if (_pending.isEmpty) return 0;
    final batch = List<String>.from(_pending);
    _pending.clear();
    for (final snippet in batch) {
      try {
        runtime.evaluate(snippet);
      } catch (_) {
        // 实例可能已经被回收
      }
    }
    return batch.length;
  }

  static String _jsString(String value) {
    // 用 JSON 编码当 JS 字符串字面量，避开手写转义
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    return '"$escaped"';
  }

  /// 同步宿主 API 派发。只有这些能在这里直接返回。
  ///
  /// `ajax` / `getUrl` / `post` / `connect` 是异步的，不在这个表里 ——
  /// 它们由 `_nativeCallJs` 生成的 Promise 走 [_request] 单独处理。
  String _dispatchSync(String method, Object? params) {
    final api = host;
    if (api == null) return '';
    final args = params is List ? params : (params == null ? const [] : [params]);
    String arg(int index) =>
        index < args.length ? (args[index]?.toString() ?? '') : '';
    try {
      switch (method) {
        case 'put':
          api.put(arg(0), arg(1));
          return '';
        case 'getvar':
          return api.getVar(arg(0));
        case 'getString':
          return api.getString(arg(0));
        case 'timeFormat':
          // ⚠️ 胶水里 `pattern ? String(pattern) : null` 传的是 JS 的 null，
          // 过桥后 args = [ts, null]，`args.length > 1` 成立，
          // arg(1) 返回 ''（空串）→ timeFormat(ts, '') → _format(t, '') → **空字符串**。
          // 于是书源里所有 `java.timeFormat(x)` 都返回空，
          // 引擎自检也卡在这里（期望 2026/11/18 09:05，实际空）。
          // 空串 / null 一律当「用默认格式」。
          final fmt = args.length > 1 ? arg(1) : '';
          return api.timeFormat(arg(0), fmt.isEmpty ? null : fmt);
        case 'base64Decode':
          return JsHostApi.base64Decode(arg(0));
        case 'base64Encode':
          return JsHostApi.base64Encode(arg(0));
        case 'md5':
          return JsHostApi.md5Encode(arg(0));
        case 'md5_16':
          final digest = JsHostApi.md5Encode(arg(0));
          return digest.length == 32 ? digest.substring(8, 24) : digest;
        case 'log':
          return JsHostApi.log(arg(0));
        default:
          return '';
      }
    } catch (_) {
      // 脚本侧的异常不该把引擎带走，返回空串让它自己判空
      return '';
    }
  }

  /// 异步请求：Dart 侧拿到结果后调用 JS 的 resolve 回调。
  Future<void> _request(String reqId, String method, Object? params) async {
    final api = host;
    String result = '';
    if (api != null) {
      final args = params is List ? params : (params == null ? const [] : [params]);
      String arg(int index) =>
          index < args.length ? (args[index]?.toString() ?? '') : '';
      try {
        result = switch (method) {
          'ajax' => await api.ajax(arg(0)),
          'getUrl' => await api.getUrl(arg(0)),
          'post' => await api.post(arg(0), arg(1)),
          'connect' => await api.connect(arg(0)),
          _ => '',
        };
      } catch (_) {
        result = '';
      }
    }
    try {
      runtime.evaluate(
        'if (window.__jsResolve) window.__jsResolve('
        '${_jsString(reqId)}, ${_jsString(result)});',
      );
    } catch (_) {
      // 实例可能已经超时被回收，忽略
    }
    // 网络结果回来后，把宿主回调攒下的回填语句一起跑掉
    takePending();
  }
}

/// 引擎池。默认 2 个实例。
class JsEnginePool {
  JsEnginePool({int size = 2}) : _size = size < 1 ? 1 : size;

  final int _size;
  final List<_Worker> _workers = [];
  bool _initialized = false;
  bool _available = true;
  String _unavailableReason = '';

  /// 原生库不可用时为 false（测试环境、或平台不支持）。
  bool get available => _available;
  String get unavailableReason => _unavailableReason;

  Future<void> _ensure() async {
    if (_initialized) return;
    _initialized = true;
    try {
      for (var i = 0; i < _size; i++) {
        _workers.add(_Worker(getJavascriptRuntime()));
      }
    } catch (error) {
      _available = false;
      _unavailableReason = '$error';
      _workers.clear();
    }
  }

  /// 执行一段脚本。
  ///
  /// [glue] 是 [buildJsGlue] 的产物，每个实例只需注入一次。
  /// [globals] 是 `result` / `baseUrl` / `key` 这些脚本可见的变量。
  Future<String> run(
    String script, {
    required JsRuntimeContext context,
    required Map<String, String> globals,
  }) async {
    await _ensure();
    if (!_available || _workers.isEmpty) {
      throw JsEngineFailure('JS 引擎不可用：$_unavailableReason');
    }
    final worker = _workers.reduce(
      (a, b) => a.lastUsed.isBefore(b.lastUsed) && !a.broken ? a : b,
    );
    if (worker.broken) {
      throw const JsEngineFailure('JS 引擎实例已损坏');
    }
    worker
      ..host = JsHostApi(context)
      ..lastUsed = DateTime.now();
    try {
      final runtime = worker.runtime;
      // 每次执行都重装胶水：脚本少、代价几十毫秒，换来实例之间不串味
      final glueResult = runtime.evaluate(buildJsGlue());
      if (glueResult.isError) {
        throw JsEngineFailure('胶水注入失败：${glueResult.stringResult}');
      }
      final preludeResult = runtime.evaluate(_prelude(globals));
      if (preludeResult.isError) {
        throw JsEngineFailure('全局变量注入失败：${preludeResult.stringResult}');
      }
      // 第一步：同步求值。异步桥（Promise）在 QuickJS 上不一定被 await，
      // 所以先拿同步结果；需要网络的脚本再走第二步。
      //
      // ⚠️ 包一层 IIFE：第二步会**重复执行同一段脚本**，
      // 如果脚本里是 `var id = ...`，第二次会报「已声明」。
      // 包进函数作用域后每次都是全新的局部变量，可以安全重跑。
      final wrapped = '(function(){\n$script\n})()';
      var syncResult = runtime.evaluate(wrapped);
      if (syncResult.isError) {
        throw JsEngineFailure(_clean(syncResult));
      }
      var syncText = syncResult.stringResult;

      // ⚠️ 同步宿主 API 的结果也是在桥回调里**塞队列**的（不能重入 evaluate），
      // 所以第一次执行完，`__nativeResolve` 还没跑，`sendMessage` 拿到的是 null。
      // 这里补一轮：先把队列跑掉，再重新执行脚本，同步 API 就能拿到真值。
      // 桥接自检报「实际 null」就是漏了这一步。
      if (worker.takePending() > 0) {
        _drainMicrotasks(runtime);
        final again = runtime.evaluate(wrapped);
        if (again.isError) throw JsEngineFailure(_clean(again));
        syncText = again.stringResult;
      }

      // 第二步：脚本返回的不是值，说明它在等宿主异步回填。
      //
      // QuickJsRuntime2 的 evaluateAsync **不会**等 Dart 的 Future
      // （自检里看到的就是 `实际 instance of 'Future<dynamic>'`），
      // 所以这里手写轮询：
      //   1. 跑一遍已攒的宿主回填语句
      //   2. 再跑 microtask 队列
      //   3. 重新执行脚本，看这次能不能拿到真值
      // 网络没回来之前每一轮都是空，循环等到超时为止。
      if (syncText.isEmpty ||
          syncText.contains('[object Promise]') ||
          syncText.contains("instance of 'Future")) {
        final deadline = DateTime.now().add(const Duration(seconds: 6));
        while (DateTime.now().isBefore(deadline)) {
          // 等一下，让 Dart 的 HTTP 有机会完成
          await Future<void>.delayed(const Duration(milliseconds: 25));
          worker.takePending();
          _drainMicrotasks(runtime);
          final retry = runtime.evaluate(wrapped);
          if (retry.isError) throw JsEngineFailure(_clean(retry));
          final text = retry.stringResult;
          if (text.isNotEmpty &&
              !text.contains('[object Promise]') &&
              !text.contains("instance of 'Future")) {
            return text;
          }
        }
        // 等超时了还没值：把 Promise 自己序列化出来，让上层看得见
        return _describePromise(runtime, wrapped);
      }
      return syncText;
    } on TimeoutException {
      // QuickJS 没法安全中断长脚本，只能把这个实例废掉重建
      worker.broken = true;
      unawaited(_replace(worker));
      throw const JsEngineFailure('脚本执行超时（5 秒）');
    } finally {
      worker.lastUsed = DateTime.now();
    }
  }

  /// 把 QuickJS 的报错洗成人能看的：去掉堆栈，只留第一行。
  static String _clean(JsEvalResult result) =>
      result.stringResult.split('\n').first.trim();

  /// 跑一遍 QuickJS 的 microtask 队列，让 Promise 有机会完成。
  void _drainMicrotasks(JavascriptRuntime runtime) {
    try {
      runtime.executePendingJob();
    } catch (_) {
      // 引擎没暴露这个能力就算了
    }
  }

  /// 同步与 await 都拿不到值时，把 Promise 的状态和已 resolve 的值打出来，
  /// 让「引擎不能用」变成一条能看懂的信息。
  String _describePromise(JavascriptRuntime runtime, String script) {
    try {
      final probe = runtime.evaluate('''
(function () {
  try {
    var r = (function () { return ($script); })();
    if (!r || typeof r.then !== 'function') return 'non-promise:' + String(r);
    var state = 'pending';
    var val = '';
    r.then(function (v) { state = 'fulfilled'; val = String(v); },
           function (e) { state = 'rejected'; val = String(e); });
    return 'promise:' + state + ':' + val;
  } catch (e) { return 'error:' + String(e); }
})()
''');
      return probe.stringResult;
    } catch (error) {
      return 'promise-probe-failed:$error';
    }
  }

  Future<void> _replace(_Worker old) async {
    final index = _workers.indexOf(old);
    if (index < 0) return;
    try {
      old.runtime.dispose();
    } catch (_) {}
    if (_available) {
      try {
        _workers[index] = _Worker(getJavascriptRuntime());
      } catch (_) {
        _workers.removeAt(index);
      }
    }
  }

  /// 注入全局变量。
  static String _prelude(Map<String, String> globals) {
    final buffer = StringBuffer();
    for (final entry in globals.entries) {
      final value = entry.value
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"')
          .replaceAll('\n', r'\n')
          .replaceAll('\r', r'\r');
      buffer.writeln('var ${entry.key} = "$value";');
    }
    // 把 JS 侧调用转成一条 channel 消息，Dart 侧返回后再 resolve
    buffer.writeln(r'''
var __nativeSeq = 0;
var __nativePending = {};
var __jsReqSeq = 0;
var __jsReqResolvers = {};

// ⚠️ 桥上只能传字符串：Android 的 QuickJsRuntime2 会把 Dart 数组当
// List<dynamic> 塞进 FFI 返回值通道，直接抛
//   type 'List<dynamic>' is not a subtype of type 'String'
// 所以一律 JSON.stringify 成字符串再过去，Dart 侧再 jsonDecode。
function __nativeCall(method, params) {
  var id = String(__nativeSeq++);
  var r = sendMessage('__host__', JSON.stringify([id, method, params]));
  if (r === null || r === undefined) return '';
  if (typeof r !== 'string') return String(r);
  return r;
}

// 给 Dart 侧补调用的钩子（Dart 同步回调里会再调一次 __nativeResolve）
function __nativeResolve(id, value) {
  var cb = __nativePending[id];
  if (cb) { delete __nativePending[id]; cb(value); }
}

// 异步请求：返回 Promise，Dart 那边拿到结果后调 __jsResolve
function __nativeRequest(method, params) {
  var id = String(__jsReqSeq++);
  return new Promise(function (resolve) {
    __jsReqResolvers[id] = resolve;
    sendMessage('__host__', JSON.stringify([id, '__req__' + method, params]));
  });
}
function __jsResolve(id, value) {
  var cb = __jsReqResolvers[id];
  if (cb) { delete __jsReqResolvers[id]; cb(value); }
}

function __native_ajax(u) { return __nativeRequest('ajax', [u]); }
function __native_getUrl(u) { return __nativeRequest('getUrl', [u]); }
function __native_post(u, b) { return __nativeRequest('post', [u, b]); }
function __native_connect(u) { return __nativeRequest('connect', [u]); }
function __native_put(k, v) { return __nativeCall('put', [k, v]); }
function __native_getvar(k) { return __nativeCall('getvar', [k]); }
function __native_getString(p) { return __nativeCall('getString', [p]); }
function __native_timeFormat(t, p) { return __nativeCall('timeFormat', [t, p]); }
function __native_base64Decode(s) { return __nativeCall('base64Decode', [s]); }
function __native_base64Encode(s) { return __nativeCall('base64Encode', [s]); }
function __native_md5(s) { return __nativeCall('md5', [s]); }
function __native_log(s) { return __nativeCall('log', [s]); }
''');
    return buffer.toString();
  }

  void dispose() {
    for (final worker in _workers) {
      try {
        worker.runtime.dispose();
      } catch (_) {}
    }
    _workers.clear();
    _initialized = false;
  }
}

/// 全局单例：书源搜索共用一套引擎，避免反复建实例。
final JsEnginePool jsEnginePool = JsEnginePool();

/// 给上层用的便捷入口：跑一段书源 JS，失败返回 null。
Future<String?> tryRunBookSourceJs(
  String script, {
  required SourceFetcher fetch,
  required HostAllowList allowList,
  String result = '',
  String baseUrl = '',
  String key = '',
}) async {
  try {
    return await jsEnginePool.run(
      script,
      context: JsRuntimeContext(
        fetch: fetch,
        allowList: allowList,
        result: result,
        baseUrl: baseUrl,
        key: key,
      ),
      globals: {'result': result, 'baseUrl': baseUrl, 'key': key, 'src': baseUrl},
    );
  } catch (_) {
    return null;
  }
}
