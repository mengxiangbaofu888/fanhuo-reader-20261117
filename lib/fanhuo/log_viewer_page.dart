/// 日志查看页：不用连电脑，直接在 App 里看运行日志。
///
/// 为什么做成一页而不是「设置里显示几行」：书源加载、引擎执行这些
/// 一失败就静默的路径，需要**能复制、能滚动、能清空**的完整视图。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'fanqie_theme.dart';
import 'source_bootstrap.dart';
import 'source_explore_page.dart';

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  String _text = '读取中…';
  String _path = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final text = await AppLog.dump(lines: 1000);
    final path = await AppLog.directoryPath();
    if (!mounted) return;
    setState(() {
      _text = text.isEmpty ? '（暂无日志）' : text;
      _path = path;
      _loading = false;
    });
  }

  bool _exporting = false;

  /// 打包导出：日志文件 + 环境快照 + 书源概况。
  ///
  /// 导出物放在应用私有目录，路径会显示在弹窗里；用户用文件管理器
  /// 或 `adb pull` 取走即可。zip 是标准 store 模式，任何解压工具都能开。
  Future<void> _export(BuildContext context) async {
    setState(() => _exporting = true);
    try {
      // 附一份书源概况，排查时不用再问用户「你装了多少源」
      final bootstrap = FanhuoSourceBootstrap.instance;
      final repo = bootstrap.repository;
      final stats = repo.stats();
      final summary = StringBuffer()
        ..writeln('书源总数：${stats.total}')
        ..writeln('可搜：${stats.searchable}')
        ..writeln('需引擎：${stats.jsBlocked}')
        ..writeln('带发现页：${stats.explorable}')
        ..writeln('加载轨迹：${bootstrap.loadTrace}')
        ..writeln('加载错误：${bootstrap.loadError ?? "无"}')
        ..writeln('分档：${stats.tierSummary()}')
        ..writeln('来源：${stats.packSummary()}')
        ..writeln()
        ..writeln('前 50 个可探索源的分类入口数：');
      var shown = 0;
      for (final p in repo.all) {
        if (!p.source.canExplore) continue;
        final cats = parseExploreCategories(p.source.exploreUrl ?? '');
        summary.writeln(
            '  ${p.source.name} | 分类 ${cats.length} | ${p.source.url}');
        if (++shown >= 50) break;
      }

      final result = await AppLog.exportBundle(extraFiles: {
        '书源概况.txt': summary.toString(),
      });
      if (!mounted) return;
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导出失败，详见日志')),
        );
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('日志包已导出'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                result.path,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text('大小：${result.label}',
                  style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
              const Text(
                '用文件管理器进到该目录即可看到 .zip，\n'
                '或电脑上执行：\n'
                'adb pull /sdcard/Android/data/com.fanhuo.reader/files/logs\n'
                '（adb 不通时，用手机自带的文件管理直接分享）',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('好'),
            ),
          ],
        ),
      );
      await _reload();
    } finally {
      if (mounted) setState(() => _exporting = false);
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
          title: const Text('运行日志'),
          backgroundColor: paper.background,
          foregroundColor: paper.ink,
          elevation: 0,
          actions: [
            IconButton(
              tooltip: '导出日志包',
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.archive_outlined, color: paper.ink),
              onPressed: _exporting ? null : () => _export(context),
            ),
            IconButton(
              tooltip: '刷新',
              icon: Icon(Icons.refresh, color: paper.ink),
              onPressed: _loading ? null : _reload,
            ),
            IconButton(
              tooltip: '复制全部',
              icon: Icon(Icons.copy_all, color: paper.ink),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _text));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制')),
                );
              },
            ),
            IconButton(
              tooltip: '清空',
              icon: Icon(Icons.delete_outline, color: paper.ink),
              onPressed: () async {
                await AppLog.clear();
                await _reload();
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              color: paper.raised(0.05),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    '日志目录：$_path',
                    style: TextStyle(fontSize: 11, color: paper.raised(0.6)),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    '用 adb 取：adb shell run-as com.fanhuo.reader ls files/fanhuo-logs',
                    style: TextStyle(fontSize: 10, color: paper.raised(0.45)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      scrollDirection: Axis.vertical,
                      padding: const EdgeInsets.all(12),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SelectableText(
                          _text,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
