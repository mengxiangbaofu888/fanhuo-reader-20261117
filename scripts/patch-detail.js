#!/usr/bin/env node
/**
 * 详情页两处增强（都在上游底座里，用「字符串替换 + 追加文件内容」实现）。
 *
 * 1. **目录兜底**：`DetailLoaderPage._load()` 一次抓详情 + 目录，目录抓不到
 *    整页就「加载失败」。改成目录抓失败时退到上次成功的快照。
 *
 * 2. **本地书架按钮**：文庫详情页只有「云端收藏」（账号体系，要登录），
 *    本地书架没有入口。加一个 `_ShelfToggleButton` 写 `LibraryState`。
 *
 * 两处都做幂等判断：替换型看锚点在不在，追加型看 class 是否已存在。
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const BASE = process.env.WENKU_BASE || path.join(ROOT, '_wenku_base');

function log(msg) {
  console.log(`[detail-patch] ${msg}`);
}

function read(rel) {
  const file = path.join(BASE, rel);
  if (!fs.existsSync(file)) {
    console.error(`[detail-patch] 找不到 ${rel}`);
    process.exit(1);
  }
  return { file, text: fs.readFileSync(file, 'utf8') };
}

/* ───────── 1. 目录兜底 ───────── */
{
  const { file, text } = read('lib/pages.dart');
  const OLD = `    book ??= (await widget.repository.detail(
      widget.novel,
    )).withChapters(await widget.repository.chapters(widget.novel.id));`;
  const NEW = `    if (book == null) {
      // 先拿详情；目录单独处理 —— 目录抓不到不该让整页失败。
      final detail = await widget.repository.detail(widget.novel);
      List<NovelChapter> chapters;
      try {
        chapters = await widget.repository.chapters(widget.novel.id);
      } catch (error) {
        // 目录这次没抓到（站点慢/超时/规则失效）：退到上次成功抓到的快照。
        // 缓存里没有章节 URL，正文还得现抓，但至少书架能显示、目录能看。
        chapters = const [];
        if (widget.repository case final OfflineNovelRepository offline) {
          try {
            await offline.loadCache();
          } catch (_) {}
          final cached = await offline.cachedBook(widget.novel.id);
          chapters = cached?.chapters ?? const [];
        }
        if (chapters.isEmpty) rethrow;
      }
      book = detail.withChapters(chapters);
    }`;

  if (text.includes(NEW)) {
    log('pages.dart: 目录兜底（已应用，跳过）');
  } else if (text.includes(OLD)) {
    fs.writeFileSync(file, text.replace(OLD, NEW), 'utf8');
    log('pages.dart: 目录兜底');
  } else if (text.includes('目录抓不到不该让整页失败')) {
    // 别人（人手或旧版脚本）已经改过，内容大同小异，认它
    log('pages.dart: 目录兜底（检测到等效实现，跳过）');
  } else {
    console.error('[detail-patch] pages.dart 找不到 _load() 锚点 —— 底座版本漂移');
    process.exit(1);
  }
}

/** 组件本体。用变量持有，避免模板字符串里再套反引号。 */
const COMPONENT = `

/// 详情页的「加入/移出书架」按钮。
///
/// 为什么要单独一个：文庫原本只有「云端收藏」（账号体系，需要登录），
/// 本地书架没有入口。这个按钮直接写 LibraryState.setShelfMembership，
/// 点完立刻在「书架」tab 里能看到。
class _ShelfToggleButton extends StatefulWidget {
  const _ShelfToggleButton({required this.state, required this.novel});

  final LibraryState state;
  final Novel novel;

  @override
  State<_ShelfToggleButton> createState() => _ShelfToggleButtonState();
}

class _ShelfToggleButtonState extends State<_ShelfToggleButton> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.state.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    final on = widget.state.contains(widget.novel.id);
    setState(() => _busy = true);
    try {
      await widget.state.setShelfMembership(
        widget.novel.id,
        !on,
        novel: widget.novel,
      );
      if (!mounted) return;
      showNovelFeedback(
        context,
        on ? '已移出书架' : '已加入书架：\${widget.novel.title}',
      );
    } catch (error) {
      if (!mounted) return;
      showNovelFeedback(context, '书架操作失败：\$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.state.contains(widget.novel.id);
    return GlassTextButton(
      key: const ValueKey('detail-shelf-toggle'),
      compact: true,
      onPressed: _busy ? null : _toggle,
      child: AppText(
        _busy ? '处理中…' : (on ? '✓ 已在书架' : '加入书架'),
      ),
    );
  }
}
`;

/* ───────── 2. LibraryState 接受 fromSync ───────── */
{
  const { file, text } = read('lib/library_state.dart');
  const FIND = `  Future<void> setShelfMembership(
    int id,
    bool present, {
    Novel? novel,
    int? restoredAddedAt,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setShelfMembership(
          id,
          present,
          novel: novel,
          restoredAddedAt: restoredAddedAt,
        ),
      );
    }`;
  const REPL = `  Future<void> setShelfMembership(
    int id,
    bool present, {
    Novel? novel,
    int? restoredAddedAt,
    bool fromSync = false,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setShelfMembership(
          id,
          present,
          novel: novel,
          restoredAddedAt: restoredAddedAt,
          fromSync: fromSync,
        ),
      );
    }`;

  if (text.includes('bool fromSync = false,')) {
    log('library_state.dart: fromSync 参数（已应用，跳过）');
  } else if (text.includes(FIND)) {
    fs.writeFileSync(file, text.replace(FIND, REPL), 'utf8');
    log('library_state.dart: 加 fromSync 参数');
  } else {
    console.error(
        '[detail-patch] library_state.dart 找不到 setShelfMembership 锚点');
    process.exit(1);
  }
}

/* ───────── 2. 本地书架按钮 ───────── */
{
  const { file, text } = read('lib/review_pages.dart');
  const FIND = `        final actions = [
          GlassTextButton(
            key: const ValueKey('detail-cloud-save'),`;
  const REPL = `        final actions = [
          // 真正的「加入书架」——写本地 LibraryState，点了立刻在书架见到。
          _ShelfToggleButton(state: state, novel: novel),
          GlassTextButton(
            key: const ValueKey('detail-cloud-save'),`;

  let src = text;
  if (!src.includes('_ShelfToggleButton(state: state, novel: novel)')) {
    if (!src.includes(FIND)) {
      console.error('[detail-patch] review_pages.dart 找不到 actions 锚点');
      process.exit(1);
    }
    src = src.replace(FIND, REPL);
    log('review_pages.dart: 插入书架按钮');
  } else {
    log('review_pages.dart: 书架按钮（已应用，跳过）');
  }

  if (!src.includes('class _ShelfToggleButton extends StatefulWidget')) {
    src += COMPONENT;
    log('review_pages.dart: 追加 _ShelfToggleButton 组件');
  } else {
    log('review_pages.dart: _ShelfToggleButton 组件（已应用，跳过）');
  }

  if (src !== text) fs.writeFileSync(file, src, 'utf8');
}

log('完成');
