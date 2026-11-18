/// 日志查看页：不用连电脑，直接在 App 里看运行日志。
///
/// 为什么做成一页而不是「设置里显示几行」：书源加载、引擎执行这些
/// 一失败就静默的路径，需要**能复制、能滚动、能清空**的完整视图。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'fanqie_theme.dart';

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
    final text = await AppLog.dump(lines: 500);
    final path = await AppLog.directoryPath();
    if (!mounted) return;
    setState(() {
      _text = text.isEmpty ? '（暂无日志）' : text;
      _path = path;
      _loading = false;
    });
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
