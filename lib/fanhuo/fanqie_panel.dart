/// 番茄式阅读设置面板（Dart/Flutter）。
///
/// 视觉规格全部抄自番茄 `com.dragon.read` 7.3.7.33 的 layout：
///   - 标题栏 56dp，标题 18sp（`MenuTitleView`）
///   - 小节标签 12sp，左对齐（`arf.xml` / `e08.xml` 的 `TextView textSize=12sp`）
///   - 选项条 32dp 高、圆角、选中项高亮（`MultipleOptionsView`）
///   - 背景五色卡：52×28dp，横排无间隙（`e08.xml` 的 ipi…ipc）
///   - 面板底部留白 40dp
///
/// 逻辑部分只管回调，不碰存储——状态由外面的 [FanqieReaderSettings] 持有。
library;

import 'package:flutter/material.dart';

import 'fanqie_settings.dart';
import 'fanqie_theme.dart';

/// 面板回调。每个字段一个回调，谁变了只通知谁。
class FanqiePanelCallbacks {
  const FanqiePanelCallbacks({
    required this.onChanged,
    this.onOpenFontManager,
    this.onOpenAiProofread,
  });

  final ValueChanged<FanqieReaderSettings> onChanged;
  final VoidCallback? onOpenFontManager;

  /// 底部「AI 纠错」入口，点了直接对当前章跑一次。
  final VoidCallback? onOpenAiProofread;
}

class FanqieReaderPanel extends StatelessWidget {
  const FanqieReaderPanel({
    super.key,
    required this.settings,
    required this.callbacks,
    this.showAiEntry = true,
  });

  final FanqieReaderSettings settings;
  final FanqiePanelCallbacks callbacks;
  final bool showAiEntry;

