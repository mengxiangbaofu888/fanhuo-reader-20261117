/// 独立的「书源」首页 —— 一进去就能用，不依赖上游的私有内容接口。
///
/// 为什么要有这个入口：现在装上的版本一进首页就「加载失败」，
/// 因为上游 `main.dart` 在启动时就去连它自己的内容 API（`libcpp.so` 那套），
/// 而这个 API 不在公开源码里、本项目也没有。那条链路一失败，首屏就白。
///
/// 这一页的三块内容全部走本地 + 直连：
///   1. 搜索（书源搜书）
///   2. 书源管理（统计 / 筛选 / 开关）
///   3. 排版设置（番茄面板）
library;

import 'package:flutter/material.dart';

import '../catalog.dart';

import 'fanqie_panel.dart';
import 'fanqie_settings.dart';
import 'fanqie_theme.dart';
import 'multi_source_search.dart';
import 'source_manager_page.dart';
import 'source_repository.dart';
import 'source_search_page.dart';

/// 首屏三件套的壳。上游只要把这个 Widget 挂到「我的」或底部 tab，就有可用的首屏。
class FanhuoHome extends StatefulWidget {
  const FanhuoHome({
    super.key,
    required this.repository,
    required this.fetch,
    required this.settings,
    required this.onSettingsChanged,
    this.onOpenSearch,
    this.onToggleSource,
    this.onOpenNovel,
  });

  final BookSourceRepository repository;
  final SourceFetcher fetch;
  final FanqieReaderSettings settings;
  final ValueChanged<FanqieReaderSettings> onSettingsChanged;

  /// 想自己接管搜索页（比如接到上游的详情页）就传这个。
  final void Function()? onOpenSearch;
  final Future<bool> Function(BookSourceLike source, bool enabled)? onToggleSource;

  /// 书源书 → 上游阅读页。
  final Future<void> Function(Novel novel)? onOpenNovel;

  @override
  State<FanhuoHome> createState() => _FanhuoHomeState();
}

typedef BookSourceLike = dynamic;

class _FanhuoHomeState extends State<FanhuoHome> {
  late FanqieReaderSettings _settings = widget.settings;

  @override
  Widget build(BuildContext context) {
    final paper = _settings.paper;
    final theme = fanqieReaderTheme(
      ThemeData(brightness: paper.isDark ? Brightness.dark : Brightness.light),
      paper,
      font: _settings.font,
      line: _settings.line,
      paragraph: _settings.paragraph,
    );
    final stats = widget.repository.stats();
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: paper.background,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: [
              Text(
                '书源',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: paper.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                stats.summary,
                style: TextStyle(fontSize: 13, color: paper.raised(0.6)),
              ),
              Text(
                stats.packSummary(),
                style: TextStyle(fontSize: 12, color: paper.raised(0.45)),
              ),
              Text(
                stats.tierSummary(),
                style: TextStyle(fontSize: 11, color: paper.raised(0.38)),
              ),
              const SizedBox(height: 24),
              _bigCard(
                paper: paper,
                icon: Icons.search,
                title: '搜书',
                subtitle: '同时问 ${stats.searchable} 个书源，谁先回谁先上',
                onTap: widget.onOpenSearch ??
                    () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SourceSearchPage(
                              repository: widget.repository,
                              fetch: widget.fetch,
                              onOpenNovel: widget.onOpenNovel,
                            ),
                          ),
                        ),
              ),
              const SizedBox(height: 12),
              _bigCard(
                paper: paper,
                icon: Icons.list_alt,
                title: '书源管理',
                subtitle: '共 ${stats.total} 条，可按来源/分组筛、单条开关',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SourceManagerPage(
                      repository: widget.repository,
                      onToggle: widget.onToggleSource,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _bigCard(
                paper: paper,
                icon: Icons.text_fields,
                title: '阅读排版',
                subtitle:
                    '${paper.label} · ${_settings.font.label}字号 · ${_settings.effect.label}翻页',
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: Colors.transparent,
                  isScrollControlled: true,
                  builder: (_) => FanqieReaderPanel(
                    settings: _settings,
                    callbacks: FanqiePanelCallbacks(
                      onChanged: (next) {
                        setState(() => _settings = next);
                        widget.onSettingsChanged(next);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                '说明',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: paper.raised(0.55),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '这一页不连任何私有接口，断网也能打开（书源列表在本地）。\n'
                '搜书结果来自各书源站点本身，站点挂了那一条就没结果，属正常。',
                style: TextStyle(fontSize: 12, color: paper.raised(0.45), height: 1.6),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bigCard({
    required FanqiePaper paper,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: paper.raised(0.05),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: paper.ink, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: paper.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 12, color: paper.raised(0.55)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: paper.raised(0.35)),
            ],
          ),
        ),
      ),
    );
  }
}
