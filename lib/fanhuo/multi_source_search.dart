/// 多源并发搜书。
///
/// 旷野书屋「搜书」的本质：同一个关键词丢给 N 个书源，谁先回谁先上，
/// 最后按「书名相似度 → 耗时 → 书名」合并排序。
///
/// 这里只做调度与合并，不碰网络。网络由 [SourceFetcher] 注入，
/// 上层换成 HttpClient / dio / 原生 MethodChannel 都不影响这一层。
library;

import 'package:html/dom.dart' show Document, Element;

import 'book_source.dart';
import 'rule_engine.dart';

/// 一次搜索命中的书。
class SearchHit {
  const SearchHit({
    required this.name,
    required this.bookUrl,
    required this.sourceName,
    required this.sourceUrl,
    required this.costMs,
    this.author,
    this.coverUrl,
    this.intro,
    this.kind,
    this.lastChapter,
    this.wordCount,
  });

  final String name;
  final String bookUrl;
  final String sourceName;
  final String sourceUrl;
  final int costMs;
  final String? author;
  final String? coverUrl;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? wordCount;

  Map<String, Object?> toJson() => {
        'name': name,
        'bookUrl': bookUrl,
        'sourceName': sourceName,
        'sourceUrl': sourceUrl,
        'costMs': costMs,
        'author': author,
        'coverUrl': coverUrl,
        'intro': intro,
        'kind': kind,
        'lastChapter': lastChapter,
        'wordCount': wordCount,
      };
}

/// 单源一次搜索的结果。
class SourceResult {
  const SourceResult({
    required this.source,
    required this.hits,
    required this.costMs,
    this.error,
  });

  final BookSource source;
  final List<SearchHit> hits;
  final int costMs;
  final String? error;

  bool get ok => error == null;
}

/// 网络抽象：给 [SearchRequest]，回原始响应文本。
typedef SourceFetcher = Future<String> Function(
  SearchRequest request, {
  String? header,
});

/// 在 [root] 节点内部按规则取一个字段；字段规则要 JS 或写错时返回 null，
/// 只丢这一个字段，不拖垮整个源。
String? _field(
  Object? root,
  Object? document,
  SourceRule rule,
  String name, {
  String base = '',
}) {
  final raw = rule[name];
  if (raw == null) return null;
  try {
    if (root is! Element || document is! Document) return null;
    return RuleEngine.pickIn(root, document, raw, base: base);
  } on RuleUnsupported {
    return null;
  } on RuleSyntaxError {
    return null;
  }
}

String _absolute(String url, String base) {
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  try {
    return Uri.parse(base).resolve(url).toString();
  } catch (_) {
    return url;
  }
}

String? _absoluteOrNull(String? url, String base) =>
    url == null ? null : _absolute(url, base);

/// 单源搜索。
Future<SourceResult> searchOne(
  BookSource source,
  String keyword, {
  required SourceFetcher fetch,
  int page = 1,
}) async {
  final started = DateTime.now();
  int cost() => DateTime.now().difference(started).inMilliseconds;

  if (!source.canSearch) {
    return SourceResult(source: source, hits: const [], costMs: 0, error: '没有搜索规则');
  }

  try {
    final request = RuleEngine.parseSearchUrl(source.searchUrl!, key: keyword, page: page);
    final body = await fetch(request, header: source.header);
    final document = RuleEngine.parseHtml(body);
    final rule = source.searchRule;
    final listRule = rule['bookList'];
    if (listRule == null) {
      return SourceResult(source: source, hits: const [], costMs: cost(), error: '没有 bookList 规则');
    }
    final nodes = RuleEngine.selectNodes(document, listRule);
    final hits = <SearchHit>[];
    for (final node in nodes) {
      final name = _field(node, document, rule, 'name');
      final bookUrl = _field(node, document, rule, 'bookUrl');
      if (name == null || bookUrl == null) continue;
      hits.add(
        SearchHit(
          name: name,
          bookUrl: _absolute(bookUrl, source.url),
          sourceName: source.name,
          sourceUrl: source.url,
          costMs: cost(),
          author: _field(node, document, rule, 'author'),
          coverUrl: _absoluteOrNull(_field(node, document, rule, 'coverUrl'), source.url),
          intro: _field(node, document, rule, 'intro'),
          kind: _field(node, document, rule, 'kind'),
          lastChapter: _field(node, document, rule, 'lastChapter'),
          wordCount: _field(node, document, rule, 'wordCount'),
        ),
      );
    }
    return SourceResult(source: source, hits: hits, costMs: cost());
  } on RuleUnsupported catch (error) {
    return SourceResult(source: source, hits: const [], costMs: cost(), error: '$error');
  } on RuleSyntaxError catch (error) {
    return SourceResult(source: source, hits: const [], costMs: cost(), error: '$error');
  } catch (error) {
    return SourceResult(source: source, hits: const [], costMs: cost(), error: '请求失败：$error');
  }
}

