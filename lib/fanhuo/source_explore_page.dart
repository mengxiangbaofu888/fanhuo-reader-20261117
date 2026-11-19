/// 书源发现页：用书源自带的分类规则，做出真正能用的「发现」。
///
/// 为什么需要它：底座（文庫）的「发现」tab 连它自己的私有 `libcpp.so` 接口，
/// 我们拿不到那个 so，那个页面永远「书籍加载失败」。而书源里有
/// **1256 个源带 `exploreUrl`**，它们自带分类目录，完全不需要私有接口。
///
/// `exploreUrl` 有三种形态，全部支持：
///   1. **分栏文本**（684 个）：
///      ```
///      玄幻奇幻::/xuanhuanqihuan/list-1-{{page}}.html
///      武侠修真::/wuxiaxiuzhen/list-2-{{page}}.html
///      ```
///   2. **JSON 数组**（572 个）：
///      ```json
///      [{"title":"都市人生","url":"http://.../classify?page={{page}}"}, ...]
///      ```
///   3. **纯 URL**（较少）：只有一个地址，当成唯一分类。
///
/// 列表规则优先用 `ruleExplore`，没有就退回 `ruleSearch`
/// （327/328 的分栏源都靠这个兜住，两者的列表结构通常一致）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;

import '../catalog.dart';

import 'app_log.dart';
import 'book_source.dart';
import 'fanqie_theme.dart';
import 'multi_source_search.dart';
import 'source_bootstrap.dart';
import 'source_novel_repository.dart';
import 'source_repository.dart';
import 'rule_engine.dart';

/// 一个可点的分类。
class ExploreCategory {
  const ExploreCategory({required this.title, required this.url});

  final String title;

  /// 已经展开 `{{page}}` 之前的模板，抓的时候替换页码。
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
      // 掉到下面的分栏解析
    }
  }

  // 形态 1：每行 `标题::地址`
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
      // 形态 3：纯 URL
      out.add(ExploreCategory(title: '全部', url: row));
    }
  }
  return out;
}

/// 发现页。
class SourceExplorePage extends StatefulWidget {
  const SourceExplorePage({super.key, this.onOpenNovel});

  final Future<void> Function(Novel novel)? onOpenNovel;

  @override
  State<SourceExplorePage> createState() => _SourceExplorePageState();
}

class _SourceExplorePageState extends State<SourceExplorePage> {
  List<BookSource> _explorable = const [];
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    FanhuoSourceBootstrap.instance.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    FanhuoSourceBootstrap.instance.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    final repo = FanhuoSourceBootstrap.instance.repository;
    final list = repo.all
        .where((p) => p.source.canExplore)
        .map((p) => p.source)
        .toList(growable: false);
    if (!mounted) {
      _explorable = list;
      return;
    }
    setState(() => _explorable = list);
  }

  List<BookSource> get _filtered {
    final key = _keyword.trim().toLowerCase();
    if (key.isEmpty) return _explorable;
    return _explorable
        .where((s) =>
            s.name.toLowerCase().contains(key) ||
            s.group.toLowerCase().contains(key))
        .toList(growable: false);
  }

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
    final list = _filtered;
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: paper.background,
        appBar: AppBar(
          title: const Text('发现'),
          backgroundColor: paper.background,
          foregroundColor: paper.ink,
          elevation: 0,
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              color: paper.raised(0.05),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Text(
                '${_explorable.length} 个书源带分类目录。'
                '点进去看分类，再点分类抓书单。',
                style: TextStyle(fontSize: 12, color: paper.raised(0.6)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _keyword = v),
                style: TextStyle(color: paper.ink),
                decoration: InputDecoration(
                  hintText: '按书源名 / 分组筛',
                  hintStyle: TextStyle(color: paper.raised(0.45)),
                  isDense: true,
                  filled: true,
                  fillColor: paper.raised(0.06),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(
                      child: Text(
                        _explorable.isEmpty
                            ? '没有书源带分类目录'
                            : '没有匹配的书源',
                        style: TextStyle(color: paper.raised(0.55)),
                      ),
                    )
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (context, index) =>
                          Divider(height: 1, color: paper.raised(0.12)),
                      itemBuilder: (context, i) => _sourceRow(list[i], paper),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceRow(BookSource source, FanqiePaper paper) {
    final cats = parseExploreCategories(source.exploreUrl ?? '');
    return ListTile(
      title: Text(
        source.name,
        style: TextStyle(color: paper.ink, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          if (source.group.isNotEmpty) source.group,
          '${cats.length} 个分类',
        ].join(' · '),
        style: TextStyle(fontSize: 12, color: paper.raised(0.5)),
      ),
      trailing: Icon(Icons.chevron_right, color: paper.raised(0.4)),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SourceCategoryPage(
            source: source,
            categories: cats,
            onOpenNovel: widget.onOpenNovel,
          ),
        ),
      ),
    );
  }
}