  @override
  Widget build(BuildContext context) {
    final paper = settings.paper;
    final theme = fanqieReaderTheme(
      ThemeData(brightness: paper.isDark ? Brightness.dark : Brightness.light),
      paper,
      font: settings.font,
      line: settings.line,
      paragraph: settings.paragraph,
    );
    return Theme(
      data: theme,
      child: Material(
        color: paper.background,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: FanqieLayout.panelBottomPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _title(context),
                _section(
                  label: '字号',
                  child: _optionStrip<FanqieFontScale>(
                    context,
                    values: FanqieFontScale.values,
                    current: settings.font,
                    labelOf: (v) => v.label,
                    onPick: (v) => callbacks.onChanged(settings.copyWith(font: v)),
                  ),
                ),
                _section(
                  label: '行距',
                  child: _optionStrip<FanqieLineSpacing>(
                    context,
                    values: FanqieLineSpacing.values,
                    current: settings.line,
                    labelOf: (v) => v.label,
                    onPick: (v) => callbacks.onChanged(settings.copyWith(line: v)),
                  ),
                ),
                _section(
                  label: '段距',
                  child: _optionStrip<FanqieParagraphSpacing>(
                    context,
                    values: FanqieParagraphSpacing.values,
                    current: settings.paragraph,
                    labelOf: (v) => v.label,
                    onPick: (v) =>
                        callbacks.onChanged(settings.copyWith(paragraph: v)),
                  ),
                ),
                _section(label: '背景', child: _colorCards(context)),
                _section(label: '翻页', child: _pageEffects(context)),
                if (paper.isDark == false)
                  _section(label: '护眼', child: _switches(context)),
                if (paper.isDark) _section(label: '夜间', child: _switches(context)),
                if (showAiEntry) _aiEntry(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(BuildContext context) {
    final paper = settings.paper;
    return SizedBox(
      height: FanqieLayout.panelTitleHeight,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            '阅读设置',
            style: TextStyle(
              fontSize: FanqieLayout.titleTextSize,
              fontWeight: FontWeight.w600,
              color: paper.ink,
            ),
          ),
          Positioned(
            right: 8,
            child: IconButton(
              tooltip: '字体',
              icon: Icon(Icons.format_size, color: paper.ink),
              onPressed: callbacks.onOpenFontManager,
            ),
          ),
          Positioned(
            left: 8,
            child: IconButton(
              tooltip: '关闭',
              icon: Icon(Icons.keyboard_arrow_down, color: paper.ink),
              onPressed: () => Navigator.maybePop(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section({required String label, required Widget child}) {
    final paper = settings.paper;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: TextStyle(
                fontSize: FanqieLayout.sectionLabelSize,
                color: paper.raised(0.64),
              ),
            ),
          ),
          const SizedBox(width: FanqieLayout.barInnerGap),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _optionStrip<T extends Enum>({
    required BuildContext context,
    required List<T> values,
    required T current,
    required String Function(T) labelOf,
    required ValueChanged<T> onPick,
  }) {
    final paper = settings.paper;
    return Container(
      height: FanqieLayout.optionStripHeight,
      decoration: BoxDecoration(
        color: paper.raised(0.06),
        borderRadius: BorderRadius.circular(FanqieLayout.optionStripHeight / 2),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        children: [
          for (final value in values)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onPick(value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == current ? paper.background : Colors.transparent,
                    borderRadius:
                        BorderRadius.circular(FanqieLayout.optionStripHeight / 2),
                  ),
                  child: Text(
                    labelOf(value),
                    style: TextStyle(
                      fontSize: FanqieLayout.optionTextSize,
                      fontWeight: value == current ? FontWeight.w600 : FontWeight.w400,
                      color: value == current ? paper.ink : paper.raised(0.64),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _colorCards(BuildContext context) {
    final paper = settings.paper;
    return SizedBox(
      height: FanqieLayout.colorCardHeight,
      child: Row(
        children: [
          for (final candidate in FanqiePaper.values)
            GestureDetector(
              onTap: () => callbacks.onChanged(settings.copyWith(paper: candidate)),
              child: Container(
                width: FanqieLayout.colorCardWidth,
                height: FanqieLayout.colorCardHeight,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: candidate.background,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: candidate == paper ? paper.ink : paper.raised(0.18),
                    width: candidate == paper ? 1.6 : 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  candidate.label,
                  style: TextStyle(fontSize: 10, color: candidate.ink),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pageEffects(BuildContext context) {
    final paper = settings.paper;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _optionStrip<FanqiePageEffect>(
          context,
          values: FanqiePageEffect.values,
          current: settings.effect,
          labelOf: (v) => v.label,
          onPick: (v) => callbacks.onChanged(settings.copyWith(effect: v)),
        ),
        const SizedBox(height: 6),
        Text(
          '${settings.effect.label}：${settings.effect.note}',
          style: TextStyle(fontSize: 11, color: paper.raised(0.52)),
        ),
        Text(
          '翻页动效仅在左右翻页模式下生效；上下滚动时按滚动处理。',
          style: TextStyle(fontSize: 11, color: paper.raised(0.52)),
        ),
      ],
    );
  }

  Widget _switches(BuildContext context) {
    final paper = settings.paper;
    Widget row(String label, bool value, ValueChanged<bool> onToggle) => SizedBox(
          height: 30,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: FanqieLayout.optionTextSize, color: paper.ink),
                ),
              ),
              Transform.scale(
                scale: 0.8,
                child: Switch(value: value, onChanged: onToggle),
              ),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row('点击屏幕翻页', settings.tapPaging,
            (v) => callbacks.onChanged(settings.copyWith(tapPaging: v))),
        row('音量键翻页', settings.volumePaging,
            (v) => callbacks.onChanged(settings.copyWith(volumePaging: v))),
        row('仅左右翻页区域翻页', settings.pageTurnOnEdgeOnly,
            (v) => callbacks.onChanged(settings.copyWith(pageTurnOnEdgeOnly: v))),
        row('护眼模式', settings.eyeProtection,
            (v) => callbacks.onChanged(settings.copyWith(eyeProtection: v))),
        row('智能匹配页边距', settings.smartMargin,
            (v) => callbacks.onChanged(settings.copyWith(smartMargin: v))),
      ],
    );
  }

  Widget _aiEntry(BuildContext context) {
    final paper = settings.paper;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SizedBox(
        height: 40,
        child: OutlinedButton.icon(
          onPressed: callbacks.onOpenAiProofread,
          icon: Icon(Icons.auto_fix_high, size: 18, color: paper.ink),
          label: Text('AI 纠错本章', style: TextStyle(color: paper.ink)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: paper.raised(0.24)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
        ),
      ),
    );
  }
}
