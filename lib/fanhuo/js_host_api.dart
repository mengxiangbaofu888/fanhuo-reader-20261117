/// 书源 JS 的宿主 API。
///
/// 书源脚本里的 `java.ajax` / `java.get` / `base64Decode` / `md5` 这些**不是 JS 标准**，
/// 是「阅读」App 用 Rhino 塞给脚本的 Java 对象。换成 QuickJS 之后，
/// 这些名字得我们自己在 Dart 侧实现并注入 JS 全局。
///
/// 这个文件只负责**实现**；注入和调用隔离在 [JsEngine] 里。
///
/// 安全边界（很重要，书源是陌生人写的脚本）：
///   1. 网络只允许当前书源域名 + 书页域名（[HostAllowList]）
///   2. 单次请求超时 10 秒、单页 4 MB 上限
///   3. 拿不到文件系统、拿不到 Android 反射、拿不到 Dart 对象
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'multi_source_search.dart';
import 'rule_engine.dart';

/// 域名白名单。
///
/// 书源脚本能请求哪些域，由「当前处理的是哪个源、哪个书页」决定。
/// 允许子域（`a.example.com` 命中 `example.com`）。
class HostAllowList {
  HostAllowList(Iterable<String> seeds) {
    for (final seed in seeds) {
      final host = _hostOf(seed);
      if (host != null) _allowed.add(host);
    }
  }

  final Set<String> _allowed = {};

  static String? _hostOf(String urlOrHost) {
    if (urlOrHost.isEmpty) return null;
    final trimmed = urlOrHost.trim();
    if (trimmed.contains('/')) {
      try {
        return Uri.parse(trimmed).host.toLowerCase();
      } catch (_) {
        return null;
      }
    }
    return trimmed.toLowerCase();
  }

  void allow(String urlOrHost) {
    final host = _hostOf(urlOrHost);
    if (host != null && host.isNotEmpty) _allowed.add(host);
  }

