import 'package:flutter_test/flutter_test.dart';

import 'package:wenku8_flutter/fanhuo/book_source.dart';
import 'package:wenku8_flutter/fanhuo/multi_source_search.dart';
import 'package:wenku8_flutter/fanhuo/rule_engine.dart';

const _sampleHtml = '''
<html><body>
  <div class="sitembox">
    <dl>
      <dt><a href="/book/1/"><img src="/img/1.jpg"></a></dt>
      <dd>
        <h3><a href="/book/1/">剑来</a></h3>
        <div class="book_other"><span>烽火戏诸侯</span><span>玄幻</span></div>
        <div class="book_des">一个少年提剑下山的故事。</div>
      </dd>
    </dl>
    <dl>
      <dt><a href="/book/2/"><img src="/img/2.jpg"></a></dt>
      <dd>
        <h3><a href="/book/2/">诡秘之主</a></h3>
        <div class="book_other"><span>爱潜水的乌贼</span><span>奇幻</span></div>
        <div class="book_des">蒸汽与机械的时代。</div>
      </dd>
    </dl>
  </div>
</body></html>
''';

const _sourceJson = '''
{
  "bookSourceUrl": "https://example.com/",
  "bookSourceName": "测试源",
  "bookSourceGroup": "测试",
  "bookSourceType": 0,
  "enabled": true,
  "enabledExplore": true,
  "searchUrl": "https://example.com/search.html,{\\n  \\"method\\": \\"POST\\",\\n  \\"body\\": \\"searchtype=all&searchkey={{key}}\\"\\n}",
  "exploreUrl": "玄幻::/xuanhuan/{{page}}.html",
  "header": "{\\"Cookie\\": \\"a=b\\"}",
  "ruleSearch": {
    "bookList": "class.sitembox@tag.dl",
    "name": "tag.dd@tag.h3@tag.a@text",
    "bookUrl": "tag.dd@tag.h3@tag.a@href",
    "author": "class.book_other.0@tag.span.0@text",
    "coverUrl": "tag.dt@tag.a@img@src",
    "intro": "class.book_des@text"
  },
  "ruleBookInfo": {"name": "id.info@h1@text"},
  "ruleToc": {"chapterList": "class.box_con@tag.dd"},
  "ruleContent": {"content": "id.content@html##广告|删掉"},
  "ruleExplore": {},
  "customOrder": 3,
  "weight": 5
}
''';

