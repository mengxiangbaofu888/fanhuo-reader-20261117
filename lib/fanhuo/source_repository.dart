/// 书源仓库：加载合并后的书源包，提供「可用/可搜/可发现」的筛选与分组。
///
/// 数据来自 `assets/fanhuo/bookSources-merged.json`（旷野 133 + aoaostar 2168，已去重 2301 条）。
/// 这个文件 11.5 MB，全量 `jsonDecode` 在低端机上要 1～2 秒，
/// 所以加载是**懒的**（第一次真要搜书时才解），并且按需过滤，不预先建索引。
library;

import 'dart:convert';

import 'book_source.dart';
import 'rule_engine.dart';

/// 从哪来的书源。UI 上用来分组和显示来源徽标。
enum SourcePack {
  kuangye('旷野书屋'),
  aoaostar('aoaostar 阅读源'),
  unknown('未标注');

  const SourcePack(this.label);
  final String label;

  static SourcePack fromName(Object? name) {
    for (final p in SourcePack.values) {
      if (p.name == name) return p;
    }
    return SourcePack.unknown;
  }
}

/// 一条书源 + 它的来源包。
class PackedSource {
  const PackedSource(this.source, this.pack);
  final BookSource source;
  final SourcePack pack;
}

/// 加载与筛选。
class BookSourceRepository {
  BookSourceRepository._(this._all);

  final List<PackedSource> _all;
  List<PackedSource>? _searchableCache;

  List<PackedSource> get all => _all;
  int get length => _all.length;

  /// 从 JSON 文本构建。格式：数组，每项是 BookSource 字段 + 可选 `sourcePack`。
  static BookSourceRepository parse(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) {
      throw const FormatException('书源包必须是 JSON 数组');
    }
    final out = <PackedSource>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final source = BookSource.fromJson(item);
      if (source.url.isEmpty || source.name.isEmpty) continue;
      out.add(PackedSource(source, SourcePack.fromName(item['sourcePack'])));
    }
    return BookSourceRepository._(out);
  }

  /// 能搜的书源（有 searchUrl 且启用且规则里不含 JS）。
  ///
  /// 「不含 JS」这一条很关键：规则引擎跑不了 `@js:` / `<js>`，
  /// 早筛掉比让它们进搜索队列再一个个抛异常快得多。
  List<PackedSource> get searchable {
    return _searchableCache ??= _all.where((p) {
      final s = p.source;
      if (!s.enabled || !s.canSearch) return false;
      if (RuleEngine.needsJs(s.searchUrl!)) return false;
      if (_ruleHasJs(s.searchRule, s.tocRule, s.contentRule, s.bookInfoRule)) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  static bool _ruleHasJs(List<SourceRule> rules) {
    for (final rule in rules) {
      for (final value in rule.fields.values) {
        if (RuleEngine.needsJs(value)) return true;
      }
    }
    return false;
  }

  /// 统计：给设置页显示「总 2301 / 可搜 1650 / 需 JS 651」这种概览。
  SourceStats stats() {
    var searchableCount = 0;
    var jsBlocked = 0;
    var explore = 0;
    final byPack = <SourcePack, int>{};
    for (final p in _all) {
      byPack[p.pack] = (byPack[p.pack] ?? 0) + 1;
      final s = p.source;
      if (!s.enabled) continue;
      if (s.canExplore) explore++;
      if (!s.canSearch) continue;
      if (RuleEngine.needsJs(s.searchUrl!) ||
          _ruleHasJs([s.searchRule, s.tocRule, s.contentRule, s.bookInfoRule])) {
        jsBlocked++;
      } else {
        searchableCount++;
      }
    }
    return SourceStats(
      total: _all.length,
      searchable: searchableCount,
      jsBlocked: jsBlocked,
      explorable: explore,
      byPack: byPack,
    );
  }

  /// 按关键词搜书源本身（用户想找某个站点的源）。
  List<PackedSource> query(String keyword) {
    final key = keyword.trim().toLowerCase();
    if (key.isEmpty) return _all;
    return _all
        .where((p) =>
            p.source.name.toLowerCase().contains(key) ||
            p.source.url.toLowerCase().contains(key) ||
            p.source.group.toLowerCase().contains(key))
        .toList(growable: false);
  }

  /// 按分组列出（设置页的书源分组视图）。
  Map<String, List<PackedSource>> byGroup() {
    final map = <String, List<PackedSource>>{};
    for (final p in _all) {
      final group = p.source.group.isEmpty ? '未分组' : p.source.group;
      (map[group] ??= <PackedSource>[]).add(p);
    }
    return map;
  }
}

/// 概览统计。
class SourceStats {
  const SourceStats({
    required this.total,
    required this.searchable,
    required this.jsBlocked,
    required this.explorable,
    required this.byPack,
  });

  final int total;
  final int searchable;
  final int jsBlocked;
  final int explorable;
  final Map<SourcePack, int> byPack;

  String get summary =>
      '共 $total 条 · 可搜 $searchable · 需 JS $jsBlocked · 带发现页 $explorable';

  String packSummary() =>
      byPack.entries.map((e) => '${e.key.label} ${e.value}').join(' · ');
}
