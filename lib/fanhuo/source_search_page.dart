/// 书源搜索页：把 `BookSourceRepository` 和多源搜索接起来，并**不依赖上游的
/// 私有 API runtime**，所以能独立打开、独立出结果。
///
/// 这一页的目的很明确：现在的版本一进去就「加载失败」，
/// 是因为上游首页要连它自己的私有内容接口（本项目拿不到）。
/// 这一页完全不碰那个接口，只用内置书源 + 直连站点。
library;

import 'package:flutter/material.dart';

import '../catalog.dart';
import 'fanqie_theme.dart';
import 'book_source.dart';
import 'multi_source_search.dart';
import 'source_bootstrap.dart';
import 'source_novel_repository.dart';
import 'source_repository.dart';

/// 一次搜索的状态机。
enum SearchPhase { idle, loading, done, failed }

class SourceSearchPage extends StatefulWidget {
  const SourceSearchPage({
    super.key,
    required this.repository,
    required this.fetch,
    this.onOpenNovel,
    this.onShelfChanged,
    this.initialKeyword = '',
  });

  final BookSourceRepository repository;
  final SourceFetcher fetch;

  /// 点一本书时：把书源条目登记成上游 Novel，再交给阅读页。
  final Future<void> Function(Novel novel)? onOpenNovel;

