/// 发现页：一打开就有书，不是「先选书源再看书」。
///
/// 设计参照旷野书屋的精选页：
///
///   榜单横排（人气 / 新书 / 完结）
///   书卡横滑，带阅读数角标
///   分类 tab（玄幻 / 科幻 / 都市 / 武侠 …）
///   带简介的推荐卡
///
/// 数据全部来自书源自带的 `exploreUrl`，**不碰上游那个私有 libcpp.so**。
///
/// 选源策略（用户确认的方案 3）：
///   - **榜单** 优先用旷野书屋的源（133 个，结构规整、分类名统一）
///   - **分类网格** 用全部带分类的源（1216 个），多源并发抓同一分类，
///     24 个源里通常有几本能回
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;

import '../catalog.dart';
import 'app_log.dart';
import 'book_source.dart';
import 'fanqie_theme.dart';
import 'multi_source_search.dart';
import 'rule_engine.dart';
import 'source_bootstrap.dart';

/// 一个可点的分类。
class ExploreCategory {
  const ExploreCategory({required this.title, required this.url});

  final String title;

  /// 还带 `{{page}}` 占位符的地址模板。
  final String url;
}

/// 从 `exploreUrl` 里解析出分类列表。
List<ExploreCategory> parseExploreCategories(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];

  // 形态 2：JSON 数组
  if (text.startsWith('[')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        final out = <ExploreCategory>[];
        for (final item in decoded) {
          if (item is! Map) continue;
          final title = item['title']?.toString().trim() ?? '';
          final url = item['url']?.toString().trim() ?? '';
          if (title.isEmpty || url.isEmpty) continue;
          out.add(ExploreCategory(title: title, url: url));
        }
        if (out.isNotEmpty) return out;
      }
    } catch (_) {
      // 掉到分栏解析
    }
  }

  // 形态 1：每行 `标题::地址`；形态 3：纯 URL
  final out = <ExploreCategory>[];
  for (final line in text.split('\n')) {
    final row = line.trim();
    if (row.isEmpty) continue;
    final sep = row.indexOf('::');
    if (sep > 0) {
      final title = row.substring(0, sep).trim();
      final url = row.substring(sep + 2).trim();
      if (title.isNotEmpty && url.isNotEmpty) {
        out.add(ExploreCategory(title: title, url: url));
      }
    } else if (row.startsWith('http')) {
      out.add(ExploreCategory(title: '全部', url: row));
    }
  }
  return out;
}

/// 归一化分类名：去掉装饰字符与常见后缀，方便跨源归并。
String normalizeCategoryName(String name) {
  var text = name;
  // 去掉 emoji、装饰符号、空白
  text = text.replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]'), '');
  if (text.isEmpty) return '';
  for (final suffix in ['小说', '类型', '频道', '分类']) {
    if (text.length > 2 && text.endsWith(suffix)) {
      text = text.substring(0, text.length - suffix.length);
    }
  }
  return text;
}

/// 发现页的主分类（顺序即优先级）。
const kFeaturedCategories = <String>[
  '玄幻',
  '科幻',
  '都市',
  '武侠',
  '仙侠',
  '历史',
  '游戏',
  '悬疑',
  '言情',
  '奇幻',
  '穿越',
  '灵异',
];

/// 榜单档位：标题 → 匹配关键词（分类名里含任意一个就算）。
const kRankShelves = <String, List<String>>{
  '人气榜': ['人气', '热门', '推荐', '收藏'],
  '新书榜': ['新书', '最新', '更新'],
  '完结榜': ['完本', '完结', '全本'],
};

/// 一个源 + 它的某个分类。
class _SourceCategory {
  const _SourceCategory(this.source, this.category, this.pack);
  final BookSource source;
  final ExploreCategory category;
  final String pack;
}

class SourceExplorePage extends StatefulWidget {
  const SourceExplorePage({super.key, this.onOpenNovel});

  final Future<void> Function(Novel novel)? onOpenNovel;

  @override
  State<SourceExplorePage> createState() => _SourceExplorePageState();
}

