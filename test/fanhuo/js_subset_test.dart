import 'package:flutter_test/flutter_test.dart';

import 'package:wenku8_flutter/fanhuo/js_subset.dart';

/// 这里的每条用例都来自真实书源里抽出来的脚本，不是编的。
/// 目标：605 个「simple」档书源靠这个解释器跑起来。
void main() {
  String run(String script, {String result = '', String baseUrl = '', String key = ''}) {
    return evaluateJs(script, JsScope(result: result, baseUrl: baseUrl, key: key));
  }

  group('真实书源脚本：正则取 id 再拼 URL', () {
    // 来自「🎉梦琪小说」「💯第一小说①」
    const script = r'''
var id = result.match(/(\d+)\/?$/)[1];
var iid = parseInt(id/1000);
'https://www.mqxs8.com/files/article/image/'+iid+'/'+id+'/'+id+'s.jpg';
''';

    test('bookUrl 结尾取数字，拼出封面地址', () {
      expect(
        run(script, result: 'https://www.mqxs8.com/book/12345/'),
        'https://www.mqxs8.com/files/article/image/12/12345/12345s.jpg',
      );
    });

    test('没有结尾斜杠也能取到', () {
      expect(
        run(script, result: 'https://www.mqxs8.com/book/987654'),
        'https://www.mqxs8.com/files/article/image/987/987654/987654s.jpg',
      );
    });
  });

  group('真实书源脚本：正则提取括号内容', () {
    // 来自「🎉 阅友小说」
    test(r"result.match(/\('(.*?)'\)/)[1]", () {
      expect(
        run(r"result.match(/\('(.*?)'\)/)[1]", result: "x('abc123')"),
        'abc123',
      );
    });

    test('匹配不到时退化成 undefined，不抛异常', () {
      // 真实 JS 里 match 返回 null，再 [1] 会 TypeError；
      // 子集里不让它炸，退化成 undefined，交给上层当「没取到」处理。
      expect(
        run(r"result.match(/\('(.*?)'\)/)[1]", result: 'nomatch'),
        'undefined',
      );
    });
  });

  group('真实书源脚本：拼域名', () {
    test("'http://www.31xs.org'+result", () {
      expect(run("'http://www.31xs.org'+result", result: '/book/1/'), 'http://www.31xs.org/book/1/');
    });
  });

  group('字符串方法', () {
    test('replace 首次替换（非 g）', () {
      expect(run("result.replace(/a/, 'X')", result: 'aa'), 'Xa');
    });

    test('replace 全局替换（g）', () {
      expect(run("result.replace(/a/g, 'X')", result: 'aa'), 'XX');
    });

    test(r'replace 用 $1 引用捕获组', () {
      expect(run(r"result.replace(/(\d+)/, '[$1]')", result: 'abc123def'), 'abc[123]def');
    });

    test('replaceAll 纯字符串', () {
      expect(run("result.replaceAll('&amp;', '&')", result: 'a&amp;b&amp;c'), 'a&b&c');
    });

    test('split + 索引取值', () {
      expect(run("result.split('/')[2]", result: 'a/b/c/d'), 'c');
    });

    test('trim / toLowerCase / toUpperCase', () {
      expect(run('result.trim()', result: '  x  '), 'x');
      expect(run('result.toLowerCase()', result: 'ABC'), 'abc');
      expect(run('result.toUpperCase()', result: 'abc'), 'ABC');
    });

    test('substring / slice / substr 语义', () {
      expect(run('result.substring(1, 3)', result: 'abcdef'), 'bc');
      expect(run('result.slice(-3)', result: 'abcdef'), 'def');
      expect(run('result.substr(2, 2)', result: 'abcdef'), 'cd');
    });

    test('indexOf / startsWith / includes', () {
      expect(run("result.indexOf('cd')", result: 'abcdef'), '2');
      expect(run("result.startsWith('ab')", result: 'abcdef'), 'true');
      expect(run("result.includes('zz')", result: 'abcdef'), 'false');
    });

    test('padStart', () {
      expect(run("result.padStart(5, '0')", result: '12'), '00012');
    });

    test('length', () {
      expect(run('result.length', result: '中文abc'), '5');
    });
  });

  group('数值与运算', () {
    test('parseInt 与除法取整', () {
      expect(run('parseInt(result/1000)', result: '12345'), '12');
    });

    test('~~ 取整（位运算）', () {
      expect(run('~~(result/1000)', result: '12345'), '12');
    });

    test('加法不吞小数点', () {
      expect(run('1+2'), '3');
    });

    test('字符串加数字走拼接', () {
      expect(run("'x' + result", result: '5'), 'x5');
    });

    test('Math.floor / max / min', () {
      expect(run('Math.floor(result/1000)', result: '9999'), '9');
      expect(run('Math.max(1, 7, 3)'), '7');
      expect(run('Math.min(1, 7, 3)'), '1');
    });
  });

  group('变量与 IIFE', () {
    test('var 声明 + return', () {
      expect(
        run('var a = 1; var b = 2; return a + b;'),
        '3',
      );
    });

    test('箭头函数 IIFE', () {
      expect(run('(()=>{ return result + "!"; })()', result: 'hi'), 'hi!');
    });

    test('function IIFE', () {
      expect(
        run('(function(){ var x = result.split("/"); return x[1]; })()', result: 'a/b/c'),
        'b',
      );
    });

    test('带参数的箭头函数', () {
      expect(run('((n)=>{ return n*2; })(21)'), '42');
    });
  });

  group('模板字符串', () {
    test('插值拼接', () {
      // 用 r 前缀，避免 Dart 自己把 ${result} 当插值
      expect(
        run(r'var id = result; return `https://x/${id}.jpg`;', result: 'abc'),
        'https://x/abc.jpg',
      );
    });
  });

  group('条件与三元', () {
    test('if / else', () {
      expect(
        run('if (result.length > 3) { return "long"; } else { return "short"; }', result: 'abcdef'),
        'long',
      );
    });

    test('三元表达式', () {
      expect(run('result.length > 3 ? "a" : "b"', result: 'xy'), 'b');
    });

    test('逻辑或取默认值', () {
      expect(run('result || "fallback"', result: ''), 'fallback');
      expect(run('result || "fallback"', result: 'x'), 'x');
    });
  });

  group('超出子集要明确抛 JsUnsupported', () {
    test('循环', () {
      expect(() => run('for (var i = 0; i < 3; i++) { }'), throwsA(isA<JsUnsupported>()));
    });

    test('java.ajax（中等档）', () {
      expect(
        () => run('java.ajax(result)'),
        throwsA(isA<JsUnsupported>()),
      );
    });

    test('JSON.parse', () {
      expect(() => run('JSON.parse(result)'), throwsA(isA<JsUnsupported>()));
    });

    test('数组回调 map', () {
      expect(
        () => run('result.split(",").map(function(x){return x;})', result: 'a,b'),
        throwsA(isA<JsUnsupported>()),
      );
    });

    test('++ 自增', () {
      expect(() => run('var i = 0; i++; return i;'), throwsA(isA<JsUnsupported>()));
    });

    test('未定义变量', () {
      expect(() => run('nope + 1'), throwsA(isA<JsUnsupported>()));
    });
  });

  group('JS 语义细节', () {
    test('null 与 undefined 的字符串化', () {
      expect(run('null'), 'null');
      expect(run('undefined'), 'undefined');
    });

    test('布尔字符串化', () {
      expect(run('1 === 1'), 'true');
      expect(run('1 !== 1'), 'false');
    });

    test('数组 join 默认逗号', () {
      expect(run('[1,2,3].join()'), '1,2,3');
      expect(run("[1,2,3].join('-')"), '1-2-3');
    });

    test('encodeURIComponent', () {
      expect(run("encodeURIComponent('中文 a')"), '%E4%B8%AD%E6%96%87%20a');
    });

    test('字符串索引取字符', () {
      expect(run('result[1]', result: 'abc'), 'b');
    });

    test('注释被忽略', () {
      expect(run('// 注释\nresult + 1', result: '1'), '11');
    });
  });
}
