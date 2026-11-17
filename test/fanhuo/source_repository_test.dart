import 'package:flutter_test/flutter_test.dart';

import 'package:wenku8_flutter/fanhuo/rule_engine.dart';
import 'package:wenku8_flutter/fanhuo/source_repository.dart';

const _plain = {
  'bookSourceUrl': 'https://plain.com/',
  'bookSourceName': '纯规则源',
  'bookSourceGroup': '精品',
  'searchUrl': 'https://plain.com/s?q={{key}}',
  'ruleSearch': {
    'bookList': 'class.list@tag.li',
    'name': 'tag.a@text',
    'bookUrl': 'tag.a@href',
  },
  'enabled': true,
};

const _jsSource = {
  'bookSourceUrl': 'https://withjs.com/',
  'bookSourceName': '带 JS 的源',
  'bookSourceGroup': '精品',
  'searchUrl': 'https://withjs.com/s?q={{key}}',
  'ruleSearch': {
    'bookList': 'class.list@tag.li',
    'name': '@js:result.trim()',
    'bookUrl': 'tag.a@href',
  },
  'enabled': true,
};

const _noSearch = {
  'bookSourceUrl': 'https://nosearch.com/',
  'bookSourceName': '没有搜索的源',
  'enabled': true,
};

const _disabled = {
  'bookSourceUrl': 'https://disabled.com/',
  'bookSourceName': '被关掉的源',
  'searchUrl': 'https://disabled.com/s?q={{key}}',
  'ruleSearch': {
    'bookList': 'class.x',
    'name': 'tag.a@text',
    'bookUrl': 'tag.a@href',
  },
  'enabled': false,
};

String _pack(Object json, {required String pack}) {
  final map = Map<Object?, Object?>.from(json as Map);
  map['sourcePack'] = pack;
  return _quote(map);
}

/// 极简的「对象 → JSON 字符串」，避免把 dart:convert 的用法写得太绕。
String _quote(Object? value) {
  if (value == null) return 'null';
  if (value is String) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n');
    return '"$escaped"';
  }
  if (value is num || value is bool) return '$value';
  if (value is Map) {
    final pairs = value.entries
        .map((e) => '${_quote(e.key.toString())}:${_quote(e.value)}')
        .join(',');
    return '{$pairs}';
  }
  if (value is List) {
    return '[${value.map(_quote).join(',')}]';
  }
  return _quote(value.toString());
}

void main() {
  group('书源仓库', () {
    late BookSourceRepository repo;

    setUp(() {
      final raw = '['
          '${_pack(_plain, pack: 'kuangye')},'
          '${_pack(_jsSource, pack: 'aoaostar')},'
          '${_pack(_noSearch, pack: 'aoaostar')},'
          '${_pack(_disabled, pack: 'aoaostar')}'
          ']';
      repo = BookSourceRepository.parse(raw);
    });

    test('解析：四条都能读进来，来源包正确', () {
      expect(repo.length, 4);
      expect(repo.all[0].pack, SourcePack.kuangye);
      expect(repo.all[1].pack, SourcePack.aoaostar);
      expect(repo.all[0].source.name, '纯规则源');
    });

    test('可搜：排除 JS 源、无搜索源、被关掉的源', () {
      final searchable = repo.searchable;
      expect(searchable.length, 1);
      expect(searchable.single.source.name, '纯规则源');
    });

    test('统计：JS 挡掉的能被单独数出来', () {
      final stats = repo.stats();
      expect(stats.total, 4);
      // 夹具没写 jsTier，走「规则里含 JS 就剔」的兜底分支；
      // jsBlocked 只统计 jsTier 为 mid/hard 的源（要真引擎的那些）。
      expect(stats.searchable, 1);
      expect(stats.jsBlocked, 0);
      expect(stats.byPack[SourcePack.kuangye], 1);
      expect(stats.byPack[SourcePack.aoaostar], 3);
      expect(stats.summary, contains('可搜 1'));
      expect(stats.packSummary(), contains('旷野书屋 1'));
    });

    test('关键词筛：名字 / 域名 / 分组都能命中', () {
      expect(repo.query('纯规则').length, 1);
      expect(repo.query('withjs').length, 1);
      expect(repo.query('精品').length, 2);
      expect(repo.query('').length, 4);
    });

    test('分组视图：空分组归到「未分组」', () {
      final groups = repo.byGroup();
      expect(groups['精品']!.length, 2);
      expect(groups['未分组']!.length, 2);
    });

    test('坏数据：不是数组就抛 FormatException', () {
      expect(
        () => BookSourceRepository.parse('{"a":1}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('坏条目：缺 url/name 的被丢掉，不炸整包', () {
      final r = BookSourceRepository.parse(
        '[${_pack(_plain, pack: 'kuangye')},{"bookSourceUrl":"","bookSourceName":""}]',
      );
      expect(r.length, 1);
    });
  });

  group('来源包标识', () {
    test('未知来源回落到 unknown', () {
      expect(SourcePack.fromName('nope'), SourcePack.unknown);
      expect(SourcePack.fromName(null), SourcePack.unknown);
      expect(SourcePack.fromName('kuangye'), SourcePack.kuangye);
    });
  });

  group('规则引擎：多段 tag 链（1.0.0 的回归点）', () {
    const html =
        '<div class="box"><p><a href="/x/"><img src="/c.jpg"></a></p></div>';

    test('tag.a@tag.img@src：img 是选择步不是取值步', () {
      final doc = RuleEngine.parseHtml(html);
      final img = RuleEngine.selectNodes(doc, 'class.box@tag.p@tag.a@tag.img');
      expect(img.length, 1, reason: '三步 tag 链应该能走到底');
      expect(RuleEngine.valueOf(img.first, 'tag.img@src'), '/c.jpg');
    });

    test('单步 pickIn 取属性仍然正常', () {
      final doc = RuleEngine.parseHtml(html);
      expect(RuleEngine.pick(doc, 'class.box@tag.p@tag.a@href'), '/x/');
    });

    test('裸 @text 是取值步，带点的 tag.text 是选择步', () {
      expect(RuleEngine.needsJs('@js:1'), isTrue);
      final doc = RuleEngine.parseHtml('<div class="t"><text>正文</text></div>');
      // tag.text 是「找 <text> 元素」
      expect(RuleEngine.pick(doc, 'class.t@tag.text@text'), '正文');
    });
  });
}