/// 某个书源的分类页 + 抓到的书单。
class SourceCategoryPage extends StatefulWidget {
  const SourceCategoryPage({
    super.key,
    required this.source,
    required this.categories,
    this.onOpenNovel,
  });

  final BookSource source;
  final List<ExploreCategory> categories;
  final Future<void> Function(Novel novel)? onOpenNovel;

  @override
  State<SourceCategoryPage> createState() => _SourceCategoryPageState();
}

class _SourceCategoryPageState extends State<SourceCategoryPage> {
  ExploreCategory? _active;
  List<SearchHit> _hits = const [];
  bool _loading = false;
  String _error = '';
  int _page = 1;

  @override
  void initState() {
    super.initState();
    if (widget.categories.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _selectCategory(widget.categories.first);
      });
    }
  }

  Future<void> _selectCategory(ExploreCategory category) async {
    setState(() {
      _active = category;
      _loading = true;
      _error = '';
      _hits = const [];
      _page = 1;
    });
    await _fetch();
  }

  Future<void> _fetch() async {
    final active = _active;
    if (active == null) return;
    final bootstrap = FanhuoSourceBootstrap.instance;
    final source = widget.source;
    try {
      // 分类地址可能是相对路径（`/xuanhuan/list-1-{{page}}.html`），
      // 先补成绝对地址，再展开页码占位符。
      final raw = _absolute(
        RuleEngine.fillTemplate(active.url, key: '', page: _page),
        source.url,
      );
      final request = SearchRequest(url: raw);
      final body = await bootstrap.fetch(request, header: source.header);
      final document = RuleEngine.parseHtml(body);

      // 列表规则：优先 ruleExplore，没有就退回 ruleSearch
      final exploreList = source.exploreRule['bookList'] ?? '';
      final searchList = source.searchRule['bookList'] ?? '';
      final rule = exploreList.isNotEmpty
          ? source.exploreRule
          : (searchList.isNotEmpty ? source.searchRule : source.exploreRule);
      final listRule = rule['bookList'];
      if (listRule == null || listRule.isEmpty) {
        setState(() {
          _loading = false;
          _error = '这个书源没有列表规则（ruleExplore.bookList 为空，'
              'ruleSearch.bookList 也为空）';
        });
        return;
      }

      final nodes = RuleEngine.selectNodes(document, listRule);
      final hits = <SearchHit>[];
      for (final node in nodes) {
        final name = _pick(node, document, rule, 'name', raw);
        final bookUrl = _pick(node, document, rule, 'bookUrl', raw);
        if (name == null || bookUrl == null) continue;
        hits.add(
          SearchHit(
            name: name,
            bookUrl: _absolute(bookUrl, raw),
            sourceName: source.name,
            sourceUrl: source.url,
            costMs: 0,
            author: _pick(node, document, rule, 'author', raw),
            coverUrl: _pick(node, document, rule, 'coverUrl', raw),
            intro: _pick(node, document, rule, 'intro', raw),
            kind: _pick(node, document, rule, 'kind', raw),
            lastChapter: _pick(node, document, rule, 'lastChapter', raw),
          ),
        );
      }
      AppLog.info(
        'explore',
        '${source.name} / ${active.title} 第 $_page 页：'
        '${nodes.length} 节点 → ${hits.length} 本',
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _hits = hits;
        _error = hits.isEmpty ? '这一页没抓到书（规则可能失效，或该分类为空）' : '';
      });
    } catch (error) {
      AppLog.warn('explore', '${source.name} / ${active.title} 失败：$error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '抓取失败：$error';
      });
    }
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
        appBar: AppBar(
          title: Text(widget.source.name),
          backgroundColor: paper.background,
          foregroundColor: paper.ink,
          elevation: 0,
        ),
        body: Column(
          children: [
            if (widget.categories.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final c in widget.categories)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 8),
                        child: ChoiceChip(
                          label: Text(c.title,
                              style: const TextStyle(fontSize: 12)),
                          selected: _active?.title == c.title,
                          onSelected: (_) => _selectCategory(c),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(child: _body(paper)),
            if (_hits.isNotEmpty)
              SafeArea(
                top: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: _page > 1 && !_loading
                          ? () {
                              _page -= 1;
                              setState(() => _loading = true);
                              _fetch();
                            }
                          : null,
                      child: const Text('上一页'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('第 $_page 页',
                          style: TextStyle(
                              fontSize: 12, color: paper.raised(0.55))),
                    ),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () {
                              _page += 1;
                              setState(() => _loading = true);
                              _fetch();
                            },
                      child: const Text('下一页'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(FanqiePaper paper) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: SelectableText(
            _error,
            textAlign: TextAlign.center,
            style: TextStyle(color: paper.ink),
          ),
        ),
      );
    }
    if (_hits.isEmpty) {
      return Center(
        child: Text('选一个分类试试',
            style: TextStyle(color: paper.raised(0.55))),
      );
    }
    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (context, index) =>
          Divider(height: 1, color: paper.raised(0.12)),
      itemBuilder: (context, i) => _hitRow(_hits[i], paper),
    );
  }

  bool _opening = false;

  Future<void> _addToShelf(SearchHit hit) async {
    final repo = FanhuoSourceBootstrap.instance.novelRepository;
    if (repo == null) return;
    try {
      final packed = FanhuoSourceBootstrap.instance.repository.all.firstWhere(
        (p) => p.source.url == hit.sourceUrl,
        orElse: () =>
            FanhuoSourceBootstrap.instance.repository.all.first,
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
      final packed = FanhuoSourceBootstrap.instance.repository.all.firstWhere(
        (p) => p.source.url == hit.sourceUrl,
        orElse: () =>
            FanhuoSourceBootstrap.instance.repository.all.first,
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

  Widget _hitRow(SearchHit hit, FanqiePaper paper) {
    return ListTile(
      title: Text(hit.name,
          style: TextStyle(color: paper.ink, fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hit.author != null && hit.author!.isNotEmpty)
            Text(hit.author!,
                style: TextStyle(fontSize: 12, color: paper.raised(0.6))),
          if (hit.lastChapter != null && hit.lastChapter!.isNotEmpty)
            Text(
              '最新：${hit.lastChapter}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: paper.raised(0.5)),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.add_circle_outline, color: paper.ink),
            tooltip: '加入书架',
            onPressed: () => _addToShelf(hit),
          ),
          _opening
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: Icon(Icons.menu_book_outlined, color: paper.ink),
                  tooltip: '打开阅读',
                  onPressed: widget.onOpenNovel == null
                      ? null
                      : () => _open(hit),
                ),
        ],
      ),
      onTap: widget.onOpenNovel == null ? null : () => _open(hit),
    );
  }
}
