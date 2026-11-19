/// 我的书源书架：把收藏的书源书列出来，点进去直接读。
///
/// 为什么单独一页而不是塞进上游「书架」：
/// 上游书架的数据源是它自己的 `NovelRepository` 列表（本地书 + 它自己的书），
/// 书源书是另一种 id 空间（负数 -900000000 起）。混在一起会互相干扰，
/// 所以这里自己列。上游书架那边照样可以读到 —— 因为 `FanhuoSourceRepository`
/// 已经 `extends NovelRepository`，两套视图读的是同一份登记表。
library;

import 'package:flutter/material.dart';

import '../catalog.dart';
import 'fanqie_theme.dart';
import 'source_bootstrap.dart';
import 'source_novel_repository.dart';

class SourceShelfPage extends StatefulWidget {
  const SourceShelfPage({super.key, this.onOpenNovel});

  /// 点一本书时交给上游阅读页。
  final Future<void> Function(Novel novel)? onOpenNovel;

  @override
  State<SourceShelfPage> createState() => _SourceShelfPageState();
}

class _SourceShelfPageState extends State<SourceShelfPage> {
  List<Novel>? _books;
  String _error = '';

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

  Future<void> _reload() async {
    final repo = FanhuoSourceBootstrap.instance.novelRepository;
    if (repo == null) {
      if (mounted) setState(() => _error = '书源运行时还没准备好');
      return;
    }
    try {
      final books = await repo.shelfBooks();
      if (!mounted) return;
      setState(() {
        _books = books;
        _error = '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
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
    final books = _books;
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: paper.background,
        appBar: AppBar(
          title: const Text('我的书源书架'),
          backgroundColor: paper.background,
          foregroundColor: paper.ink,
          elevation: 0,
          actions: [
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
          ],
        ),
        body: _error.isNotEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: SelectableText(
                    _error,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red.shade700),
                  ),
                ),
              )
            : books == null
                ? const Center(child: CircularProgressIndicator())
                : books.isEmpty
                    ? Center(
                        child: Text(
                          '书架还是空的。\n去「搜书」里点条目右边的 ＋ 收一本。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: paper.raised(0.55)),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: books.length,
                        separatorBuilder: (context, index) =>
                            Divider(height: 1, color: paper.raised(0.12)),
                        itemBuilder: (context, i) =>
                            _row(books[i], paper),
                      ),
      ),
    );
  }

  Widget _row(Novel novel, FanqiePaper paper) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 54,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: novel.colors,
          ),
        ),
      ),
      title: Text(
        novel.title,
        style: TextStyle(color: paper.ink, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          novel.author,
          if ((novel.lastUpdate ?? '').isNotEmpty) '最新：${novel.lastUpdate}',
        ].where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: paper.raised(0.5)),
      ),
      trailing: IconButton(
        tooltip: '移出书架',
        icon: Icon(Icons.remove_circle_outline, color: paper.raised(0.5)),
        onPressed: () async {
          final repo = FanhuoSourceBootstrap.instance.novelRepository;
          if (repo == null) return;
          final ok = await repo.removeFromShelf(novel.id);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ok ? '已移出：${novel.title}' : '本来就不在书架')),
          );
          await _reload();
        },
      ),
      onTap: widget.onOpenNovel == null
          ? null
          : () => widget.onOpenNovel!(novel),
    );
  }
}