  bool allows(String url) {
    try {
      final host = Uri.parse(url).host.toLowerCase();
      if (host.isEmpty) return false;
      for (final allowed in _allowed) {
        if (host == allowed || host.endsWith('.$allowed')) return true;
      }
      // 书源站经常把图片/接口放 CDN，同一主域的后缀也放行
      for (final allowed in _allowed) {
        final parts = allowed.split('.');
        if (parts.length >= 2) {
          final root = parts.sublist(parts.length - 2).join('.');
          if (host.endsWith('.$root') || host == root) return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Set<String> get hosts => Set.unmodifiable(_allowed);
}

/// 单次脚本执行可用的 KV 存储（对应阅读的 `java.put` / `java.get`）。
class JsCookieJar {
  final Map<String, String> _values = {};
  final Map<String, List<String>> _cookies = {};

  String? get(String key) => _values[key];
  void put(String key, Object? value) => _values[key] = value?.toString() ?? '';

  List<String> cookiesFor(String url) {
    try {
      final host = Uri.parse(url).host;
      return _cookies[host] ?? const [];
    } catch (_) {
      return const [];
    }
  }

  void setCookies(String url, Iterable<String> setCookieHeaders) {
    try {
      final host = Uri.parse(url).host;
      _cookies.putIfAbsent(host, () => []).addAll(setCookieHeaders);
    } catch (_) {
      // 非法 URL 就当没收到
    }
  }
}

/// 一次脚本执行的上下文。
class JsRuntimeContext {
  JsRuntimeContext({
    required this.fetch,
    required this.allowList,
    this.cookieJar,
    this.result = '',
    this.baseUrl = '',
    this.key = '',
    DateTime? now,
  }) : now = now ?? DateTime.now();

  /// 抓页面。默认实现就是书源搜索用的那个 fetch。
  final SourceFetcher fetch;
  final HostAllowList allowList;
  final JsCookieJar? cookieJar;
  final String result;
  final String baseUrl;
  final String key;

  /// 固定「现在」，方便测试 `java.timeFormat`。
  final DateTime now;

  int requestCount = 0;
  static const maxRequests = 16;
}

/// 宿主 API 的实现集合。每个方法都对应 JS 侧同名函数。
class JsHostApi {
  JsHostApi(this.context);

  final JsRuntimeContext context;

  /// `java.ajax(url)` —— 返回页面文本。失败返回空串（书源脚本习惯判空）。
  Future<String> ajax(String url) async {
    if (context.requestCount >= JsRuntimeContext.maxRequests) {
      throw StateError('单次脚本最多发 ${JsRuntimeContext.maxRequests} 个请求');
    }
    if (!context.allowList.allows(url)) {
      throw StateError('域名不在白名单：${_hostOf(url)}');
    }
    context.requestCount += 1;
    try {
      final text = await context.fetch(SearchRequest(url: url));
      return text;
    } catch (_) {
      return '';
    }
  }

  /// `java.getUrl(url)` 与 ajax 同义。
  ///
  /// 注意：阅读里 `java.get` 有两个重载（HTTP GET 与读 KV），
  /// JS 侧无法按参数类型区分，所以这里把 HTTP 的拆成 `getUrl`，
  /// glue 里对 `java.get` 做参数个数判断。
  Future<String> getUrl(String url) => ajax(url);

  /// `java.post(url, body)`。
  Future<String> post(String url, String body) async {
    if (!context.allowList.allows(url)) {
      throw StateError('域名不在白名单：${_hostOf(url)}');
    }
    if (context.requestCount >= JsRuntimeContext.maxRequests) {
      throw StateError('单次脚本最多发 ${JsRuntimeContext.maxRequests} 个请求');
    }
    context.requestCount += 1;
    try {
      return await context.fetch(
        SearchRequest(url: url, method: 'POST', body: body),
      );
    } catch (_) {
      return '';
    }
  }

  /// `java.connect(url)` —— 只取响应头/状态，这里沿用 ajax。
  Future<String> connect(String url) => ajax(url);

  /// `java.put(key, value)`。
  void put(String key, Object? value) => context.cookieJar?.put(key, value);

  /// `java.get(key)`。
  String getVar(String key) => context.cookieJar?.get(key) ?? '';

  /// `java.getString(path)` —— 从 `java.put` 存的对象里按 JSONPath 取值。
  ///
  /// 只实现书源实际用到的最小子集：`$.a.b` / `$.a[0]` / `$.a.b[2].c`。
  String getString(String path) {
    final raw = context.cookieJar?.get('__json__');
    if (raw == null || raw.isEmpty) return '';
    Object? current;
    try {
      current = jsonDecode(raw);
    } catch (_) {
      return '';
    }
    for (final segment in _pathSegments(path)) {
      if (current == null) return '';
      if (segment is int) {
        if (current is! List || segment >= current.length) return '';
        current = current[segment];
      } else {
        if (current is! Map) return '';
        current = current[segment];
      }
    }
    return current?.toString() ?? '';
  }

  static List<Object> _pathSegments(String path) {
    final out = <Object>[];
    for (final part in path.replaceFirst(RegExp(r'^\$\.?'), '').split('.')) {
      if (part.isEmpty) continue;
      final match = RegExp(r'^([^\[]*)((\[\d+\])*)$').firstMatch(part);
      if (match == null) continue;
      if (match.group(1)!.isNotEmpty) out.add(match.group(1)!);
      for (final index in RegExp(r'\[(\d+)\]').allMatches(match.group(2)!)) {
        out.add(int.parse(index.group(1)!));
      }
    }
    return out;
  }

  /// `java.timeFormat(timestamp)` —— 毫秒/秒时间戳转 `yyyy/MM/dd HH:mm`。
  String timeFormat(Object? timestamp, [String? pattern]) {
    if (timestamp == null) return '';
    var ms = int.tryParse(timestamp.toString()) ?? 0;
    if (ms <= 0) return '';
    // 10 位秒 → 毫秒
    if (ms < 100000000000) ms *= 1000;
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    final p = pattern ?? 'yyyy/MM/dd HH:mm';
    return _format(time, p);
  }

  static String _format(DateTime t, String pattern) {
    final map = {
      'yyyy': t.year.toString().padLeft(4, '0'),
      'MM': t.month.toString().padLeft(2, '0'),
      'dd': t.day.toString().padLeft(2, '0'),
      'HH': t.hour.toString().padLeft(2, '0'),
      'mm': t.minute.toString().padLeft(2, '0'),
      'ss': t.second.toString().padLeft(2, '0'),
    };
    var out = pattern;
    for (final entry in map.entries) {
      out = out.replaceAll(entry.key, entry.value);
    }
    return out;
  }

  /// `base64Decode` / `base64Encode`。
  static String base64Decode(String input) {
    try {
      return utf8.decode(base64.decode(input.trim()));
    } catch (_) {
      return '';
    }
  }

  static String base64Encode(String input) =>
      base64.encode(utf8.encode(input));

  /// `md5(str)` —— 阅读里同时提供 `md5Encode` 与 `md5`。
  static String md5Encode(String input) =>
      crypto.md5.convert(utf8.encode(input)).toString();

  /// `java.toast` / `java.log` 之类：只写 stdout，不弹任何东西。
  static String log(Object? message) {
    // ignore: avoid_print
    print('[js] $message');
    return '';
  }

  static String? _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return null;
    }
  }
}

/// 生成注入到 JS 全局的「胶水代码」。
///
/// 为什么用生成而不是直接在 Dart 里暴露：QuickJS 通过 channel 通信，
/// 每个 Dart 方法要单独注册会非常啰嗦；用一段固定的 JS 把
/// `__native_*` 包装成阅读的 `java.xxx` 名字，脚本不用改一个字。
String buildJsGlue() => r'''
var java = {
  ajax: function (url) { return __native_ajax(String(url)); },
  getUrl: function (url) { return __native_getUrl(String(url)); },
  post: function (url, body) { return __native_post(String(url), String(body)); },
  connect: function (url) { return __native_connect(String(url)); },
  put: function (key, value) { __native_put(String(key), String(value)); },
  get: function (key) {
    // 一个参数：可能是 URL 也可能是 KV 的 key。带协议头就当 URL。
    var s = String(key);
    return /^https?:/i.test(s) ? __native_getUrl(s) : __native_getvar(s);
  },
  getString: function (path) { return __native_getString(String(path)); },
  timeFormat: function (ts, pattern) {
    return __native_timeFormat(String(ts), pattern ? String(pattern) : null);
  },
  log: function (msg) { __native_log(String(msg)); },
  toast: function (msg) { __native_log(String(msg)); },
  longToast: function (msg) { __native_log(String(msg)); }
};

function base64Decode(input) { return __native_base64Decode(String(input)); }
function base64Encode(input) { return __native_base64Encode(String(input)); }
function md5(input) { return __native_md5(String(input)); }
function md5Encode(input) { return __native_md5(String(input)); }
function md5Encode16(input) { return __native_md5(String(input)).substring(8, 24); }

// 书源里常见的「同步请求」写法：包装成可直接用返回值
function ajax(url) { return java.ajax(url); }
function get(url) { return java.getUrl(url); }
function post(url, body) { return java.post(url, body); }
''';
