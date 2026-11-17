/// 番茄式阅读页设置模型 —— 与底座 `ReaderPreferences` 的桥接层。
///
/// 底座的 `ReaderPreferences` 管的是「底座自己的阅读器」（scroll / paged / vertical、
/// 5 档 pageEffect、paper 5 档）。番茄只有 3 档字号 + 3 档行距 + 3 档段距 + 4 档翻页，
/// 外加 5 套正文底色。这里做两件事：
///   1. 给 UI 一个「番茄视角」的模型（三档下拉，不是连续滑块）
///   2. 把它无损映射到底座的枚举与数值，落盘也走底座那套 JSON
library;

import 'dart:convert';

import 'fanqie_theme.dart';

/// 番茄视角的阅读页设置。
class FanqieReaderSettings {
  const FanqieReaderSettings({
    this.paper = FanqiePaper.yellow,
    this.font = FanqieFontScale.medium,
    this.line = FanqieLineSpacing.normal,
    this.paragraph = FanqieParagraphSpacing.normal,
    this.effect = FanqiePageEffect.simulation,
    this.pageMargins = 20,
    this.tapPaging = true,
    this.volumePaging = false,
    this.eyeProtection = false,
    this.smartMargin = true,
    this.pageTurnOnEdgeOnly = false,
  });

  final FanqiePaper paper;
  final FanqieFontScale font;
  final FanqieLineSpacing line;
  final FanqieParagraphSpacing paragraph;
  final FanqiePageEffect effect;

  /// 左右页边距（dp）。番茄的「智能匹配页边距」会根据字号和机型自动算，
  /// 这里保留用户手填值，智能开关只管初始值。
  final double pageMargins;
  final bool tapPaging;
  final bool volumePaging;
  final bool eyeProtection;
  final bool smartMargin;

  /// 番茄的「仅左右翻页模式」：分页时只在左右两侧点击翻页，中间区域呼出菜单。
  final bool pageTurnOnEdgeOnly;

  FanqieReaderSettings copyWith({
    FanqiePaper? paper,
    FanqieFontScale? font,
    FanqieLineSpacing? line,
    FanqieParagraphSpacing? paragraph,
    FanqiePageEffect? effect,
    double? pageMargins,
    bool? tapPaging,
    bool? volumePaging,
    bool? eyeProtection,
    bool? smartMargin,
    bool? pageTurnOnEdgeOnly,
  }) =>
      FanqieReaderSettings(
        paper: paper ?? this.paper,
        font: font ?? this.font,
        line: line ?? this.line,
        paragraph: paragraph ?? this.paragraph,
        effect: effect ?? this.effect,
        pageMargins: pageMargins ?? this.pageMargins,
        tapPaging: tapPaging ?? this.tapPaging,
        volumePaging: volumePaging ?? this.volumePaging,
        eyeProtection: eyeProtection ?? this.eyeProtection,
        smartMargin: smartMargin ?? this.smartMargin,
        pageTurnOnEdgeOnly: pageTurnOnEdgeOnly ?? this.pageTurnOnEdgeOnly,
      );

  Map<String, Object?> toJson() => {
        'paper': paper.name,
        'font': font.name,
        'line': line.name,
        'paragraph': paragraph.name,
        'effect': effect.name,
        'pageMargins': pageMargins,
        'tapPaging': tapPaging,
        'volumePaging': volumePaging,
        'eyeProtection': eyeProtection,
        'smartMargin': smartMargin,
        'pageTurnOnEdgeOnly': pageTurnOnEdgeOnly,
      };

  factory FanqieReaderSettings.fromJson(Map<String, dynamic> json) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    double clampMargin(Object? v) {
      if (v is! num || !v.isFinite) return 20;
      return v.toDouble().clamp(0, 80);
    }

    return FanqieReaderSettings(
      paper: pick(FanqiePaper.values, json['paper'], FanqiePaper.yellow),
      font: pick(FanqieFontScale.values, json['font'], FanqieFontScale.medium),
      line: pick(FanqieLineSpacing.values, json['line'], FanqieLineSpacing.normal),
      paragraph: pick(FanqieParagraphSpacing.values, json['paragraph'],
          FanqieParagraphSpacing.normal),
      effect: pick(FanqiePageEffect.values, json['effect'], FanqiePageEffect.simulation),
      pageMargins: clampMargin(json['pageMargins']),
      tapPaging: json['tapPaging'] != false,
      volumePaging: json['volumePaging'] == true,
      eyeProtection: json['eyeProtection'] == true,
      smartMargin: json['smartMargin'] != false,
      pageTurnOnEdgeOnly: json['pageTurnOnEdgeOnly'] == true,
    );
  }

  /// 从 SharedPreferences 里读出来的原始串恢复；坏了就回默认值。
  static FanqieReaderSettings fromRecord(Object? record) {
    if (record is! String || record.isEmpty) return const FanqieReaderSettings();
    try {
      final decoded = jsonDecode(record);
      if (decoded is! Map<String, dynamic>) return const FanqieReaderSettings();
      return FanqieReaderSettings.fromJson(decoded);
    } catch (_) {
      return const FanqieReaderSettings();
    }
  }

  String toRecord() => jsonEncode(toJson());

  /// 「智能匹配页边距」：字号越大，左右留白越多，避免一行太长。
  static double smartMarginFor(FanqieFontScale font, {double width = 400}) {
    final ratio = switch (font) {
      FanqieFontScale.small => 0.05,
      FanqieFontScale.medium => 0.065,
      FanqieFontScale.large => 0.08,
    };
    return (width * ratio).clamp(12, 40);
  }
}
