import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wenku8_flutter/fanhuo/ai_proofread.dart';
import 'package:wenku8_flutter/fanhuo/book_source.dart';
import 'package:wenku8_flutter/fanhuo/fanqie_settings.dart';
import 'package:wenku8_flutter/fanhuo/fanqie_theme.dart';
import 'package:wenku8_flutter/fanhuo/multi_source_search.dart';
import 'package:wenku8_flutter/fanhuo/rule_engine.dart';

/// 番茄配色与排版常量：钉死从 resources.arsc 里读出来的那几个值。
/// 这几行是「抄错了就红」的护栏。
void main() {
  group('番茄配色', () {
    test('五套正文底色与番茄 reader_*_theme_bg_light 一致', () {
      expect(FanqiePaper.white.background, const Color(0xFFD7D7DB));
      expect(FanqiePaper.yellow.background, const Color(0xFFF7E4CF));
      expect(FanqiePaper.green.background, const Color(0xFFC9DECB));
      expect(FanqiePaper.blue.background, const Color(0xFFC2DEF0));
      expect(FanqiePaper.black.background, const Color(0xFF262626));
    });

    test('墨色与底色的对比度 ≥ 7:1（WCAG AAA 正文）', () {
      for (final paper in FanqiePaper.values) {
        final l1 = paper.background.computeLuminance();
        final l2 = paper.ink.computeLuminance();
        final brighter = l1 > l2 ? l1 : l2;
        final darker = l1 > l2 ? l2 : l1;
        final contrast = (brighter + 0.05) / (darker + 0.05);
        expect(
          contrast,
          greaterThanOrEqualTo(7.0),
          reason: '${paper.label} 的对比度只有 ${contrast.toStringAsFixed(2)}:1',
        );
      }
    });

    test('只有夜间是暗色', () {
      expect(FanqiePaper.black.isDark, isTrue);
      for (final paper in [
        FanqiePaper.white,
        FanqiePaper.yellow,
        FanqiePaper.green,
        FanqiePaper.blue,
      ]) {
        expect(paper.isDark, isFalse, reason: paper.label);
      }
    });

    test('翻页四档齐全且只有无动画是零时长', () {
      expect(FanqiePageEffect.values.length, 4);
      expect(FanqiePageEffect.none.duration, Duration.zero);
      for (final effect in [
        FanqiePageEffect.simulation,
        FanqiePageEffect.cover,
        FanqiePageEffect.slide,
      ]) {
        expect(effect.duration, greaterThan(Duration.zero), reason: effect.label);
      }
      expect(FanqiePageEffect.values.every((e) => e.onlyInPagedMode), isTrue);
    });

    test('面板几何取自 e08.xml / arf.xml', () {
      expect(FanqieLayout.panelTitleHeight, 56);
      expect(FanqieLayout.panelBottomPadding, 40);
      expect(FanqieLayout.optionStripHeight, 32);
      expect(FanqieLayout.colorCardWidth, 52);
      expect(FanqieLayout.colorCardHeight, 28);
      expect(FanqieLayout.colorCardCount, FanqiePaper.values.length);
      expect(FanqieLayout.sectionLabelSize, 12);
      expect(FanqieLayout.optionTextSize, 14);
      expect(FanqieLayout.titleTextSize, 18);
    });
  });

  group('番茄式阅读设置', () {
    test('默认值合理', () {
      const s = FanqieReaderSettings();
      expect(s.paper, FanqiePaper.yellow);
      expect(s.font, FanqieFontScale.medium);
      expect(s.effect, FanqiePageEffect.simulation);
      expect(s.tapPaging, isTrue);
    });

    test('JSON 往返不丢字段', () {
      const original = FanqieReaderSettings(
        paper: FanqiePaper.green,
        font: FanqieFontScale.large,
        line: FanqieLineSpacing.loose,
        paragraph: FanqieParagraphSpacing.tight,
        effect: FanqiePageEffect.cover,
        pageMargins: 33,
        volumePaging: true,
        eyeProtection: true,
        smartMargin: false,
      );
      final restored = FanqieReaderSettings.fromRecord(original.toRecord());
      expect(restored.toRecord(), original.toRecord());
    });

    test('坏数据回默认值，不抛异常', () {
      expect(FanqieReaderSettings.fromRecord(null).paper, FanqiePaper.yellow);
      expect(FanqieReaderSettings.fromRecord('不是 json').paper, FanqiePaper.yellow);
      expect(FanqieReaderSettings.fromRecord('{"paper":"不存在"}').paper,
          FanqiePaper.yellow);
    });

    test('页边距超范围会被夹住', () {
      final s = FanqieReaderSettings.fromJson({'pageMargins': 9999});
      expect(s.pageMargins, lessThanOrEqualTo(80));
      final t = FanqieReaderSettings.fromJson({'pageMargins': -5});
      expect(t.pageMargins, greaterThanOrEqualTo(0));
    });

    test('智能页边距随字号变大', () {
      final small = FanqieReaderSettings.smartMarginFor(FanqieFontScale.small);
      final medium = FanqieReaderSettings.smartMarginFor(FanqieFontScale.medium);
      final large = FanqieReaderSettings.smartMarginFor(FanqieFontScale.large);
      expect(small, lessThan(medium));
      expect(medium, lessThan(large));
    });
  });
}