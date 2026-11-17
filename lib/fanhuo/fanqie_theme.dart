/// 番茄阅读页的配色与排版常量。
///
/// 全部数值来自对 `com.dragon.read` 7.3.7.33 的静态提取：
///   - 正文底色：`res/values/colors.xml` 的 `reader_*_theme_bg_light`
///   - 面板尺寸：`res/layout/e08.xml`（字号面板）、`arf.xml`（间距面板）、
///     `atp.xml`/`aq4.xml`（阅读菜单条）、`ame.xml`（字体面板）
///   - 文案：`res/values/strings.xml`（f6w=仿真 / f7p=覆盖 / drq=无动画 / bcb=点击屏幕翻页 …）
///
/// 这些是「配色数值 + 布局尺寸」这类事实，和番茄的代码、素材无关。
library;

import 'package:flutter/material.dart';

/// 番茄正文底色的五档。命名沿用番茄自己的 reader_<color>_theme_bg_light。
enum FanqiePaper {
  white('纯白', Color(0xFFD7D7DB), Color(0xFF2B2B2B)),
  yellow('暖黄', Color(0xFFF7E4CF), Color(0xFF3A3025)),
  green('护眼绿', Color(0xFFC9DECB), Color(0xFF2C332C)),
  blue('静谧蓝', Color(0xFFC2DEF0), Color(0xFF26323A)),
  black('夜间', Color(0xFF262626), Color(0xFFB8B8B8));

  const FanqiePaper(this.label, this.background, this.ink);

  final String label;
  final Color background;

  /// 正文墨色。番茄的 reader_*_theme_bg_light 只给了底色，
  /// 墨色取与底色同色相的深色，保证对比度 ≥ 7:1。
  final Color ink;

  bool get isDark => background.computeLuminance() < 0.4;

  /// 面板上用的一层「抬升色」：底色向墨色插值。
  Color raised(double amount) => Color.lerp(background, ink, amount)!;
}

/// 字号三档。番茄的字号面板是 3 档（小 / 适中 / 大），
/// 阅读页里再叠一个连续滑块微调，这里保留三档 + 1sp 步进。
enum FanqieFontScale {
  small('小', 15),
  medium('适中', 18),
  large('大', 21);

  const FanqieFontScale(this.label, this.sizeSp);
  final String label;
  final double sizeSp;
}

/// 行距三档（行高倍数）。
enum FanqieLineSpacing {
  tight('紧凑', 1.4),
  normal('标准', 1.7),
  loose('宽松', 2.0);

  const FanqieLineSpacing(this.label, this.factor);
  final String label;
  final double factor;
}

/// 段距三档（逻辑像素）。
enum FanqieParagraphSpacing {
  tight('紧凑', 4),
  normal('标准', 8),
  loose('宽松', 14);

  const FanqieParagraphSpacing(this.label, this.px);
  final String label;
  final double px;
}

/// 翻页四档。
///
/// 番茄的原文案来自 strings.xml：
///   `f6w` = 仿真、`f7p` = 覆盖、`drq` = 无动画，第四档「平滑」是默认档没有独立文案。
/// 「仅在左右翻页模式下生效」（`c19`）说明这四档全部只作用于分页模式。
enum FanqiePageEffect {
  simulation('仿真', '书页沿手指卷曲，松手按速度决定翻不翻', Duration(milliseconds: 480)),
  cover('覆盖', '新页从右侧盖住旧页，旧页不动', Duration(milliseconds: 340)),
  slide('平滑', '整页水平平移', Duration(milliseconds: 300)),
  none('无动画', '瞬切，最省电', Duration.zero);

  const FanqiePageEffect(this.label, this.note, this.duration);
  final String label;
  final String note;
  final Duration duration;

  /// 番茄把「上下模式」独立成一个 ReaderMode，翻页动效只对左右模式有意义。
  bool get onlyInPagedMode => true;
}

/// 番茄排版面板的几何常量（dp）。
abstract final class FanqieLayout {
  /// 面板标题栏高度：`MenuTitleView` 56dp，小屏变体 48dp。
  static const double panelTitleHeight = 56;
  static const double panelTitleHeightCompact = 48;

  /// 面板底部留白：`arf.xml` paddingBottom=40dp。
  static const double panelBottomPadding = 40;

  /// 选项条高度：`MultipleOptionsView` 32dp（字体面板 34dp）。
  static const double optionStripHeight = 32;
  static const double optionStripHeightFont = 34;

  /// 背景色卡：`e08.xml` 里五张 52dp × 28dp、无间距。
  static const double colorCardWidth = 52;
  static const double colorCardHeight = 28;
  static const int colorCardCount = 5;

  /// 文字规格：小节标签 12sp、选项文字 14sp、标题 18sp。
  static const double sectionLabelSize = 12;
  static const double optionTextSize = 14;
  static const double titleTextSize = 18;

  /// 阅读菜单条（`atp.xml`）高度 36dp，模块间距 16dp / 12dp。
  static const double readerBarHeight = 36;
  static const double barGap = 16;
  static const double barInnerGap = 12;
}

/// 沉浸式阅读页用的系统 UI 样式：底色跟随 FanqiePaper，图标明暗跟着变。
SystemUiStyle fanqieSystemUiStyle(FanqiePaper paper) => SystemUiStyle(
      statusBarBrightness: paper.isDark ? Brightness.dark : Brightness.light,
      statusBarIconBrightness: paper.isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: paper.background,
      systemNavigationBarIconBrightness:
          paper.isDark ? Brightness.light : Brightness.dark,
      statusBarColor: Colors.transparent,
    );

/// 把上面几项打包成阅读页主题，交给 Reader 的 Theme 继承。
ThemeData fanqieReaderTheme(
  ThemeData base,
  FanqiePaper paper, {
  required FanqieFontScale font,
  required FanqieLineSpacing line,
  required FanqieParagraphSpacing paragraph,
  String? fontFamily,
}) {
  final textTheme = base.textTheme
      .apply(
        fontFamily: fontFamily,
        bodyColor: paper.ink,
        displayColor: paper.ink,
      )
      .copyWith(
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: paper.ink,
          fontSize: font.sizeSp,
          height: line.factor,
          letterSpacing: 0.2,
        ),
      );
  return base.copyWith(
    scaffoldBackgroundColor: paper.background,
    canvasColor: paper.background,
    dividerColor: paper.raised(0.16),
    disabledColor: paper.raised(0.35),
    textTheme: textTheme,
    colorScheme: base.colorScheme.copyWith(
      surface: paper.background,
      onSurface: paper.ink,
      primary: paper.ink,
      onPrimary: paper.background,
      surfaceContainerLow: paper.raised(0.03),
      surfaceContainer: paper.raised(0.06),
      surfaceContainerHigh: paper.raised(0.10),
      outline: paper.raised(0.32),
      outlineVariant: paper.raised(0.18),
      surfaceTint: Colors.transparent,
    ),
    iconTheme: base.iconTheme.copyWith(color: paper.ink),
  );
}
