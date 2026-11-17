/// 阅读格式书源（Legado BookSource 18 字段）的模型。
///
/// 字段命名严格对齐旷野书屋 `assets/defaultData/bookSources.json`
/// 与阅读（Legado）的 `BookSource`：两者字段逐一相同，所以可以直接互导。
library;

import 'dart:convert';

/// 一条书源规则里的一组搜索/详情/目录/正文规则。
class SourceRule {
  const SourceRule(this.fields);

  final Map<String, String> fields;

  String? operator [](String key) {
    final value = fields[key];
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool get isEmpty => fields.isEmpty;

  Map<String, Object?> toJson() => Map<String, Object?>.from(fields);
}

/// 一个书源。
class BookSource {
  const BookSource({
    required this.url,
    required this.name,
    this.group = '',
    this.type = 0,
    this.enabled = true,
    this.enabledExplore = false,
    this.searchUrl,
    this.exploreUrl,
    this.header,
    this.loginUrl,
    this.loginCheckJs,
    this.bookUrlPattern,
    this.customOrder = 0,
    this.weight = 0,
    this.comment = '',
    this.searchRule = const SourceRule({}),
    this.bookInfoRule = const SourceRule({}),
    this.tocRule = const SourceRule({}),
    this.contentRule = const SourceRule({}),
    this.exploreRule = const SourceRule({}),
    this.probeStatus = '',
    this.jsTier = '',
  });

  final String url;
  final String name;
  final String group;

  /// 0=文本 1=音频 2=图片 3=文件。旷野 133 个源全是 0。
  final int type;
  final bool enabled;
  final bool enabledExplore;
  final String? searchUrl;
  final String? exploreUrl;
  final String? header;
  final String? loginUrl;
  final String? loginCheckJs;
  final String? bookUrlPattern;
  final int customOrder;
  final int weight;
  final String comment;
  final SourceRule searchRule;
  final SourceRule bookInfoRule;
  final SourceRule tocRule;
  final SourceRule contentRule;
  final SourceRule exploreRule;

  /// 首页探测结果：HTTP 状态码字符串，"0" 表示连不上。
  /// 只有跑过 `scripts/probe-sources.js` 才有值。
  final String probeStatus;

  /// 仓库预打的分级：'' / none / simple / mid / hard。
  /// 由合并脚本按脚本用到的 API 判档写进 JSON，运行时只读不算。
  final String jsTier;

  bool get canSearch => searchUrl != null && searchUrl!.isNotEmpty;
  bool get canExplore => enabledExplore && exploreUrl != null && exploreUrl!.isNotEmpty;

  /// 首页可达（不代表能搜到书）。
  bool get homepageReachable => probeStatus == '200';

  static Map<String, String> _ruleFromJson(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.value is String) '${entry.key}': entry.value as String,
    };
  }

  factory BookSource.fromJson(Map<String, dynamic> json) {
    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    return BookSource(
      url: (json['bookSourceUrl'] as String? ?? '').trim(),
      name: (json['bookSourceName'] as String? ?? '').trim(),
      group: (json['bookSourceGroup'] as String? ?? '').trim(),
      type: json['bookSourceType'] is int ? json['bookSourceType'] as int : 0,
      enabled: json['enabled'] != false,
      enabledExplore: json['enabledExplore'] == true,
      searchUrl: str(json['searchUrl']),
      exploreUrl: str(json['exploreUrl']),
      header: str(json['header']),
      loginUrl: str(json['loginUrl']),
      loginCheckJs: str(json['loginCheckJs']),
      bookUrlPattern: str(json['bookUrlPattern']),
      customOrder: json['customOrder'] is int ? json['customOrder'] as int : 0,
      weight: json['weight'] is int ? json['weight'] as int : 0,
      comment: (json['bookSourceComment'] as String? ?? '').trim(),
      searchRule: SourceRule(_ruleFromJson(json['ruleSearch'])),
      bookInfoRule: SourceRule(_ruleFromJson(json['ruleBookInfo'])),
      tocRule: SourceRule(_ruleFromJson(json['ruleToc'])),
      contentRule: SourceRule(_ruleFromJson(json['ruleContent'])),
      exploreRule: SourceRule(_ruleFromJson(json['ruleExplore'])),
      probeStatus: json['probeStatus']?.toString() ?? '',
      jsTier: json['jsTier']?.toString() ?? '',
    );
  }

  Map<String, Object?> toJson() => {
        'bookSourceUrl': url,
        'bookSourceName': name,
        'bookSourceGroup': group,
        'bookSourceType': type,
        'bookSourceComment': comment,
        'enabled': enabled,
        'enabledExplore': enabledExplore,
        'searchUrl': searchUrl ?? '',
        'exploreUrl': exploreUrl ?? '',
        'header': header ?? '',
        'loginUrl': loginUrl ?? '',
        'loginCheckJs': loginCheckJs ?? '',
        'bookUrlPattern': bookUrlPattern ?? '',
        'customOrder': customOrder,
        'weight': weight,
        'ruleSearch': searchRule.toJson(),
        'ruleBookInfo': bookInfoRule.toJson(),
        'ruleToc': tocRule.toJson(),
        'ruleContent': contentRule.toJson(),
        'ruleExplore': exploreRule.toJson(),
        if (probeStatus.isNotEmpty) 'probeStatus': probeStatus,
      };

  /// 解析一段书源 JSON（数组或单个对象都吃）。
  static List<BookSource> parseList(String raw) {
    final decoded = jsonDecode(raw);
    final list = decoded is List ? decoded : [decoded];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) BookSource.fromJson(item),
    ].where((s) => s.url.isNotEmpty && s.name.isNotEmpty).toList();
  }
}
