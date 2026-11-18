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
class _Worker {
  _Worker(this.runtime) {
    runtime.onMessage('__host__', (dynamic args) async {
      final list = args is List ? args : [args];
      final id = list.isNotEmpty ? list[0]?.toString() ?? '' : '';
      final method = list.length > 1 ? list[1]?.toString() ?? '' : '';
      final params = list.length > 2 ? list[2] : null;
      final result = await _dispatch(method, params);
      runtime.evaluate(
        'window.__nativeResolve(${_jsString(id)}, ${_jsString(result)})',
      );
      return null;
    });
  }

  final JavascriptRuntime runtime;
  JsHostApi? host;
  DateTime lastUsed = DateTime.now();
  bool broken = false;

  static String _jsString(String value) {
    // 用 JSON 编码当 JS 字符串字面量，避开手写转义
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    return '"$escaped"';
  }

  Future<String> _dispatch(String method, Object? params) async {
    final api = host;
    if (api == null) return '';
    final args = params is List ? params : (params == null ? const [] : [params]);
    String arg(int index) =>
        index < args.length ? (args[index]?.toString() ?? '') : '';
    try {
      switch (method) {
        case 'ajax':
          return await api.ajax(arg(0));
        case 'getUrl':
          return await api.getUrl(arg(0));
        case 'post':
          return await api.post(arg(0), arg(1));
        case 'connect':
          return await api.connect(arg(0));
        case 'put':
          api.put(arg(0), arg(1));
          return '';
        case 'getvar':
          return api.getVar(arg(0));
        case 'getString':
          return api.getString(arg(0));
        case 'timeFormat':
          return api.timeFormat(arg(0), args.length > 1 ? arg(1) : null);
        case 'base64Decode':
          return JsHostApi.base64Decode(arg(0));
        case 'base64Encode':
          return JsHostApi.base64Encode(arg(0));
        case 'md5':
          return JsHostApi.md5Encode(arg(0));
        case 'log':
          return JsHostApi.log(arg(0));
        default:
          return '';
      }
    } catch (error) {
      // 脚本侧的异常不该把引擎带走，返回空串让它自己判空
      return '';
    }
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
      runtime.evaluate(buildJsGlue());
      runtime.evaluate(_prelude(globals));
      final result = await runtime
          .evaluateAsync(script)
          .timeout(const Duration(seconds: 5));
      if (result.isError) {
        throw JsEngineFailure(result.stringResult);
      }
      return result.stringResult;
    } on TimeoutException {
      // QuickJS 没法安全中断长脚本，只能把这个实例废掉重建
      worker.broken = true;
      unawaited(_replace(worker));
      throw const JsEngineFailure('脚本执行超时（5 秒）');
    } finally {
      worker.lastUsed = DateTime.now();
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
function __nativeCall(method, params) {
  var id = String(__nativeSeq++);
  sendMessage('__host__', [id, method, params]);
  return '';
}
function __nativeResolve(id, value) {
  var cb = __nativePending[id];
  if (cb) { delete __nativePending[id]; cb(value); }
}
function __native_ajax(u) { return __nativeCall('ajax', [u]); }
function __native_getUrl(u) { return __nativeCall('getUrl', [u]); }
function __native_post(u, b) { return __nativeCall('post', [u, b]); }
function __native_connect(u) { return __nativeCall('connect', [u]); }
function __native_put(k, v) { __nativeCall('put', [k, v]); }
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