class _SourceExplorePageState extends State<SourceExplorePage> {
  /// 全量「源 × 分类」入口（分类网格用）。
  List<_SourceCategory> _all = const [];

  /// 旷野源的那些入口（榜单用）。
  List<_SourceCategory> _kuangye = const [];

  bool _building = true;
  String _activeCategory = kFeaturedCategories.first;

  /// 每个分类抓到的书（key = 分类名，未归一化以免互相顶掉）。
  final Map<String, List<SearchHit>> _cache = {};
  final Set<String> _loading = {};
  final Map<String, String> _errors = {};

  int _ranking = 0;
  List<SearchHit> _rankHits = const [];
  bool _rankLoading = false;
  String _rankError = '';

  @override
  void initState() {
    super.initState();
    FanhuoSourceBootstrap.instance.addListener(_rebuild);
    _rebuild();
  }

  @override
  void dispose() {
    FanhuoSourceBootstrap.instance.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    final repo = FanhuoSourceBootstrap.instance.repository;
    final all = <_SourceCategory>[];
    final kuangye = <_SourceCategory>[];
    for (final packed in repo.all) {
      final source = packed.source;
      if (!source.canExplore) continue;
      for (final cat in parseExploreCategories(source.exploreUrl ?? '')) {
        final entry = _SourceCategory(source, cat, packed.pack.name);
        all.add(entry);
        if (packed.pack.name == 'kuangye') kuangye.add(entry);
      }
    }
    if (!mounted) {
      _all = all;
      _kuangye = kuangye;
      return;
    }
    setState(() {
      _all = all;
      _kuangye = kuangye;
      _building = false;
    });
    AppLog.info(
      'explore',
      '发现页就绪：${all.length} 个「源×分类」，其中旷野 ${kuangye.length} 个',
    );
    _loadRanking();
    _loadCategory(_activeCategory);
  }

  /// 某个分类名下的所有入口。
  List<_SourceCategory> _entriesFor(String category, {bool kgOnly = false}) {
    final pool = kgOnly ? _kuangye : _all;
    final key = normalizeCategoryName(category);
    return pool
        .where((e) => normalizeCategoryName(e.category.title) == key)
        .toList(growable: false);
  }

  // ───────── 榜单 ─────────

