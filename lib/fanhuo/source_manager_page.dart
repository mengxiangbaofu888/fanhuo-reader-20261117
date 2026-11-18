/// 书源管理页：看统计、按来源/分组筛、单条开关、预览规则。
///
/// 只做「看」和「开关」，不改规则内容 —— 改规则是另一件事（需要文本编辑器 + 校验）。
library;

import 'package:flutter/material.dart';

import 'book_source.dart';
import 'engine_probe.dart';
import 'fanqie_theme.dart';
import 'source_bootstrap.dart';
import 'source_repository.dart';

class SourceManagerPage extends StatefulWidget {
  const SourceManagerPage({
    super.key,
    required this.repository,
    this.onToggle,
  });

  final BookSourceRepository repository;

  /// 开关某条书源。返回 true 表示已保存。
  final Future<bool> Function(BookSource source, bool enabled)? onToggle;

  @override
  State<SourceManagerPage> createState() => _SourceManagerPageState();
}

class _SourceManagerPageState extends State<SourceManagerPage> {
  final _filter = TextEditingController();
  SourcePack? _pack;
  String _keyword = '';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
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
    final stats = widget.repository.stats();
    var list = widget.repository.query(_keyword);
    if (_pack != null) {
      list = list.where((p) => p.pack == _pack).toList(growable: false);
    }
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: paper.background,
        appBar: AppBar(
          title: const Text('书源管理'),
          backgroundColor: paper.background,
          foregroundColor: paper.ink,
          elevation: 0,
        ),
        body: Column(
          children: [
            _statsCard(stats, paper),
            _filters(paper),
            Expanded(
              child: list.isEmpty
                  ? Center(
                      child: Text('没有匹配的书源',
                          style: TextStyle(color: paper.raised(0.5))),
                    )
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) => _row(list[i], paper),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statsCard(SourceStats stats, FanqiePaper paper) {
    return Container(
      width: double.infinity,
      color: paper.raised(0.05),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stats.summary, style: TextStyle(color: paper.ink, fontSize: 13)),
          const SizedBox(height: 4),
          // 加载诊断：0 条时必须能看出是 asset 没进包还是解析失败
          Text(
            '加载：${FanhuoSourceBootstrap.instance.loadTrace}',
            style: TextStyle(
              fontSize: 11,
              color: stats.total == 0
                  ? Colors.red.shade700
                  : paper.raised(0.45),
            ),
          ),
          Text(stats.tierSummary(),
              style: TextStyle(color: paper.raised(0.55), fontSize: 12)),
          Text(stats.packSummary(),
              style: TextStyle(color: paper.raised(0.6), fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            'JS 分档：simple 走内置子集解释器，mid 走 QuickJS 引擎'
            '（两条都进搜索队列）；hard 依赖 Java 反射，不支持。',
            style: TextStyle(color: paper.raised(0.5), fontSize: 11),
          ),
          const SizedBox(height: 10),
          _probeRow(paper),
        ],
      ),
    );
  }

  /// 引擎自检按钮。点一次跑一段固定脚本，直接告诉你 QuickJS 在这台手机上能不能用。
  bool _probing = false;
  EngineProbeResult? _probeResult;

  Widget _probeRow(FanqiePaper paper) {
    final result = _probeResult;
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: _probing ? null : _runProbe,
          icon: _probing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_circle_outline, size: 18),
          label: Text(_probing ? '检测中…' : '引擎自检'),
          style: OutlinedButton.styleFrom(
            foregroundColor: paper.ink,
            side: BorderSide(color: paper.raised(0.25)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            textStyle: const TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(width: 10),
        if (result != null)
          Expanded(
            child: Text(
              '${result.label}：${result.detail}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: result.ok ? Colors.green.shade700 : Colors.red.shade700,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _runProbe() async {
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final result = await runEngineProbe();
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = result;
    });
  }

  Widget _filters(FanqiePaper paper) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        children: [
          TextField(
            controller: _filter,
            onChanged: (v) => setState(() => _keyword = v),
            style: TextStyle(color: paper.ink, fontSize: 14),
            decoration: InputDecoration(
              hintText: '按名字 / 域名 / 分组筛',
              hintStyle: TextStyle(color: paper.raised(0.45)),
              isDense: true,
              filled: true,
              fillColor: paper.raised(0.06),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _chip('全部', _pack == null, () => setState(() => _pack = null), paper),
              for (final pack in SourcePack.values)
                if (pack != SourcePack.unknown)
                  _chip(
                    pack.label,
                    _pack == pack,
                    () => setState(() => _pack = pack),
                    paper,
                  ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap, FanqiePaper paper) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? paper.ink : paper.raised(0.06),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? paper.background : paper.raised(0.7),
          ),
        ),
      ),
    );
  }

  Widget _row(PackedSource packed, FanqiePaper paper) {
    final source = packed.source;
    return ListTile(
      dense: true,
      title: Text(
        source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: paper.ink, fontSize: 14),
      ),
      subtitle: Text(
        '${packed.pack.label} · ${source.group.isEmpty ? "未分组" : source.group}'
        '${source.canSearch ? "" : " · 无搜索"}${_tierLabel(source.jsTier)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: paper.raised(0.55)),
      ),
      trailing: Switch(
        value: source.enabled,
        onChanged: widget.onToggle == null
            ? null
            : (v) async {
                final saved = await widget.onToggle!(source, v);
                if (saved && mounted) setState(() {});
              },
      ),
      onTap: () => _showDetail(source, paper),
    );
  }

  static String _tierLabel(String tier) => switch (tier) {
    'simple' => ' · JS·子集',
    'mid' => ' · JS·需引擎',
    'hard' => ' · JS·不支持',
    _ => '',
  };

  void _showDetail(BookSource source, FanqiePaper paper) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: paper.background,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: [
            Text(source.name,
                style: TextStyle(
                    color: paper.ink, fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _kv('地址', source.url, paper),
            _kv('分组', source.group, paper),
            _kv('搜索', source.searchUrl ?? '（无）', paper),
            _kv('发现', source.exploreUrl ?? '（无）', paper),
            for (final entry in source.searchRule.fields.entries)
              _kv('搜索·${entry.key}', entry.value, paper),
            for (final entry in source.tocRule.fields.entries)
              _kv('目录·${entry.key}', entry.value, paper),
            for (final entry in source.contentRule.fields.entries)
              _kv('正文·${entry.key}', entry.value, paper),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v, FanqiePaper paper) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: RichText(
          text: TextSpan(
            style: TextStyle(fontSize: 12, color: paper.raised(0.75)),
            children: [
              TextSpan(
                text: '$k：',
                style: TextStyle(fontWeight: FontWeight.w600, color: paper.ink),
              ),
              TextSpan(text: v),
            ],
          ),
        ),
      );
}
