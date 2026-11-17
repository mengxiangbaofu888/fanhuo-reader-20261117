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

  /// 直接给一批已打包的书源（开关状态过滤后用）。
  factory BookSourceRepository.fromPacked(List<PackedSource> packed) =>
      BookSourceRepository._(List<PackedSource>.unmodifiable(packed));

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

  /// 能搜的书源。
  ///
  /// 放行条件：
  ///   1. 启用 + 有 searchUrl
  ///   2. 规则里的 JS 属于**子集可执行档**（`jsTier` 为 none / simple），
  ///      或者没有 JS
  /// `mid`（要 QuickJS）与 `hard`（要 Java 反射）仍然剔掉，但管理页能看到。
  List<PackedSource> get searchable {
    return _searchableCache ??= _all.where((p) {
      final s = p.source;
      if (!s.enabled || !s.canSearch) return false;
      return switch (s.jsTier) {
        'mid' || 'hard' => false,
        'simple' => true,
        'none' || '' => !_ruleHasJs(s.searchRule) &&
            !_ruleHasJs(s.tocRule) &&
            !_ruleHasJs(s.contentRule) &&
            !_ruleHasJs(s.bookInfoRule),
        _ => false,
      };
    }).toList(growable: false);
  }

  static bool _ruleHasJs(SourceRule rule) {
    for (final value in rule.fields.values) {
      if (RuleEngine.needsJs(value)) return true;
    }
    return false;
  }

  /// 统计：给设置页显示「总 2301 / 可搜 1650 / 需 JS 651」这种概览。
  SourceStats stats() {
    var jsBlocked = 0;
    var explore = 0;
    final byPack = <SourcePack, int>{};
    final byTier = <String, int>{};
    for (final p in _all) {
      byPack[p.pack] = (byPack[p.pack] ?? 0) + 1;
      final s = p.source;
      byTier[s.jsTier.isEmpty ? 'none' : s.jsTier] =
          (byTier[s.jsTier.isEmpty ? 'none' : s.jsTier] ?? 0) + 1;
      if (!s.enabled) continue;
      if (s.canExplore) explore++;
      if (!s.canSearch) continue;
      if (s.jsTier == 'mid' || s.jsTier == 'hard') jsBlocked++;
    }
    return SourceStats(
      total: _all.length,
      searchable: searchable.length,
      jsBlocked: jsBlocked,
      explorable: explore,
      byPack: byPack,
      byTier: byTier,
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
    this.byTier = const {},
  });

  final int total;
  final int searchable;
  final int jsBlocked;
  final int explorable;
  final Map<SourcePack, int> byPack;

  /// JS 分档：none / simple / mid / hard 各多少条。
  final Map<String, int> byTier;

  String get summary =>
      '共 $total 条 · 可搜 $searchable · 需引擎 $jsBlocked · 带发现页 $explorable';

  String packSummary() =>
      byPack.entries.map((e) => '${e.key.label} ${e.value}').join(' · ');

  static const _tierLabels = {
    'none': '无 JS',
    'simple': 'JS·子集可跑',
    'mid': 'JS·需引擎',
    'hard': 'JS·不支持',
  };

  String tierSummary() => [
    for (final entry in _tierLabels.entries)
      if ((byTier[entry.key] ?? 0) > 0) '${entry.value} ${byTier[entry.key]}',
  ].join(' · ');
}