void main() {
  group('书源模型', () {
    test('18 字段解析完整', () {
      final source = BookSource.parseList('[$_sourceJson]').single;
      expect(source.name, '测试源');
      expect(source.url, 'https://example.com/');
      expect(source.group, '测试');
      expect(source.enabled, isTrue);
      expect(source.canSearch, isTrue);
      expect(source.canExplore, isTrue);
      expect(source.searchRule['bookList'], 'class.sitembox@tag.dl');
      expect(source.tocRule['chapterList'], 'class.box_con@tag.dd');
      expect(source.customOrder, 3);
      expect(source.weight, 5);
    });

    test('缺 searchUrl 的书源 canSearch 为假', () {
      final source = BookSource.fromJson({
        'bookSourceUrl': 'https://x.com/',
        'bookSourceName': '无搜索',
        'searchUrl': '',
      });
      expect(source.canSearch, isFalse);
      expect(source.canExplore, isFalse);
    });

    test('toJson 往返保留搜索规则', () {
      final source = BookSource.parseList('[$_sourceJson]').single;
      final again = BookSource.fromJson(source.toJson());
      expect(again.searchRule.toJson(), source.searchRule.toJson());
      expect(again.searchUrl, source.searchUrl);
    });
  });

  group('规则引擎', () {
    test('默认圆点规则逐段下钻', () {
      final doc = RuleEngine.parseHtml(_sampleHtml);
      final names = RuleEngine.selectNodes(doc, 'class.sitembox@tag.dl');
      expect(names.length, 2);

      final first = names.first;
      expect(RuleEngine.pickIn(first, doc, 'tag.dd@tag.h3@tag.a@text'), '剑来');
      expect(RuleEngine.pickIn(first, doc, 'tag.dd@tag.h3@tag.a@href'), '/book/1/');
      expect(RuleEngine.pickIn(first, doc, 'class.book_other.0@tag.span.0@text'), '烽火戏诸侯');
      expect(RuleEngine.pickIn(first, doc, 'class.book_des@text'), '一个少年提剑下山的故事。');
      expect(RuleEngine.pickIn(first, doc, 'tag.dt@tag.a@img@src'), '/img/1.jpg');
    });

    test('负索引取末尾元素', () {
      final doc = RuleEngine.parseHtml(_sampleHtml);
      final dl = RuleEngine.selectNodes(doc, 'class.sitembox@tag.dl');
      expect(RuleEngine.pickIn(dl.first, doc, 'class.book_other.0@tag.span.-1@text'), '玄幻');
    });

    test('@css: 前缀走 CSS 选择器', () {
      final doc = RuleEngine.parseHtml(_sampleHtml);
      expect(RuleEngine.pick(doc, '@css:.book_des'), contains('少年提剑'));
    });

    test('##正则##替换 提炼规则', () {
      final doc = RuleEngine.parseHtml('<div id="x">广告正文内容删掉</div>');
      expect(RuleEngine.pick(doc, 'id.x@text##广告|删掉'), '正文内容');
    });

    test('##正则（无替换）只保留匹配段', () {
      final doc = RuleEngine.parseHtml('<h1>《剑来》最新章节</h1>');
      // 注意：Dart 的 RegExp 用的是 re 语法，中文没有特殊含义
      expect(RuleEngine.pick(doc, 'tag.h1@text##《|》.*'), '剑来');
    });

    test('JS 规则明确抛 RuleUnsupported，不静默返回空', () {
      expect(RuleEngine.needsJs('@js:result'), isTrue);
      expect(RuleEngine.needsJs('<js>result</js>'), isTrue);
      expect(RuleEngine.needsJs('class.a@text'), isFalse);
      expect(() => RuleEngine.parse('@js:1+1'), throwsA(isA<RuleUnsupported>()));
    });

    test('XPath 前缀明确抛 RuleUnsupported', () {
      final doc = RuleEngine.parseHtml(_sampleHtml);
      expect(() => RuleEngine.pick(doc, '//div'), throwsA(isA<RuleUnsupported>()));
    });
  });

  group('URL 与请求构造', () {
    test('{{key}} 做 URL 编码，{{page}} 原样', () {
      final filled = RuleEngine.fillTemplate(
        'https://x.com/s?q={{key}}&p={{page}}',
        key: '剑 来',
        page: 3,
      );
      expect(filled, contains('p=3'));
      expect(filled, isNot(contains('{{')));
      expect(filled, contains('%E5%89%91'));
    });

    test('{{page+n}} 偏移', () {
      expect(
        RuleEngine.fillTemplate('/list/{{page+2}}.html', key: '', page: 1),
        '/list/3.html',
      );
    });

    test('JSON 形 searchUrl 拆成 POST + body', () {
      final request = RuleEngine.parseSearchUrl(
        'https://example.com/search.html,{"method":"POST","body":"searchtype=all&searchkey={{key}}"}',
        key: '剑来',
      );
      expect(request.method, 'POST');
      expect(request.url, 'https://example.com/search.html');
      expect(request.body, contains('searchtype=all'));
      expect(request.body, contains('%E5%89%91'));
    });

    test('纯 GET 的 searchUrl 不带 body', () {
      final request =
          RuleEngine.parseSearchUrl('https://x.com/s?q={{key}}', key: 'a');
      expect(request.method, 'GET');
      expect(request.body, isNull);
    });
  });

  group('多源并发搜书', () {
    // 假网络：按 domain 返回不同页面，并统计调用次数
    final calls = <String>[];

    Future<String> fakeFetch(SearchRequest request, {String? header}) async {
      calls.add(request.url);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return _sampleHtml;
    }

    final sources = [
      BookSource.parseList('[$_sourceJson]').single,
      BookSource.parseList('[$_sourceJson]').single.copyForTest(
        url: 'https://second.com/',
        name: '第二个源',
      ),
      BookSource.fromJson({
        'bookSourceUrl': 'https://none.com/',
        'bookSourceName': '没搜索规则的源',
      }),
    ];

    test('两个源都命中，无规则的源被跳过', () async {
      calls.clear();
      final search = MultiSourceSearch(sources: sources, fetch: fakeFetch);
      final results = await search.searchAll('剑来');
      expect(results.length, 2);
      expect(results.every((r) => r.ok), isTrue);
      expect(results[0].hits.length, 2);
      expect(results[1].hits.first.bookUrl, 'https://second.com/book/1/');
      // 没搜索规则的源不该发请求
      expect(calls.length, 2);
    });

    test('排序：完全命中排最前', () {
      final ranked = MultiSourceSearch.rank(
        [
          const SearchHit(
            name: '剑来外传',
            bookUrl: 'a',
            sourceName: 's',
            sourceUrl: 'u',
            costMs: 1,
          ),
          const SearchHit(
            name: '剑来',
            bookUrl: 'b',
            sourceName: 's',
            sourceUrl: 'u',
            costMs: 900,
          ),
        ],
        keyword: '剑来',
      );
      expect(ranked.first.name, '剑来');
    });

    test('单源超时被兜住，不影响别的源', () async {
      Future<String> slowFetch(SearchRequest request, {String? header}) async {
        if (request.url.contains('second')) {
          await Future<void>.delayed(const Duration(seconds: 5));
        }
        return _sampleHtml;
      }

      final search = MultiSourceSearch(
        sources: sources.take(2).toList(),
        fetch: slowFetch,
        perSourceTimeout: const Duration(milliseconds: 100),
      );
      final results = await search.searchAll('剑来');
      final timedOut = results.where((r) => r.error == '超时').toList();
      final ok = results.where((r) => r.ok).toList();
      expect(timedOut.length, 1);
      expect(ok.length, 1);
    });

    test('单源抛异常只影响它自己', () async {
      Future<String> brokenFetch(SearchRequest request, {String? header}) async {
        if (request.url.contains('second')) throw StateError('网络炸了');
        return _sampleHtml;
      }

      final search = MultiSourceSearch(
        sources: sources.take(2).toList(),
        fetch: brokenFetch,
      );
      final results = await search.searchAll('剑来');
      expect(results.where((r) => r.ok).length, 1);
      expect(results.where((r) => !r.ok).length, 1);
    });
  });
}

/// 测试内造第二个源用的小工具：不改生产代码就给一个新 URL。
extension on BookSource {
  BookSource copyForTest({required String url, required String name}) => BookSource(
        url: url,
        name: name,
        group: group,
        enabled: enabled,
        enabledExplore: enabledExplore,
        searchUrl: searchUrl,
        exploreUrl: exploreUrl,
        header: header,
        searchRule: searchRule,
        bookInfoRule: bookInfoRule,
        tocRule: tocRule,
        contentRule: contentRule,
        exploreRule: exploreRule,
      );
}