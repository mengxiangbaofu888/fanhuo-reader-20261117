/// 我的书源书架：书脊式横滑轮播 + 下方目录列表。
///
/// 视觉照文庫（`archive_wave.dart` 的 `ArchiveFileCarousel`）：
/// 书以「书脊」排队站在架子上，滚动时整体起伏，中间那本抽出来露出封面。
/// 交互也在这一层：滑到某本停下、点封面翻到详情、长按移出书架。
///
/// 为什么复用上游组件而不自己画：
/// `ArchiveFileCarousel` 已经把「波浪提取 + 吸附 + 封面懒加载 + 无障碍」
/// 全做完了（1424 行），自己重画只会更差。
library;

import 'package:flutter/material.dart';

import '../archive_wave.dart';
import '../archive_design.dart';
import '../catalog.dart';
import 'fanqie_theme.dart';
import 'source_bootstrap.dart';

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
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '书架',
                            style: TextStyle(
                              fontSize: 30,
                              height: 1.1,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                              color: paper.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'SOURCE SHELF · ${books?.length ?? 0} 本',
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 2.2,
                              fontWeight: FontWeight.w600,
                              color: paper.raised(0.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新',
                      icon: Icon(Icons.refresh, color: paper.ink),
                      onPressed: _reload,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(child: _content(paper, books)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(FanqiePaper paper, List<Novel>? books) {
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: SelectableText(
            _error,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.red.shade700),
          ),
        ),
      );
    }
    if (books == null) return const Center(child: CircularProgressIndicator());
    if (books.isEmpty) return _empty(paper);

    // 书太少时不显示轮播：一两个书脊既不好看，又和下面的列表重复，
    // 用户会以为是两本书。4 本起才值得用轮播展示。
    final showCarousel = books.length >= 4;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showCarousel) ...[
          // ── 书脊轮播（文庫同款） ──
          // ClipRect 必须包：轮播内部有 3D 倾斜 + 抽出效果，会超出 268 的高度，
          // 不裁就压住下面的「全部收藏」和列表。
          SizedBox(
            height: 268,
            child: ClipRect(
              child: ArchiveFileCarousel(
                books: books,
                animateEntrance: true,
                onOpen: (novel, _) => _open(novel),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        ArchiveSection(
          title: showCarousel ? '全部收藏' : '我的收藏',
          code: '02 / ALL',
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(top: 4, bottom: 24),
            itemCount: books.length,
            separatorBuilder: (context, index) => Divider(
              height: 1,
              indent: 20,
              endIndent: 20,
              color: paper.raised(0.12),
            ),
            itemBuilder: (context, i) => _row(books[i], paper, i),
          ),
        ),
      ],
    );
  }

  Widget _empty(FanqiePaper paper) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_outlined,
                size: 48, color: paper.raised(0.28)),
            const SizedBox(height: 16),
            Text(
              '书架还是空的',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: paper.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '去「发现」或「书源」搜一本书，\n点条目右边的「书架」按钮收进来。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.6, color: paper.raised(0.55)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(Novel novel) async {
    final binder = widget.onOpenNovel;
    if (binder != null) await binder(novel);
  }

  Widget _row(Novel novel, FanqiePaper paper, int index) {
    return InkWell(
      onTap: () => _open(novel),
      onLongPress: () => _confirmRemove(novel),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
        child: Row(
          children: [
            // 序号，文庫那种等宽数字
            SizedBox(
              width: 28,
              child: Text(
                (index + 1).toString().padLeft(2, '0'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: paper.raised(0.35),
                ),
              ),
            ),
            Container(
              width: 38,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: novel.colors,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    novel.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: paper.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      novel.author,
                      if ((novel.lastUpdate ?? '').isNotEmpty)
                        novel.lastUpdate!,
                    ].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: paper.raised(0.5)),
                  ),
                ],
              ),
            ),
            // 明显一点的移出按钮
            SizedBox(
              width: 56,
              height: 30,
              child: TextButton(
                onPressed: () => _confirmRemove(novel),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: paper.raised(0.6),
                  side: BorderSide(color: paper.raised(0.3), width: 1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
                child: const Text('移出',
                    style:
                        TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(Novel novel) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出书架？'),
        content: Text('《${novel.title}》会从书架移除，已下载的缓存保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = FanhuoSourceBootstrap.instance.novelRepository;
    if (repo == null) return;
    final removed = await repo.removeFromShelf(novel.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(removed ? '已移出：${novel.title}' : '本来就不在书架')),
    );
    await _reload();
  }
}