  /// 加进书架后通知外面刷新书架列表。
  final void Function()? onShelfChanged;
  final String initialKeyword;

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  SearchPhase _phase = SearchPhase.idle;
  List<SearchHit> _hits = const [];
  String _error = '';
  String _keyword = '';
  int _sourceCount = 0;
  int _doneCount = 0;
  int _totalSources = 0;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialKeyword.isNotEmpty) {
      _controller.text = widget.initialKeyword;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _cancel = true;
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    final sources = widget.repository.searchable;
    if (sources.isEmpty) {
      setState(() {
        _phase = SearchPhase.failed;
        _error = '没有可用书源。去「书源管理」看一下是不是全被 JS 规则挡住了。';
      });
      return;
    }
    _cancel = false;
    setState(() {
      _phase = SearchPhase.loading;
      _hits = const [];
      _error = '';
      _keyword = keyword;
      _doneCount = 0;
      _totalSources = sources.length;
      _sourceCount = 0;
    });

    final engine = MultiSourceSearch(
      // 快源先问：首页可达的排前面，用户 30 秒内就能看到第一批结果
      sources: _sortByReachability(sources),
      fetch: widget.fetch,
      // 现在跑 8 路 × 12 秒超时，1765 个源跑完要好几分钟。
      // 网络 IO 为主，48 路不会打满 CPU；6 秒不回基本就是死了。
      concurrency: 48,
      perSourceTimeout: const Duration(seconds: 6),
      onResult: (result) {
        if (!mounted || _cancel) return;
        _doneCount++;
        if (result.ok && result.hits.isNotEmpty) {
          _sourceCount++;
          // 边搜边显示：每有一个源命中就把结果并进去重新排一次
          _hits = MultiSourceSearch.rank(
            [..._hits, ...result.hits],
            keyword: _keyword,
          );
        }
        // ⚠️ 每来一个源都必须 setState 重建，否则界面只在 onResult 里改了
        // 内存变量、屏幕不刷新 —— 1.7.0 就是这样，用户看到的是「等全部跑完才出结果」。
        setState(() {});
      },
    );

    try {
      // 用 searchAll 而不是 search：结果已经在 onResult 里边搜边并进去了，
      // 这里只等它跑完，然后标记完成（不能用 search 否则会把流式结果覆盖掉）。
      await engine.searchAll(keyword);
      if (!mounted || _cancel) return;
      setState(() => _phase = SearchPhase.done);
    } catch (error) {
      if (!mounted || _cancel) return;
      setState(() {
        _phase = SearchPhase.failed;
        _error = '搜索中断：$error';
      });
    }
  }

  /// 快源先问：有 `probeStatus` 且可达的排前面，其余保持原序。
  static List<BookSource> _sortByReachability(List<PackedSource> packed) {
    int weight(PackedSource p) {
      final status = p.source.probeStatus;
      if (status.isEmpty) return 2; // 没探测过，中间档
      if (status == '200') return 0; // 首页可达，最先问
      return 3; // 探测失败，最后问
    }

    final sorted = [...packed]
      ..sort((a, b) => weight(a).compareTo(weight(b)));
    return [for (final p in sorted) p.source];
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
        appBar: AppBar(
          title: const Text('书源搜书'),
          backgroundColor: paper.background,
          foregroundColor: paper.ink,
          elevation: 0,
        ),
        backgroundColor: paper.background,
        body: Column(
          children: [
            _searchBar(paper),
            _statusBar(paper),
            Expanded(child: _body(paper)),
          ],
        ),
      ),
    );
  }

  Widget _searchBar(FanqiePaper paper) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                style: TextStyle(color: paper.ink),
                decoration: InputDecoration(
                  hintText: '书名 / 作者',
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
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _phase == SearchPhase.loading ? null : _search,
              style: FilledButton.styleFrom(
                backgroundColor: paper.ink,
                foregroundColor: paper.background,
              ),
              child: Text(_phase == SearchPhase.loading ? '搜…' : '搜'),
            ),
          ],
        ),
      );

  Widget _statusBar(FanqiePaper paper) {
    final stats = widget.repository.stats();
    final text = switch (_phase) {
      SearchPhase.idle => '${stats.summary}\n${stats.packSummary()}',
      SearchPhase.loading =>
        '已问 $_doneCount / $_totalSources 个源，$_sourceCount 个有结果',
      SearchPhase.done =>
        '「$_keyword」命中 ${_hits.length} 条，来自 $_sourceCount 个源',
      SearchPhase.failed => _error,
    };
    return Container(
      width: double.infinity,
      color: paper.raised(0.04),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: _phase == SearchPhase.failed ? Colors.red.shade700 : paper.raised(0.6),
        ),
      ),
    );
  }

  Widget _body(FanqiePaper paper) {
    // 失败且没有任何结果，才整屏报错
    if (_phase == SearchPhase.failed && _hits.isEmpty) {
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
    // 还在搜、且一条都还没回来 → 转圈
    if (_phase == SearchPhase.loading && _hits.isEmpty) {
      return Column(
        children: [
          const SizedBox(height: 60),
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            '已问 $_doneCount / $_totalSources 个源…',
            style: TextStyle(fontSize: 12, color: paper.raised(0.5)),
          ),
        ],
      );
    }
    if (_hits.isEmpty) {
      return Center(
        child: Text(
          _phase == SearchPhase.done ? '这本书一条都没搜到' : '输入书名开始搜',
          style: TextStyle(color: paper.raised(0.55)),
        ),
      );
    }
    // 有结果就显示结果 —— **不管搜没搜完**。
    // 这就是「边搜边出」：每个源回来就并进列表，用户立刻能点。
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _hits.length + (_phase == SearchPhase.loading ? 1 : 0),
      separatorBuilder: (context, index) => Divider(
        height: 1,
        color: paper.raised(0.12),
      ),
      itemBuilder: (context, i) {
        if (i >= _hits.length) {
          // 末尾那条「还在搜」的提示行
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  '已问 $_doneCount / $_totalSources 个源，还在搜…',
                  style: TextStyle(fontSize: 12, color: paper.raised(0.5)),
                ),
              ],
            ),
          );
        }
        return _hitTile(_hits[i], paper);
      },
    );
  }

  /// 点一本书：登记成上游 Novel，交给阅读页。
  ///
  /// 登记要写 SharedPreferences（记下 bookUrl / 书源），是异步的，
  /// 所以这里给一行「正在打开」的状态，避免用户连点。
  bool _opening = false;

  Future<void> _open(SearchHit hit) async {
    if (_opening) return;
    final binder = widget.onOpenNovel;
    if (binder == null) return;
    setState(() => _opening = true);
    try {
      final packed = widget.repository.all.firstWhere(
        (p) => p.source.url == hit.sourceUrl,
        orElse: () => widget.repository.all.first,
      );
      final repository = FanhuoSourceBootstrap.instance.novelRepository;
      if (repository == null) {
        throw StateError('书源运行时还没准备好');
      }
      final novel = await repository.bind(packed, hit);
      await binder(novel);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _hitTile(SearchHit hit, FanqiePaper paper) {
    final repo = FanhuoSourceBootstrap.instance.novelRepository;
    return ListTile(
      title: Text(
        hit.name,
        style: TextStyle(color: paper.ink, fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hit.author != null)
            Text(hit.author!, style: TextStyle(fontSize: 12, color: paper.raised(0.6))),
          if (hit.lastChapter != null)
            Text(
              '最新：${hit.lastChapter}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: paper.raised(0.5)),
            ),
          Text(
            '${hit.sourceName} · ${hit.costMs}ms',
            style: TextStyle(fontSize: 11, color: paper.raised(0.42)),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 「+」一键收藏：登记成上游 Novel 并加进书架，不用先进阅读页
          IconButton(
            icon: Icon(
              _saving.contains(hit.bookUrl)
                  ? Icons.hourglass_empty
                  : Icons.add_circle_outline,
              color: paper.ink,
            ),
            tooltip: '加入书架',
            onPressed: _saving.contains(hit.bookUrl)
                ? null
                : () => _addToShelf(hit, repo),
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
                  onPressed: widget.onOpenNovel == null ? null : () => _open(hit),
                ),
        ],
      ),
      onTap: widget.onOpenNovel == null ? null : () => _open(hit),
    );
  }

  /// 正在收藏中的 bookUrl（防连点）。
  final Set<String> _saving = {};

  Future<void> _addToShelf(
    SearchHit hit,
    FanhuoSourceRepository? repository,
  ) async {
    if (repository == null) {
      _toast('书源运行时还没准备好');
      return;
    }
    setState(() => _saving.add(hit.bookUrl));
    try {
      final packed = widget.repository.all.firstWhere(
        (p) => p.source.url == hit.sourceUrl,
        orElse: () => widget.repository.all.first,
      );
      final novel = await repository.bind(packed, hit);
      final added = await repository.addToShelf(novel.id);
      _toast(added ? '已加入书架：${hit.name}' : '《${hit.name}》已在书架里');
      widget.onShelfChanged?.call();
    } catch (error) {
      _toast('加入书架失败：$error');
    } finally {
      if (mounted) setState(() => _saving.remove(hit.bookUrl));
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
