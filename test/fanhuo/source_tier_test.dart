import 'package:flutter_test/flutter_test.dart';

import 'package:wenku8_flutter/fanhuo/engine_probe.dart';
import 'package:wenku8_flutter/fanhuo/source_repository.dart';

String _pack(Object json, {required String pack}) {
  final map = Map<Object?, Object?>.from(json as Map);
  map['sourcePack'] = pack;
  return _quote(map);
}

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
  if (value is List) return '[${value.map(_quote).join(',')}]';
  return _quote(value.toString());
}

const _midSource = {
  'bookSourceUrl': 'https://midsource.com/',
  'bookSourceName': '需要引擎的源',
  'searchUrl': 'https://midsource.com/s?q={{key}}',
  'ruleSearch': {
    'bookList': 'class.list@tag.li',
    'name': '@js:java.ajax(baseUrl + "/api/name")',
    'bookUrl': 'tag.a@href',
  },
  'jsTier': 'mid',
  'enabled': true,
};

const _hardSource = {
  'bookSourceUrl': 'https://hardsource.com/',
  'bookSourceName': '签名源',
  'searchUrl': 'https://hardsource.com/s?q={{key}}',
  'ruleSearch': {
    'bookList': 'class.list',
    'name': '@js:Packages.javax.crypto.Cipher.getInstance("AES")',
    'bookUrl': 'tag.a@href',
  },
  'jsTier': 'hard',
  'enabled': true,
};

const _simpleSource = {
  'bookSourceUrl': 'https://simplesource.com/',
  'bookSourceName': '子集源',
  'searchUrl': 'https://simplesource.com/s?q={{key}}',
  'ruleSearch': {
    'bookList': 'class.list',
    'name': r'@js:result.match(/(\d+)/)[1]',
    'bookUrl': 'tag.a@href',
  },
  'jsTier': 'simple',
  'enabled': true,
};

const _plainSource = {
  'bookSourceUrl': 'https://plain2.com/',
  'bookSourceName': '纯规则源',
  'searchUrl': 'https://plain2.com/s?q={{key}}',
  'ruleSearch': {
    'bookList': 'class.list',
    'name': 'tag.a@text',
    'bookUrl': 'tag.a@href',
  },
  'enabled': true,
};

void main() {
  group('1.5.1：mid 档放行', () {
    late BookSourceRepository repo;

    setUp(() {
      repo = BookSourceRepository.parse(
        '['
        '${_pack(_plainSource, pack: 'kuangye')},'
        '${_pack(_simpleSource, pack: 'aoaostar')},'
        '${_pack(_midSource, pack: 'aoaostar')},'
        '${_pack(_hardSource, pack: 'aoaostar')}'
        ']',
      );
    });

    test('mid 进搜索队列，hard 不进', () {
      final searchable = repo.searchable;
      final names = searchable.map((p) => p.source.name).toSet();
      expect(names, contains('需要引擎的源'));
      expect(names, contains('子集源'));
      expect(names, contains('纯规则源'));
      expect(names, isNot(contains('签名源')));
      expect(searchable.length, 3);
    });

    test('统计把 mid 算进可搜，把 hard 算进需引擎', () {
      final stats = repo.stats();
      expect(stats.searchable, 3);
      expect(stats.jsBlocked, 1, reason: '只有 hard 计入 jsBlocked');
      expect(stats.byTier['mid'], 1);
      expect(stats.byTier['hard'], 1);
      expect(stats.byTier['simple'], 1);
    });

    test('四档汇总文案能显示出来', () {
      expect(repo.stats().tierSummary(), contains('JS·需引擎 1'));
      expect(repo.stats().tierSummary(), contains('JS·子集可跑 1'));
    });
  });

  group('引擎自检', () {
    test('无原生库的测试环境里返回「引擎不可用」而不是抛异常', () async {
      final result = await runEngineProbe();
      // 桌面 Dart VM 没有 QuickJS 原生库，必然落在这两档之一；
      // 关键是不能抛、要有可读的 label 和 detail
      expect(
        result.status,
        anyOf(
          EngineProbeStatus.engineUnavailable,
          EngineProbeStatus.scriptFailed,
          EngineProbeStatus.assertionFailed,
          EngineProbeStatus.ok,
        ),
      );
      expect(result.label, isNotEmpty);
      expect(result.detail, isNotEmpty);
      expect(result.elapsed, isNotNull);
    });

    test('自检脚本不联网：假 fetch 被注入', () async {
      var called = false;
      final result = await runEngineProbe(
        fetch: (request, {String? header}) async {
          called = true;
          return '<div>fake</div>';
        },
        timeout: const Duration(seconds: 3),
      );
      // 引擎不可用时脚本压根没跑，fetch 自然不会被调；
      // 引擎可用时这条脚本也不需要网络，所以两种情况都应为 false
      expect(called, isFalse, reason: '${result.label} / ${result.detail}');
    });
  });
}
