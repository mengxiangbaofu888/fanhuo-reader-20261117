/// 书源运行时：懒加载 11.5 MB 的书源包、持有「开关状态」、提供 HTTP 抓取。
///
/// 为什么是单例：`HomeShell` 在 `initState` 里就要拿到仓库来建页面，
/// 而 11.5 MB 的 jsonDecode 不能放在 `initState`（会卡首帧）。
/// 所以这里做三件事：
///   1. `instance` 立刻可用，`repository` 先给一个空仓库，后台解完再替换
///   2. 解包放在 isolate 里（超过 2 MB 才起），不抢首帧
///   3. 开关状态用 SharedPreferences 存域名，不存整条规则
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../offline_cache.dart';
import 'book_source.dart';
import 'fanqie_settings.dart';
import 'gbk_tables.dart';
import 'rule_engine.dart';
import 'source_novel_repository.dart';
import 'source_repository.dart';

class FanhuoSourceBootstrap {
  FanhuoSourceBootstrap._();

  static final FanhuoSourceBootstrap instance = FanhuoSourceBootstrap._();

  static const _assetPath = 'assets/fanhuo/bookSources-merged.json';
  static const _disabledKey = 'fanhuo.disabledSources';
  static const _settingsKey = 'fanhuo.readerSettings';

  BookSourceRepository _repository = BookSourceRepository.parse('[]');
  BookSourceRepository get repository => _repository;

  FanqieReaderSettings _settings = const FanqieReaderSettings();
  FanqieReaderSettings get settings => _settings;

  final _loaded = Completer<void>();
  Future<void> get ready => _loaded.future;

  /// 书源 → 上游 Novel 的适配器。第一次访问时创建（要 OfflineCacheStore 先 load）。
  FanhuoSourceRepository? _novelRepository;
  FanhuoSourceRepository? get novelRepository => _novelRepository;

  bool _started = false;
  final Set<String> _disabled = <String>{};

  /// 启动：读设置 + 后台解书源包。重复调用无副作用。
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _disabled
        ..clear()
        ..addAll(prefs.getStringList(_disabledKey) ?? const []);
      _settings = FanqieReaderSettings.fromRecord(prefs.getString(_settingsKey));

      final raw = await rootBundle.loadString(_assetPath);
      // 11.5 MB 的解析放 isolate，避免卡首帧。
      final parsed = raw.length < 2 * 1024 * 1024
          ? BookSourceRepository.parse(raw)
          : await compute(_parseInIsolate, raw);
      _repository = _filterDisabled(parsed);

      // 书源 → 上游 Novel 适配器。离线缓存要先 load()，否则 saveBook 会用空索引。
      final cache = OfflineCacheStore();
      await cache.load();
      _cache = cache;
      _novelRepository = FanhuoSourceRepository(
        sources: _repository,
        fetch: fetch,
        cache: cache,
      );

      if (!_loaded.isCompleted) _loaded.complete();
    } catch (error, stack) {
      // 书源包坏了不能让 App 起不来：保留空仓库，上层显示「没有可用书源」。
      if (!_loaded.isCompleted) _loaded.completeError(error, stack);
    }
  }

  OfflineCacheStore? _cache;
  OfflineCacheStore? get cache => _cache;

  /// 顶层函数，`compute` 要求可序列化入口。
  static BookSourceRepository _parseInIsolate(String raw) =>
      BookSourceRepository.parse(raw);

  BookSourceRepository _filterDisabled(BookSourceRepository base) {
    if (_disabled.isEmpty) return base;
    final kept = [
      for (final p in base.all)
        if (!_disabled.contains(_keyOf(p.source))) p,
    ];
    return BookSourceRepository.fromPacked(kept);
  }

  /// 开关一条书源。返回是否保存成功。
  Future<bool> setEnabled(BookSource source, bool enabled) async {
    final key = _keyOf(source);
    if (enabled) {
      _disabled.remove(key);
    } else {
      _disabled.add(key);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_disabledKey, _disabled.toList());
      _repository = _filterDisabled(_repository);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveSettings(FanqieReaderSettings next) async {
    _settings = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_settingsKey, next.toRecord());
    } catch (_) {
      // 存不进去不影响本次会话
    }
  }

  static String _keyOf(BookSource source) =>
      source.url.replaceAll(RegExp(r'/+$'), '').toLowerCase();

  /// HTTP 抓取。书源站五花八门，这里只保证「拿到正确编码的文本」：
  /// 关证书校验（很多小站证书过期）、带浏览器 UA、跟随重定向、15 秒超时、
  /// 按响应头 / 声明 / 内容嗅探三级判定 charset（GBK 站点靠这个）。
  Future<String> fetch(SearchRequest request, {String? header}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (cert, host, port) => true;
    const ua =
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    try {
      final uri = Uri.parse(request.url);
      final req = await client.openUrl(request.method, uri);
      req.headers.set(HttpHeaders.userAgentHeader, ua);
      req.headers.set('Accept', 'text/html,application/xhtml+xml,*/*');
      req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
      final extra = _extraHeaders(header);
      for (final entry in extra.entries) {
        req.headers.set(entry.key, entry.value);
      }
      final bodyText = request.body;
      if (bodyText != null && request.method.toUpperCase() != 'GET') {
        final bytes = utf8.encode(bodyText);
        req.headers.contentLength = bytes.length;
        req.add(bytes);
      }
      final response = await req.close().timeout(const Duration(seconds: 15));
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
        if (chunks.length > 4 * 1024 * 1024) break; // 单页 4 MB 上限
      }
      return _decode(chunks, response, request.charset);
    } finally {
      client.close(force: true);
    }
  }

  /// 书源的 `header` 字段是 JSON 字符串；写坏了就当没写。
  static Map<String, String> _extraHeaders(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value.toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  static String _decode(
    List<int> bytes,
    HttpClientResponse response,
    String? declared,
  ) {
    final charset = (response.headers.contentType?.charset ?? declared ?? '')
        .toLowerCase();
    if (charset.contains('gb')) return decodeGbk(bytes);
    if (charset.contains('big5')) {
      // Big5 也没内置，先按 UTF-8 尽力解，失败回落 GBK 表（港台站多半是 UTF-8）
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } catch (_) {
        return decodeGbk(bytes);
      }
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      // 没有声明 charset 时用内容嗅探：像 GBK 就按 GBK 解
      return looksLikeGbk(bytes)
          ? decodeGbk(bytes)
          : utf8.decode(bytes, allowMalformed: true);
    }
  }
}
