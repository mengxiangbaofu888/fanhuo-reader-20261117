import 'package:flutter_test/flutter_test.dart';

import 'package:wenku8_flutter/fanhuo/js_host_api.dart';
import 'package:wenku8_flutter/fanhuo/multi_source_search.dart';
import 'package:wenku8_flutter/fanhuo/rule_engine.dart';

/// 一个可控的假 fetch：记下请求，按 URL 决定返回什么。
class FakeFetch {
  FakeFetch(this.responses);
  final Map<String, String> responses;
  final List<String> requested = [];

  Future<String> call(SearchRequest request, {String? header}) async {
    requested.add(request.url);
    for (final entry in responses.entries) {
      if (request.url.contains(entry.key)) return entry.value;
    }
    return '';
  }
}

JsRuntimeContext _context({
  required Future<String> Function(SearchRequest, {String? header}) fetch,
  List<String> hosts = const ['example.com'],
  String result = '',
  String baseUrl = '',
  String key = '',
}) =>
    JsRuntimeContext(
      fetch: fetch,
      allowList: HostAllowList(hosts),
      result: result,
      baseUrl: baseUrl,
      key: key,
      now: DateTime(2026, 11, 18, 9, 5, 7),
    );

void main() {
  group('域名白名单', () {
    test('主域与子域都放行', () {
      final list = HostAllowList(['https://www.example.com/book/1']);
      expect(list.allows('https://www.example.com/api'), isTrue);
      expect(list.allows('https://m.example.com/x'), isTrue);
      expect(list.allows('https://example.com/x'), isTrue);
    });

    test('CDN 同根域放行', () {
      final list = HostAllowList(['https://www.example.com/']);
      expect(list.allows('https://img01.example.com/a.jpg'), isTrue);
    });

    test('别的域拒绝', () {
      final list = HostAllowList(['https://www.example.com/']);
      expect(list.allows('https://evil.test/a'), isFalse);
      expect(list.allows('https://example.com.evil.test/'), isFalse);
    });

    test('非法 URL 拒绝而不是炸', () {
      final list = HostAllowList(['example.com']);
      expect(list.allows('not a url'), isFalse);
    });
  });

  group('java.ajax / get / post', () {
    test('白名单内能拿到内容', () async {
      final fake = FakeFetch({'example.com': '<html>ok</html>'});
      final api = JsHostApi(_context(fetch: fake.call));
      expect(await api.ajax('https://example.com/a'), '<html>ok</html>');
      expect(fake.requested.single, 'https://example.com/a');
    });

    test('白名单外直接抛，不发请求', () async {
      final fake = FakeFetch({});
      final api = JsHostApi(_context(fetch: fake.call));
      expect(
        () => api.ajax('https://evil.test/steal'),
        throwsA(isA<StateError>()),
      );
      expect(fake.requested, isEmpty);
    });

    test('请求数有上限', () async {
      final fake = FakeFetch({'example.com': 'x'});
      final api = JsHostApi(_context(fetch: fake.call));
      for (var i = 0; i < JsRuntimeContext.maxRequests; i++) {
        await api.ajax('https://example.com/$i');
      }
      expect(
        () => api.ajax('https://example.com/overflow'),
        throwsA(isA<StateError>()),
      );
    });

    test('抓取失败返回空串而不是抛', () async {
      Future<String> boom(SearchRequest _, {String? header}) async =>
          throw StateError('网络挂了');
      final api = JsHostApi(_context(fetch: boom));
      expect(await api.ajax('https://example.com/a'), '');
    });

    test('post 带上 body', () async {
      final captured = <String>[];
      Future<String> fetch(SearchRequest request, {String? header}) async {
        captured.add('${request.method} ${request.body}');
        return 'ok';
      }

      final api = JsHostApi(_context(fetch: fetch));
      await api.post('https://example.com/s', 'a=1');
      expect(captured.single, 'POST a=1');
    });
  });

  group('java.put / get / getString', () {
    test('KV 存取', () {
      final ctx = JsRuntimeContext(
        fetch: (r, {String? header}) async => '',
        allowList: HostAllowList(['example.com']),
        cookieJar: JsCookieJar(),
      );
      final api = JsHostApi(ctx);
      api.put('token', 'abc');
      expect(api.getVar('token'), 'abc');
      expect(api.getVar('nope'), '');
    });

    test('JSONPath 取嵌套字段', () {
      final ctx = JsRuntimeContext(
        fetch: (r, {String? header}) async => '',
        allowList: HostAllowList(['example.com']),
        cookieJar: JsCookieJar(),
      );
      final api = JsHostApi(ctx);
      api.put('__json__', '{"a":{"b":[10,20,{"c":"deep"}]}}');
      expect(api.getString(r'$.a.b[0]'), '10');
      expect(api.getString(r'$.a.b[2].c'), 'deep');
      expect(api.getString(r'$.a.missing'), '');
    });
  });

  group('内建函数', () {
    test('base64 往返', () {
      expect(JsHostApi.base64Encode('中文'), '5Lit5paH');
      expect(JsHostApi.base64Decode('5Lit5paH'), '中文');
    });

    test('base64 解非法输入返回空串', () {
      expect(JsHostApi.base64Decode('!!!'), '');
    });

    test('md5', () {
      expect(JsHostApi.md5Encode('abc'), '900150983cd24fb0d6963f7d28e17f72');
    });

    test('timeFormat 秒与毫秒都能处理', () {
      final api = JsHostApi(_context(fetch: (r, {String? header}) async => ''));
      // 2026-11-18 09:05:07 的秒级时间戳
      const seconds = 1794908707;
      expect(api.timeFormat('$seconds'), '2026/11/18 09:05');
      expect(api.timeFormat('${seconds}000'), '2026/11/18 09:05');
    });

    test('timeFormat 空值返回空串', () {
      final api = JsHostApi(_context(fetch: (r, {String? header}) async => ''));
      expect(api.timeFormat(null), '');
      expect(api.timeFormat('0'), '');
    });
  });

  group('executeJsWithEngine 的分档逻辑', () {
    test('hard 档直接不给跑', () async {
      final result = await RuleEngine.executeJsWithEngine(
        '@js:Packages.javax.crypto.Cipher.getInstance("AES")',
        result: '',
        fetch: (r, {String? header}) async => '',
        allowList: HostAllowList(['example.com']),
        tier: 'hard',
      );
      expect(result, isNull);
    });

    test('simple 档先走子集，不碰引擎', () async {
      final result = await RuleEngine.executeJsWithEngine(
        r"@js:'http://x.com'+result",
        result: '/a',
        fetch: (r, {String? header}) async => throw StateError('不该发请求'),
        allowList: HostAllowList(['x.com']),
        tier: 'simple',
      );
      expect(result, 'http://x.com/a');
    });

    test('子集跑不通时回落引擎（测试环境没有原生库 → 返回 null）', () async {
      final result = await RuleEngine.executeJsWithEngine(
        '@js:java.ajax(result)',
        result: 'https://example.com/a',
        fetch: (r, {String? header}) async => 'ok',
        allowList: HostAllowList(['example.com']),
        tier: 'mid',
      );
      // 单测环境没有 QuickJS 原生库，回落失败属预期
      expect(result, isNull);
    });
  });

  group('胶水代码', () {
    test('包含书源实际用到的所有名字', () {
      final glue = buildJsGlue();
      for (final name in [
        'java',
        'ajax',
        'getUrl',
        'post',
        'put',
        'getString',
        'timeFormat',
        'base64Decode',
        'base64Encode',
        'md5',
        'md5Encode',
      ]) {
        expect(glue.contains(name), isTrue, reason: '胶水缺 $name');
      }
    });

    test('java.get 按协议头区分 URL 与 KV key', () {
      final glue = buildJsGlue();
      expect(glue.contains(r'/^https?:/i.test(s)'), isTrue);
    });
  });
}