/// 多源并发调度。
///
/// 用「固定数量的泳道」而不是 `Future.any` + 移除队列：
/// `Future.any` 不告诉你哪个先完成，移除要靠 identity 对不上，容易漏。
/// 泳道模型天然有序，且并发上限恒定。
class MultiSourceSearch {
  MultiSourceSearch({
    required this.sources,
    required this.fetch,
    this.concurrency = 8,
    this.perSourceTimeout = const Duration(seconds: 12),
    this.onResult,
  });

  final List<BookSource> sources;
  final SourceFetcher fetch;
  final int concurrency;
  final Duration perSourceTimeout;

  /// 每有一个源返回就回调一次（用来做「边搜边出」的 UI）。
  final void Function(SourceResult result)? onResult;

  List<BookSource> get _enabled =>
      sources.where((s) => s.enabled && s.canSearch).toList(growable: false);

  Future<SourceResult> _run(BookSource source, String keyword) {
    return searchOne(source, keyword, fetch: fetch).timeout(
      perSourceTimeout,
      onTimeout: () => SourceResult(
        source: source,
        hits: const [],
        costMs: perSourceTimeout.inMilliseconds,
        error: '超时',
      ),
    );
  }

  /// 一次性搜完再排序。
  Future<List<SourceResult>> searchAll(String keyword) async {
    final queue = _enabled;
    final results = <SourceResult>[];
    var cursor = 0;

    Future<void> lane() async {
      while (true) {
        final index = cursor++;
        if (index >= queue.length) return;
        final result = await _run(queue[index], keyword);
        results.add(result);
        onResult?.call(result);
      }
    }

    final lanes = <Future<void>>[];
    for (var i = 0; i < concurrency && i < queue.length; i++) {
      lanes.add(lane());
    }
    await Future.wait(lanes);
    return results;
  }

  /// 一次性搜完并合并排序。
  Future<List<SearchHit>> search(String keyword) async {
    final results = await searchAll(keyword);
    return rank(results.expand((r) => r.hits).toList(), keyword: keyword);
  }

  /// 每个源返回就洗一次牌，适合做流式列表。
  Stream<List<SearchHit>> stream(String keyword) async* {
    final queue = _enabled;
    final hits = <SearchHit>[];
    var cursor = 0;

    Future<void> lane() async {
      while (true) {
        final index = cursor++;
        if (index >= queue.length) return;
        final result = await _run(queue[index], keyword);
        hits.addAll(result.hits);
        onResult?.call(result);
      }
    }

    final lanes = <Future<void>>[];
    for (var i = 0; i < concurrency && i < queue.length; i++) {
      lanes.add(lane());
    }

    var emitted = 0;
    for (final lane in lanes) {
      // 每条泳道跑完就吐一次累计结果
      await lane;
      if (hits.length != emitted) {
        emitted = hits.length;
        yield rank(List<SearchHit>.from(hits), keyword: keyword);
      }
    }
    if (hits.length != emitted) {
      yield rank(List<SearchHit>.from(hits), keyword: keyword);
    }
  }

  /// 排序：完全命中 → 前缀命中 → 包含 → 作者命中 → 其他；
  /// 同档按耗时升序，再按书名。
  static List<SearchHit> rank(List<SearchHit> hits, {String keyword = ''}) {
    final key = keyword.trim();
    int tier(SearchHit hit) {
      if (key.isEmpty) return 2;
      if (hit.name == key) return 0;
      if (hit.name.startsWith(key)) return 1;
      if (hit.name.contains(key)) return 2;
      if (hit.author == key) return 3;
      return 4;
    }

    final copy = [...hits];
    copy.sort((a, b) {
      final t = tier(a).compareTo(tier(b));
      if (t != 0) return t;
      final c = a.costMs.compareTo(b.costMs);
      if (c != 0) return c;
      return a.name.compareTo(b.name);
    });
    return copy;
  }
}