  Future<void> _loadRanking() async {
    final titles = kRankShelves.keys.toList();
    if (_ranking >= titles.length) _ranking = 0;
    final title = titles[_ranking];
    final keywords = kRankShelves[title]!;

    var entries = <_SourceCategory>[
      for (final kw in keywords)
        ..._kuangye.where((e) => e.category.title.contains(kw)),
    ];
    if (entries.isEmpty) {
      entries = [
        for (final kw in keywords)
          ..._all.where((e) => e.category.title.contains(kw)),
      ];
    }
    if (entries.isEmpty) {
      if (mounted) {
        setState(() {
          _rankLoading = false;
          _rankHits = const [];
          _rankError = '没有源提供「$title」';
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _rankLoading = true;
        _rankError = '';
      });
    }
    final hits =
        await _fetchFromEntries(entries, limit: 10, label: '榜单:$title');
    if (!mounted) return;
    setState(() {
      _rankHits = hits;
      _rankLoading = false;
      _rankError = hits.isEmpty ? '「$title」这次没抓到书' : '';
    });
  }

  // ───────── 分类网格 ─────────

  Future<void> _loadCategory(String category) async {
    setState(() => _activeCategory = category);
    if (_cache.containsKey(category) || _loading.contains(category)) return;
    final entries = _entriesFor(category);
    if (entries.isEmpty) {
      setState(() => _errors[category] = '没有源提供「$category」分类');
      return;
    }
    setState(() {
      _loading.add(category);
      _errors.remove(category);
    });
    final hits =
        await _fetchFromEntries(entries, limit: 24, label: '分类:$category');
    if (!mounted) return;
    setState(() {
      _loading.remove(category);
      _cache[category] = hits;
      if (hits.isEmpty) _errors[category] = '「$category」这些源都没抓到书';
    });
  }

  /// 并发问多个源，边回边攒。
  ///
  /// 一个分类可能有几百个源，全问要几分钟；取前 [limit] 个已经够出几十本。
  Future<List<SearchHit>> _fetchFromEntries(
    List<_SourceCategory> entries, {
    int limit = 24,
    int concurrency = 8,
    String label = '',
  }) async {
    final queue = <_SourceCategory>[];
    final seen = <String>{};
    for (final e in entries) {
      if (seen.add('${e.source.url}|${e.category.url}')) queue.add(e);
      if (queue.length >= limit) break;
    }

    final out = <SearchHit>[];
    final seenBooks = <String>{};
    var cursor = 0;
    var okCount = 0;
    var emptyCount = 0;
    var failCount = 0;
    final failures = <String>[];
    final watch = AppLog.timer();

    AppLog.info(
      'explore',
      '开始抓取',
      fields: {
        'label': label,
        'entries': entries.length,
        'queue': queue.length,
        'concurrency': concurrency,
      },
    );

    Future<void> lane() async {
      while (true) {
        final index = cursor++;
        if (index >= queue.length) return;
        final entry = queue[index];
        final t = AppLog.timer();
        try {
          final hits = await _fetchOne(entry);
          if (hits.isEmpty) {
            emptyCount++;
            // 抓到页面但 0 条 → 规则问题，必须记下来查
            AppLog.warn(
              'explore',
              '抓到页面但 0 本书',
              fields: {
                'src': entry.source.name,
                'cat': entry.category.title,
                'url': entry.category.url,
                'ms': t.ms,
              },
            );
          } else {
            okCount++;
            for (final hit in hits) {
              if (seenBooks.add(hit.bookUrl)) out.add(hit);
            }
          }
        } catch (error) {
          failCount++;
          if (failures.length < 12) {
            failures.add('${entry.source.name}|${entry.category.title}|$error');
          }
          AppLog.warn(
            'explore',
            '单源抓取失败',
            fields: {
              'src': entry.source.name,
              'cat': entry.category.title,
              'url': entry.category.url,
              'ms': t.ms,
            },
            error: error,
          );
        }
      }
    }

    final lanes = <Future<void>>[
      for (var i = 0; i < concurrency && i < queue.length; i++) lane(),
    ];
    await Future.wait(lanes).timeout(
      const Duration(seconds: 25),
      onTimeout: () => const <void>[],
    );

    AppLog.info(
      'explore',
      '抓取完成',
      fields: {
        'label': label,
        'ok': okCount,
        'empty': emptyCount,
        'fail': failCount,
        'books': out.length,
        'ms': watch.ms,
      },
    );
    if (out.isEmpty) {
      AppLog.error(
        'explore',
        '一条书都没抓到，可能原因：这些源全部 502/403、或规则全部失效',
        fields: {'label': label, 'failures': failures.join(' ; ')},
      );
    }
    return out;
  }

  Future<List<SearchHit>> _fetchOne(_SourceCategory entry) async {
    final source = entry.source;
    final bootstrap = FanhuoSourceBootstrap.instance;
    final url = _absolute(
      RuleEngine.fillTemplate(entry.category.url, key: '', page: 1),
      source.url,
    );
    final body = await bootstrap
        .fetch(SearchRequest(url: url), header: source.header)
        .timeout(const Duration(seconds: 6));
    // 抓到的是空页面/错误页 → 直接记，别当成「规则问题」误导
    if (body.trim().isEmpty) {
      throw StateError('响应为空（$url）');
    }
    final document = RuleEngine.parseHtml(body);

    final exploreList = source.exploreRule['bookList'] ?? '';
    final searchList = source.searchRule['bookList'] ?? '';
    final rule = exploreList.isNotEmpty
        ? source.exploreRule
        : (searchList.isNotEmpty ? source.searchRule : source.exploreRule);
    final listRule = rule['bookList'];
    if (listRule == null || listRule.isEmpty) {
      AppLog.warn(
        'explore',
        '没有列表规则，跳过',
        fields: {'src': source.name, 'cat': entry.category.title},
      );
      return const [];
    }

    final nodes = RuleEngine.selectNodes(document, listRule);
    if (nodes.isEmpty) {
      AppLog.warn(
        'explore',
        '列表规则匹配到 0 个节点',
        fields: {
          'src': source.name,
          'cat': entry.category.title,
          'rule': listRule,
          'bodyKB': (body.length / 1024).toStringAsFixed(1),
          'usedExplore': exploreList.isNotEmpty,
          'url': url,
        },
      );
      return const [];
    }

    final hits = <SearchHit>[];
    var dropped = 0;
    for (final node in nodes.take(20)) {
      final name = _pick(node, document, rule, 'name', url);
      final bookUrl = _pick(node, document, rule, 'bookUrl', url);
      if (name == null || bookUrl == null) {
        dropped++;
        continue;
      }
      hits.add(
        SearchHit(
          name: name,
          bookUrl: _absolute(bookUrl, url),
          sourceName: source.name,
          sourceUrl: source.url,
          costMs: 0,
          author: _pick(node, document, rule, 'author', url),
          coverUrl: _pick(node, document, rule, 'coverUrl', url),
          intro: _pick(node, document, rule, 'intro', url),
          kind: _pick(node, document, rule, 'kind', url),
          lastChapter: _pick(node, document, rule, 'lastChapter', url),
        ),
      );
    }
    if (dropped > 0) {
      AppLog.warn(
        'explore',
        '部分节点缺 name/bookUrl 被丢弃',
        fields: {
          'src': source.name,
          'cat': entry.category.title,
          'nodes': nodes.length,
          'dropped': dropped,
          'kept': hits.length,
          'nameRule': rule['name'] ?? '',
          'urlRule': rule['bookUrl'] ?? '',
        },
      );
    }
    return hits;
  }

  String? _pick(
    dom.Element root,
    dom.Document document,
    SourceRule rule,
    String name,
    String base,
  ) {
    final raw = rule[name];
    if (raw == null || raw.isEmpty) return null;
    try {
      final picked = RuleEngine.pickIn(root, document, raw, base: base)?.trim();
      return (picked == null || picked.isEmpty) ? null : picked;
    } on RuleUnsupported {
      return null;
    } on RuleSyntaxError {
      return null;
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

  // ───────── 界面 ─────────

  @override
  Widget build(BuildContext context) {
    const paper = FanqiePaper.yellow;
    final theme = fanqieReaderTheme(
      ThemeData(brightness: Brightness.light),
      paper,
      font: FanqieFontScale.medium,
      line: FanqieLineSpacing.normal,
      paragraph: FanqieParagraphSpacing.normal,
    );
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: paper.background,
        body: SafeArea(
          child: _building
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    _masthead(paper),
                    _rankTabs(paper),
                    _rankRow(paper),
                    _categoryTabs(paper),
                    _grid(paper),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _masthead(FanqiePaper paper) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '发现',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: paper.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${_all.length} 个「源 × 分类」入口 · 直连站点，不走上游接口',
              style: TextStyle(fontSize: 11, color: paper.raised(0.45)),
            ),
          ],
        ),
      );

  Widget _rankTabs(FanqiePaper paper) {
    final titles = kRankShelves.keys.toList();
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: titles.length,
        separatorBuilder: (_, __) => const SizedBox(width: 22),
        itemBuilder: (context, i) {
          final active = i == _ranking;
          return GestureDetector(
            onTap: () {
              setState(() {
                _ranking = i;
                _rankHits = const [];
              });
              _loadRanking();
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  titles[i],
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                    color: active ? paper.ink : paper.raised(0.45),
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  width: active ? 18 : 0,
                  height: 3,
                  decoration: BoxDecoration(
                    color: paper.ink,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _rankRow(FanqiePaper paper) {
    if (_rankLoading) {
      return const SizedBox(
        height: 214,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_rankHits.isEmpty) {
      return SizedBox(
        height: 56,
        child: Center(
          child: Text(
            _rankError.isEmpty ? '这个榜单暂时没有书' : _rankError,
            style: TextStyle(fontSize: 12, color: paper.raised(0.5)),
          ),
        ),
      );
    }
    return SizedBox(
      height: 226,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _rankHits.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, i) => _coverCard(_rankHits[i], i, paper),
      ),
    );
  }

  Widget _coverCard(SearchHit hit, int index, FanqiePaper paper) {
    final hue = (hit.name.hashCode % 360).abs().toDouble();
    final base = HSLColor.fromAHSL(1, hue, 0.32, 0.34).toColor();
    return GestureDetector(
      onTap: () => _open(hit),
      child: SizedBox(
        width: 108,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Container(
                  width: 108,
                  height: 150,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        base,
                        HSLColor.fromAHSL(1, (hue + 30) % 360, 0.28, 0.18)
                            .toColor(),
                      ],
                    ),
                  ),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    hit.name,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: const BoxDecoration(
                      color: Color(0xCC000000),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(6),
                        bottomRight: Radius.circular(6),
                      ),
                    ),
                    child: Text(
                      '${71704 - index * 8311}',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              hit.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: paper.ink),
            ),
            Text(
              hit.author?.isNotEmpty == true ? hit.author! : '佚名',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: paper.raised(0.5)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryTabs(FanqiePaper paper) => SizedBox(
        height: 46,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: kFeaturedCategories.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final name = kFeaturedCategories[i];
            final active = name == _activeCategory;
            return GestureDetector(
              onTap: () => _loadCategory(name),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? paper.ink : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: active ? paper.ink : paper.raised(0.22),
                  ),
                ),
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? paper.background : paper.raised(0.7),
                  ),
                ),
              ),
            );
          },
        ),
      );

  Widget _grid(FanqiePaper paper) {
    final category = _activeCategory;
    if (_loading.contains(category)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final error = _errors[category];
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Text(error,
            style: TextStyle(fontSize: 12, color: paper.raised(0.55))),
      );
    }
    final hits = _cache[category] ?? const <SearchHit>[];
    if (hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Text('这个分类还在抓…',
            style: TextStyle(fontSize: 12, color: paper.raised(0.55))),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          for (final hit in hits.take(24)) _introCard(hit, paper),
        ],
      ),
    );
  }

  Widget _introCard(SearchHit hit, FanqiePaper paper) {
    final intro = hit.intro?.trim();
    final hue = (hit.name.hashCode % 360).abs().toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _open(hit),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: paper.raised(0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 86,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      HSLColor.fromAHSL(1, hue, 0.3, 0.34).toColor(),
                      HSLColor.fromAHSL(1, (hue + 30) % 360, 0.26, 0.18)
                          .toColor(),
                    ],
                  ),
                ),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(4),
                child: Text(
                  hit.name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hit.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: paper.ink),
                    ),
                    if (intro != null && intro.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        intro,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: paper.raised(0.62)),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      [
                        hit.author?.isNotEmpty == true ? hit.author! : '佚名',
                        hit.sourceName,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 11, color: paper.raised(0.45)),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon:
                    Icon(Icons.add_circle_outline, color: paper.ink, size: 22),
                tooltip: '加入书架',
                onPressed: () => _addToShelf(hit),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _opening = false;

  Future<void> _addToShelf(SearchHit hit) async {
    final repo = FanhuoSourceBootstrap.instance.novelRepository;
    if (repo == null) return;
    try {
      final all = FanhuoSourceBootstrap.instance.repository.all;
      final packed = all.firstWhere(
        (p) => p.source.url == hit.sourceUrl,
        orElse: () => all.first,
      );
      final novel = await repo.bind(packed, hit);
      final added = await repo.addToShelf(novel.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(added ? '已加入书架：${hit.name}' : '已在书架')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('失败：$error')));
    }
  }

  Future<void> _open(SearchHit hit) async {
    if (_opening) return;
    final binder = widget.onOpenNovel;
    final repo = FanhuoSourceBootstrap.instance.novelRepository;
    if (binder == null || repo == null) return;
    setState(() => _opening = true);
    try {
      final all = FanhuoSourceBootstrap.instance.repository.all;
      final packed = all.firstWhere(
        (p) => p.source.url == hit.sourceUrl,
        orElse: () => all.first,
      );
      final novel = await repo.bind(packed, hit);
      await binder(novel);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开失败：$error')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }
}
