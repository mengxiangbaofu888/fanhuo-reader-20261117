/// 把「书源搜到的书」接进上游的通用阅读器。
///
/// 上游阅读器只认 `Novel` + `NovelChapter` + `NovelRepository` 三件套：
///   - `NovelRepository.chapters(id)` 拿目录
///   - `NovelRepository.chapterContent(id, chapter)` 拿正文
/// 而书源那边给的是 HTML + 规则。这个文件就是那层适配：
///
///   SearchHit（书源条目） → Novel（上游模型）
///   BookSource + bookUrl  → NovelChapter 列表（现抓目录）
///   NovelChapter          → 正文（现抓 + ruleContent 清洗）
///
/// 关键设计：
///   1. **书籍 id 用负随机数**：上游本地书用负数区间（`isLocalBook`），
///      这里再取一段足够大的负数（-900000000 起），避免和本地书撞。
///   2. **章节 id 用序号**（1 起）：书源站的章节没有稳定 id，
///      用「第几章」当 id 才能让上游的进度记录、缓存、下载都对得上。
///   3. **目录与正文都走离线缓存**：`OfflineCacheStore` 的 saveBook/saveChapter
///      要在 `epoch` 内调用，这里统一从 `cache.epochFor(id)` 取。
///   4. 每本书记住它的「书名 + bookUrl + 书源」，存在 `fanhuo.books`，
///      冷启动后还能从书架里把书取回来。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:shared_preferences/shared_preferences.dart';

import '../catalog.dart';
import '../offline_cache.dart';
import 'app_log.dart';
import 'book_source.dart';
import 'multi_source_search.dart';
import 'rule_engine.dart';
import 'source_repository.dart';

/// 书源书 → 上游 Novel 的映射表。
class FanhuoBookBinding {
  const FanhuoBookBinding({
    required this.novelId,
    required this.title,
    required this.author,
    required this.bookUrl,
    required this.sourceUrl,
    required this.sourceName,
    this.intro,
    this.kind,
    this.coverUrl,
    this.lastChapter,
  });

  final int novelId;
  final String title;
  final String author;
  final String bookUrl;
  final String sourceUrl;
  final String sourceName;
  final String? intro;
  final String? kind;
  final String? coverUrl;
  final String? lastChapter;

  Map<String, Object?> toJson() => {
        'novelId': novelId,
        'title': title,
        'author': author,
        'bookUrl': bookUrl,
        'sourceUrl': sourceUrl,
        'sourceName': sourceName,
        'intro': intro,
        'kind': kind,
        'coverUrl': coverUrl,
        'lastChapter': lastChapter,
      };

  /// 只在内存里用的失败原因：抓目录/正文哪一步断了。
  /// 不写进 JSON（每次现抓才有意义）。
  String? lastError;

  factory FanhuoBookBinding.fromJson(Map<String, dynamic> json) =>
      FanhuoBookBinding(
        novelId: json['novelId'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        bookUrl: json['bookUrl'] as String? ?? '',
        sourceUrl: json['sourceUrl'] as String? ?? '',
        sourceName: json['sourceName'] as String? ?? '',
        intro: json['intro'] as String?,
        kind: json['kind'] as String?,
        coverUrl: json['coverUrl'] as String?,
        lastChapter: json['lastChapter'] as String?,
      );
}

/// 书源 → 上游模型的转换 + 抓取。
class FanhuoSourceRepository extends NovelRepository {
  FanhuoSourceRepository({
    required this.sources,
    required this.fetch,
    required this.cache,
    SharedPreferences? preferences,
  }) : _preferences = preferences;

  final BookSourceRepository sources;
  final SourceFetcher fetch;
  final OfflineCacheStore cache;
  SharedPreferences? _preferences;

  /// 绑定的书：novelId → 书源信息。
  final Map<int, FanhuoBookBinding> _bindings = {};
  bool _loaded = false;

  /// 书架：已收藏的 novelId 集合。存在 `fanhuo.shelf.v1`。
  ///
  /// 为什么单独存：`_bindings` 只是「这本书被打开过」的登记表，
  /// 而书架是用户主动收的。两者语义不同，混在一起会让所有打开过的书
  /// 自动出现在书架里。
  final Set<int> _shelf = {};

  /// 内存里最近一次抓到的目录，避免同一次会话里反复抓。
  final Map<int, List<NovelChapter>> _chapterMemo = {};
  final Map<int, List<String>> _tocUrls = {};

  static const _bindingsKey = 'fanhuo.books.v1';
  static const _shelfKey = 'fanhuo.shelf.v1';

  /// 书籍 id 从 -900000000 起，和上游本地书（负数小值）错开。
  static const int _idBase = -900000000;

