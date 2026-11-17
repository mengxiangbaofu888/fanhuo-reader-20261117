/// 书源搜索页：把 `BookSourceRepository` 和多源搜索接起来，并**不依赖上游的
/// 私有 API runtime**，所以能独立打开、独立出结果。
///
/// 这一页的目的很明确：现在的版本一进去就「加载失败」，
/// 是因为上游首页要连它自己的私有内容接口（本项目拿不到）。
/// 这一页完全不碰那个接口，只用内置书源 + 直连站点。
library;

import 'package:flutter/material.dart';

import 'fanqie_theme.dart';
import 'multi_source_search.dart';
import 'source_repository.dart';

/// 一次搜索的状态机。
enum SearchPhase { idle, loading, done, failed }

class FanhuoSearchPage extends StatefulWidget {
  const FanhuoSearchPage({
    super.key,
    required this.repository,
    required this.fetch,
    this.onOpenBook,
    this.initialKeyword = '',
  });

  final BookSourceRepository repository;
  final SourceFetcher fetch;

  /// 点一本书时的回调（打开详情/加入书架）。
  final void Function(PackedSource source, SearchHit hit)? onOpenBook;
  final String initialKeyword;

  @override
  State<FanhuoSearchPage> createState() => _FanhuoSearchPageState();
}

class _FanhuoSearchPageState extends State<FanhuoSearchPage> {
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
      sources: [for (final p in sources) p.source],
      fetch: widget.fetch,
      concurrency: 8,
      perSourceTimeout: const Duration(seconds: 12),
      onResult: (result) {
        if (!mounted || _cancel) return;
        setState(() {
          _doneCount++;
          if (result.ok && result.hits.isNotEmpty) _sourceCount++;
        });
      },
    );

    try {
      final hits = await engine.search(keyword);
      if (!mounted || _cancel) return;
      setState(() {
        _hits = hits;
        _phase = SearchPhase.done;
      });
    } catch (error) {
      if (!mounted || _cancel) return;
      setState(() {
        _phase = SearchPhase.failed;
        _error = '搜索中断：$error';
      });
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
    if (_phase == SearchPhase.loading && _hits.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_phase == SearchPhase.failed) {
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
        child: Text(
          _phase == SearchPhase.done ? '这本书一条都没搜到' : '输入书名开始搜',
          style: TextStyle(color: paper.raised(0.55)),
        ),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _hits.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: paper.raised(0.12),
      ),
      itemBuilder: (context, i) => _hitTile(_hits[i], paper),
    );
  }

  Widget _hitTile(SearchHit hit, FanqiePaper paper) {
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
      trailing: IconButton(
        icon: Icon(Icons.download_outlined, color: paper.ink),
        tooltip: '加入书架',
        onPressed: () {
          final source = widget.repository.all
              .firstWhere(
                (p) => p.source.url == hit.sourceUrl,
                orElse: () => widget.repository.all.first,
              );
          widget.onOpenBook?.call(source, hit);
        },
      ),
    );
  }
}
