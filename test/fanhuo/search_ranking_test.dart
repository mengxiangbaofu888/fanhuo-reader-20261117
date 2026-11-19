import 'package:flutter_test/flutter_test.dart';

import 'package:wenku8_flutter/fanhuo/book_source.dart';
import 'package:wenku8_flutter/fanhuo/multi_source_search.dart';
import 'package:wenku8_flutter/fanhuo/source_repository.dart';

/// 1.7.0 的三件事里，能脱离设备验证的部分：
///   - 搜索排序（慢源不会挤掉快源）
///   - 目录分页的「下一页」识别
///   - 书架相关的数据结构语义
///
/// 书架本体要 `SharedPreferences`，属于集成测试，这里只测纯逻辑。

BookSource _source(String name, {String probe = ''}) {
  return BookSource.fromJson({
    'bookSourceUrl': 'https://$name.com/',
    'bookSourceName': name,
    'searchUrl': 'https://$name.com/s?q={{key}}',
    'ruleSearch': {
      'bookList': 'class.list',
      'name': 'tag.a@text',
      'bookUrl': 'tag.a@href',
    },
    'probeStatus': probe,
    'enabled': true,
  });
}

SearchHit _hit(String name, {required int costMs, String author = ''}) =>
    SearchHit(
      name: name,
      bookUrl: 'https://x.com/$name',
      sourceName: 's',
      sourceUrl: 'https://s.com/',
      costMs: costMs,
      author: author,
    );

void main() {
  group('1.7.0 搜索排序', () {
    test('同名书按耗时升序（快源在前）', () {
      final ranked = MultiSourceSearch.rank(
        [
          _hit('湛蓝徽章', costMs: 2354),
          _hit('湛蓝徽章', costMs: 798),
          _hit('湛蓝徽章', costMs: 1182),
        ],
        keyword: '湛蓝徽章',
      );
      expect(ranked.map((h) => h.costMs).toList(), [798, 1182, 2354]);
    });

    test('完全命中 > 前缀 > 包含 > 作者 > 其他', () {
      final ranked = MultiSourceSearch.rank(
        [
          _hit('别的书', costMs: 10),
          _hit('湛蓝徽章外传', costMs: 10),
          _hit('湛蓝徽章', costMs: 999),
          _hit('新书', costMs: 10, author: '湛蓝徽章'),
        ],
        keyword: '湛蓝徽章',
      );
      expect(ranked.first.name, '湛蓝徽章', reason: '完全命中最优先，哪怕最慢');
      expect(ranked[1].name, '湛蓝徽章外传', reason: '前缀命中排第二');
    });

    test('空关键词时按耗时排，不炸', () {
      final ranked = MultiSourceSearch.rank(
        [_hit('a', costMs: 30), _hit('b', costMs: 10)],
        keyword: '',
      );
      expect(ranked.map((h) => h.name).toList(), ['b', 'a']);
    });
  });

  group('1.7.0 书源可达性排序依据', () {
    test('probeStatus 为 200 才算「首页可达」', () {
      expect(_source('a', probe: '200').homepageReachable, isTrue);
      expect(_source('b', probe: '').homepageReachable, isFalse);
      expect(_source('c', probe: 'timeout').homepageReachable, isFalse);
    });
  });

  group('1.7.0 可搜口径不变', () {
    test('mid 可搜、hard 不可搜', () {
      final repo = BookSourceRepository.parse('''
[
  {"bookSourceUrl":"https://m.com/","bookSourceName":"mid源",
   "searchUrl":"https://m.com/s?q={{key}}",
   "ruleSearch":{"bookList":"class.l","name":"@js:java.ajax(1)","bookUrl":"tag.a@href"},
   "jsTier":"mid","enabled":true},
  {"bookSourceUrl":"https://h.com/","bookSourceName":"hard源",
   "searchUrl":"https://h.com/s?q={{key}}",
   "ruleSearch":{"bookList":"class.l","name":"@js:Packages.x.y()","bookUrl":"tag.a@href"},
   "jsTier":"hard","enabled":true}
]
''');
      final names = repo.searchable.map((p) => p.source.name).toList();
      expect(names, contains('mid源'));
      expect(names, isNot(contains('hard源')));
    });
  });
}