  /// 目录最多抓多少页。3000 章、每页 50 章也才 60 页，200 页足够兜住。
  static const int _maxTocPages = 200;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = _preferences ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_bindingsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              final binding = FanhuoBookBinding.fromJson(item);
              if (binding.novelId != 0) _bindings[binding.novelId] = binding;
            }
          }
        }
      } catch (_) {
        // 存坏了就当没有，不影响使用
      }
    }
    _shelf
      ..clear()
      ..addAll(prefs.getIntList(_shelfKey) ?? const []);
  }

  Future<void> _persistShelf() async {
    final prefs = _preferences ??= await SharedPreferences.getInstance();
    await prefs.setIntList(_shelfKey, _shelf.toList(growable: false));
  }

  /// 是否已在书架。
  bool isOnShelf(int novelId) => _shelf.contains(novelId);

  /// 书架里的书（给「我的书源书架」用）。
  Future<List<Novel>> shelfBooks() async {
    await _ensureLoaded();
    return [
      for (final id in _shelf)
        if (_bindings[id] != null) toNovel(_bindings[id]!),
    ];
  }

  /// 加入书架。返回 false 表示本来就在。
  Future<bool> addToShelf(int novelId) async {
    await _ensureLoaded();
    if (!_bindings.containsKey(novelId)) return false;
    if (!_shelf.add(novelId)) return false;
    await _persistShelf();
    return true;
  }

  /// 移出书架。
  Future<bool> removeFromShelf(int novelId) async {
    await _ensureLoaded();
    if (!_shelf.remove(novelId)) return false;
    await _persistShelf();
    return true;
  }

  Future<void> _persist() async {
    final prefs = _preferences ??= await SharedPreferences.getInstance();
    await prefs.setString(
      _bindingsKey,
      jsonEncode([for (final b in _bindings.values) b.toJson()]),
    );
  }

  /// 给一本书分配稳定的负数 id：同一 bookUrl 每次拿到同一个。
  int _idFor(String bookUrl) {
    final existing = _bindings.values
        .where((b) => b.bookUrl == bookUrl)
        .map((b) => b.novelId)
        .firstOrNull;
    if (existing != null) return existing;
    // 用 bookUrl 的稳定哈希落到 [-999999999, -900000001] 区间，
    // 撞了就往回挪，撞满这个区间是不可能的（1 亿个位置）。
    var candidate = _idBase - (bookUrl.hashCode.abs() % 99999999);
    while (_bindings.containsKey(candidate)) {
      candidate -= 1;
    }
    return candidate;
  }

  /// 把一个搜索命中登记成上游可读的书，返回 [Novel]。
  Future<Novel> bind(PackedSource packed, SearchHit hit) async {
    await _ensureLoaded();
    final id = _idFor(hit.bookUrl);
    final binding = FanhuoBookBinding(
      novelId: id,
      title: hit.name,
      author: hit.author ?? '',
      bookUrl: hit.bookUrl,
      sourceUrl: hit.sourceUrl,
      sourceName: hit.sourceName,
      intro: hit.intro,
      kind: hit.kind,
      coverUrl: hit.coverUrl,
      lastChapter: hit.lastChapter,
    );
    _bindings[id] = binding;
    await _persist();
    return toNovel(binding);
  }

  Novel toNovel(FanhuoBookBinding binding) => Novel(
        id: binding.novelId,
        title: binding.title,
        author: binding.author.isEmpty ? '佚名' : binding.author,
        genre: binding.kind ?? binding.sourceName,
        summary: binding.intro ?? '来自「${binding.sourceName}」的书源书籍。',
        colors: _colorsFor(binding.novelId),
        coverUrl: binding.coverUrl,
        lastUpdate: binding.lastChapter,
        chapterCount: 0,
      );

  /// 封面/详情页要的颜色对，用 id 派生，保持稳定。
  static List<Color> _colorsFor(int id) {
    final random = math.Random(id);
    final hue = random.nextDouble() * 360;
    final hsl = HSLColor.fromAHSL(1, hue, 0.28, 0.32);
    return [
      hsl.toColor(),
      HSLColor.fromAHSL(1, (hue + 24) % 360, 0.24, 0.18).toColor(),
    ];
  }

  BookSource? _sourceFor(FanhuoBookBinding binding) {
    for (final p in sources.all) {
      if (p.source.url == binding.sourceUrl) return p.source;
    }
    return null;
  }

  // ───────── NovelRepository 实现 ─────────

  @override
  Future<List<Novel>> list() async {
    await _ensureLoaded();
    return [for (final b in _bindings.values) toNovel(b)];
  }

  @override
  Future<Novel?> find(int id) async {
    await _ensureLoaded();
    final binding = _bindings[id];
    return binding == null ? null : toNovel(binding);
  }

  /// 书源内的搜索就是上游的「搜索」；这里只返回已登记的书，
  /// 真正的多源搜书由 `FanhuoSearchPage` 走 `MultiSourceSearch`。
  @override
  Future<List<Novel>> search(String query) async {
    await _ensureLoaded();
    final key = query.trim().toLowerCase();
    if (key.isEmpty) return list();
    return [
      for (final b in _bindings.values)
        if (b.title.toLowerCase().contains(key) ||
            b.author.toLowerCase().contains(key))
          toNovel(b),
    ];
  }

  @override
  Future<Novel> detail(Novel novel) async {
    await _ensureLoaded();
    final binding = _bindings[novel.id];
    return binding == null ? novel : toNovel(binding);
  }

  /// 抓目录。
  ///
  /// 书源的 `ruleToc` 里 `chapterList` / `chapterName` / `chapterUrl` 是相对
  /// **目录页**的规则；目录页地址在 `ruleBookInfo.tocUrl`（没有就用书页本身）。
  @override
  Future<List<NovelChapter>> chapters(int id) async {
    await _ensureLoaded();
    final memo = _chapterMemo[id];
    if (memo != null) return memo;

    final binding = _bindings[id];
    if (binding == null) return const [];
    final source = _sourceFor(binding);
    if (source == null) {
      throw const FormatException('这本书的来源书源已被删除或关闭');
    }

    final tocUrl = await _resolveTocUrl(source, binding);
    final rule = source.tocRule;
    final listRule = rule['chapterList'];
    if (listRule == null) {
      binding.lastError = '这个书源没有目录规则（ruleToc.chapterList）';
      throw FormatException(binding.lastError!);
    }

    final names = <String>[];
    final urls = <String>[];
    final visitedPages = <String>{};
    var pageUrl = tocUrl;

    // ── 分页抓全 ──
    // 很多站的目录是分页的（`?page=1` 只给 50 章），只抓第一页就会
    // 出现「只有几十章，实际几百几千章」。有 nextTocUrl 就一路跟下去。
    for (var page = 0; page < _maxTocPages; page++) {
      if (!visitedPages.add(pageUrl)) break; // 防死循环
      final html =
          await fetch(SearchRequest(url: pageUrl), header: source.header);
      final document = RuleEngine.parseHtml(html);
      final nodes = RuleEngine.selectNodes(document, listRule);

      if (page == 0 && nodes.isEmpty) {
        binding.lastError = '目录页没匹配到章节（规则 chapterList=$listRule），'
            '书源可能改版了；目录页：$pageUrl';
        throw FormatException(binding.lastError!);
      }

      // 同一章在分页边界可能重复，用 URL 去重
      final seen = urls.toSet();
      var added = 0;
      for (final node in nodes) {
        final name = _field(node, document, rule, 'chapterName', base: pageUrl);
        final url = _field(node, document, rule, 'chapterUrl', base: pageUrl);
        if (name == null || url == null) continue;
        final absolute = _absolute(url, pageUrl);
        if (!seen.add(absolute)) continue;
        urls.add(absolute);
        names.add(name.trim());
        added++;
      }

      final next = _nextTocPage(rule, document, pageUrl);
      AppLog.info(
        'bookSource',
        '目录第 ${page + 1} 页：${nodes.length} 个节点，新增 $added 章，'
        '下一页=${next ?? "无"}',
      );
      if (next == null || added == 0) break;
      pageUrl = next;
    }

    if (names.isEmpty) {
      binding.lastError = '目录规则取不到章节名（chapterName=${rule['chapterName']}）';
      throw FormatException(binding.lastError!);
    }
    AppLog.info('bookSource', '目录共 ${names.length} 章（${binding.title}）');

    final chapters = <NovelChapter>[
      for (var i = 0; i < names.length; i++)
        NovelChapter(names[i], '', id: i + 1),
    ];
    _chapterMemo[id] = chapters;
    _tocUrls[id] = urls;

    // 顺手把目录写进离线缓存，书架才能离线显示章节数。
    try {
      final epoch = cache.epochFor(id);
      await cache.saveBook(
        toNovel(binding).withChapters(chapters),
        epoch: epoch,
      );
    } catch (_) {
      // 缓存失败不影响阅读
    }
    return chapters;
  }

  /// 目录页：优先 `ruleBookInfo.tocUrl`，退到书页本身。
  Future<String> _resolveTocUrl(
    BookSource source,
    FanhuoBookBinding binding,
  ) async {
    final rule = source.bookInfoRule;
    final tocRule = rule['tocUrl'];
    if (tocRule == null) return binding.bookUrl;
    try {
      final html = await fetch(
        SearchRequest(url: binding.bookUrl),
        header: source.header,
      );
      final document = RuleEngine.parseHtml(html);
      final picked = RuleEngine.pick(document, tocRule, base: binding.bookUrl);
      if (picked != null && picked.isNotEmpty) {
        return _absolute(picked, binding.bookUrl);
      }
    } catch (_) {
      // 取不到就回落到书页
    }
    return binding.bookUrl;
  }

  /// 目录下一页。
  ///
  /// `ruleToc.nextTocUrl` 是阅读的约定字段；没有就退化成「找 a 标签里
  /// 文案是下一页/下一頁/下页/NEXT 的链接」——这是绝大多数分页站的写法。
  String? _nextTocPage(SourceRule rule, dom.Document document, String base) {
    final explicit = rule['nextTocUrl'];
    if (explicit != null && explicit.trim().isNotEmpty) {
      try {
        final picked = RuleEngine.pick(document, explicit, base: base);
        if (picked != null && picked.trim().isNotEmpty) {
          return _absolute(picked.trim(), base);
        }
      } catch (_) {
        // 规则坏掉就走下面的兜底
      }
    }
    for (final a in document.querySelectorAll('a')) {
      final text = (a.text ?? '').trim();
      if (text == '下一页' ||
          text == '下一頁' ||
          text == '下页' ||
          text == '下一章页' ||
          text.toLowerCase() == 'next' ||
          text == '›' ||
          text == '>') {
        final href = a.attributes['href'];
        if (href != null && href.trim().isNotEmpty && href != '#') {
          return _absolute(href.trim(), base);
        }
      }
    }
    return null;
  }

  /// 抓正文。
  ///
  /// `ruleContent.content` 取 HTML 片段，`ruleContent.nextContentUrl` 处理分页。
  /// 书源正文里的 `<br>` 转成换行，其余标签按阅读器的纯文本约定剥掉。
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    await _ensureLoaded();
    final cached = await cache.readChapter(novelId, chapter.id);
    if (cached != null) return cached;

    final binding = _bindings[novelId];
    if (binding == null) throw const FormatException('这本书没有来源记录');
    final source = _sourceFor(binding);
    if (source == null) throw const FormatException('来源书源已被删除或关闭');

    // 目录可能还没抓过（冷启动直接进阅读页），先抓一次。
    await chapters(novelId);
    final urls = _tocUrls[novelId];
    if (urls == null || chapter.id <= 0 || chapter.id > urls.length) {
      throw const FormatException('章节序号超出目录范围');
    }

    final buffer = StringBuffer();
    var url = urls[chapter.id - 1];
    final visited = <String>{};
    var ruleMissing = false;
    // 分页最多 24 页，防死循环
    for (var page = 0; page < 24; page++) {
      if (!visited.add(url)) break;
      final html = await fetch(SearchRequest(url: url), header: source.header);
      final document = RuleEngine.parseHtml(html);
      final contentRule = source.contentRule;
      final contentRuleText = contentRule['content'];
      if (contentRuleText == null) {
        ruleMissing = true;
        break;
      }
      final raw = RuleEngine.pick(document, contentRuleText, base: url, all: true);
      if (raw == null || raw.trim().isEmpty) break;
      buffer.writeln(_htmlToText(raw));

      final nextRule = contentRule['nextContentUrl'];
      if (nextRule == null) break;
      // `text.下一页@href` 这种规则从文档里取
      final next = RuleEngine.pick(document, nextRule, base: url);
      if (next == null || next.isEmpty) break;
      url = _absolute(next, url);
    }

    final text = buffer.toString().trim();
    if (text.isEmpty) {
      // 把失败环节写清楚：是没规则、还是规则匹配到 0 个节点
      binding.lastError = ruleMissing
          ? '这个书源没有正文规则（ruleContent.content）'
          : '正文页没取到内容（content=${source.contentRule['content']}），'
              '章节页：$url';
      AppLog.warn('bookSource', binding.lastError!);
      throw FormatException(binding.lastError!);
    }
    try {
      await cache.saveChapter(
        novelId,
        chapter.id,
        text,
        epoch: cache.epochFor(novelId),
      );
    } catch (_) {
      // 缓存失败不影响本次阅读
    }
    return text;
  }

  // ───────── 工具 ─────────

  String? _field(
    dom.Element root,
    dom.Document document,
    SourceRule rule,
    String name, {
    String base = '',
  }) {
    final raw = rule[name];
    if (raw == null) return null;
    try {
      return RuleEngine.pickIn(root, document, raw, base: base);
    } catch (_) {
      return null;
    }
  }

  static String _absolute(String url, String base) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    try {
      return Uri.parse(base).resolve(url).toString();
    } catch (_) {
      return url;
    }
  }

  /// 正文 HTML → 阅读器要的纯文本。
  ///
  /// 规则：`<br>` / `<p>` 转换行，`<script>`/`<style>` 丢掉，
  /// 其余标签剥掉只留文字，连续空行压成一个。
  static String _htmlToText(String html) {
    var text = html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    text = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
    return text;
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
