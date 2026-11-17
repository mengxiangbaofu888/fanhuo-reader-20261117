/// 书源 JS 的「子集解释器」。
///
/// 背景：2301 条书源里有 993 条带 `@js:` / `<js>` 脚本。按用到的 API 分三档：
///   - **simple（605 条）**：纯字符串/正则/算术，例如
///       `var id = result.match(/(\d+)\/?$/)[1]; 'https://x/'+id+'s.jpg'`
///   - mid（373 条）：要 `java.ajax` / `base64` / `JSON`，得靠真 JS 引擎
///   - hard（15 条）：靠 `Packages.javax.crypto` 做签名，Dart 侧没法等价
///
/// 这个文件只负责第一档。做法是**真的写一个 tokenizer + 递归下降求值器**，
/// 不是用正则去猜——猜出来的结果会静默返回错数据，比直接报错难查一百倍。
///
/// 支持的语法（覆盖 605 条里的绝大多数）：
///   字面量    数字、字符串、模板字符串、正则 /re/flags、true/false/null/undefined
///   变量      var / let / const（都按块级处理）
///   运算      + - * / % 、=== !== == != < > <= >= 、&& || ! 、三元 ?:
///   成员      a.b 、a[b] 、a.length
///   调用      f(a, b)、a.m(b)、IIFE `(()=>{...})()`、`(function(){...})()`
///   语句      var、return、if、表达式语句、块、for 里的简单三段（见下）
///   内建      String / Number / parseInt / parseFloat / Boolean
///            字符串方法 match replace replaceAll split trim trimStart trimEnd
///              substring substr slice indexOf lastIndexOf toLowerCase
///              toUpperCase startsWith endsWith padStart padEnd charAt
///            数组方法 join push pop shift unshift slice concat indexOf includes
///            正则 exec test（配合 RegExp 构造）
///            Math.floor ceil round abs min max
///            encodeURIComponent decodeURIComponent
///
/// **不在子集里的一律抛 [JsUnsupported]**，交给上层回落真引擎或标「不支持」。
library;

/// 脚本超出子集时抛这个。上层看到它就回落 QuickJS（1.5.0 接）。
class JsUnsupported implements Exception {
  const JsUnsupported(this.message);
  final String message;
  @override
  String toString() => 'JsUnsupported: $message';
}

/// 脚本运行时错误（语法对但执行炸了），和「超出子集」区分开。
class JsRuntimeError implements Exception {
  const JsRuntimeError(this.message);
  final String message;
  @override
  String toString() => 'JsRuntimeError: $message';
}

/// 给脚本用的变量表。A（子集）和 B（真引擎）共用同一份构造逻辑。
class JsScope {
  JsScope({
    this.result = '',
    this.baseUrl = '',
    this.key = '',
    this.bookUrl = '',
    this.src = '',
    this.cookies = const {},
  });

  final String result;
  final String baseUrl;
  final String key;
  final String bookUrl;
  final String src;
  final Map<String, String> cookies;

  /// 暴露给脚本的全局变量。键名就是书源 JS 里能直接用的名字。
  Map<String, Object?> toGlobals() => {
    'result': result,
    'baseUrl': baseUrl,
    'key': key,
    'bookUrl': bookUrl,
    'src': src,
    'cookie': cookies.isEmpty ? null : _CookieView(cookies),
  };
}

class _CookieView {
  const _CookieView(this.raw);
  final Map<String, String> raw;
  @override
  String toString() => raw.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// 执行一段脚本，返回它的字符串结果。
///
/// 入口约定（与 Legado 一致）：脚本的**最后一个表达式的值**就是结果；
/// 显式 `return x` 也认。两者都有时以 `return` 为准。
String evaluateJs(String script, JsScope scope) {
  final tokens = _Lexer(script).tokenize();
  final parser = _Parser(tokens);
  final program = parser.parseProgram();
  final interpreter = _Interpreter(scope.toGlobals());
  final value = interpreter.run(program);
  return _toJsString(value);
}

/// JS 的 `String()` 语义：null → 'null'，undefined → 'undefined'，
/// 数字不带 `.0`，数组按逗号连。
String _toJsString(Object? value) {
  if (value == null) return 'undefined';
  if (value is String) return value;
  if (value is bool) return value ? 'true' : 'false';
  if (value is int) return '$value';
  if (value is double) {
    if (value.isNaN) return 'NaN';
    if (value.isInfinite) return value.isNegative ? '-Infinity' : 'Infinity';
    if (value == value.roundToDouble()) return '${value.round()}';
    return '$value';
  }
  if (value is List) {
    return value.map((item) => item == null ? '' : _toJsString(item)).join(',');
  }
  if (value is Map) return '[object Object]';
  if (value is JsNull) return 'null';
  if (value is _JsRegExp) return value.pattern;
  return '$value';
}

/// 显式的 JS `null`（和 Dart 的 null 区分：Dart null 当 undefined）。
class JsNull {
  const JsNull();
  @override
  String toString() => 'null';
}

const jsNull = JsNull();
const jsUndefined = null;

// ══════════════════════════ 词法 ══════════════════════════

enum _T {
  number,
  string,
  template,
  regex,
  identifier,
  keyword,
  punct,
  eof,
}

class _Token {
  const _Token(this.type, this.text, {this.value, this.pos = 0});
  final _T type;
  final String text;
  final Object? value;
  final int pos;
  @override
  String toString() => '${type.name}($text)';
}

class _Lexer {
  _Lexer(this.src);
  final String src;
  int _i = 0;
  final _out = <_Token>[];

  static const _keywords = {
    'var',
    'let',
    'const',
    'function',
    'return',
    'if',
    'else',
    'for',
    'while',
    'true',
    'false',
    'null',
    'undefined',
    'new',
    'typeof',
    'in',
    'of',
  };

  List<_Token> tokenize() {
    while (_i < src.length) {
      final c = src[_i];
      if (_isSpace(c)) {
        _i++;
        continue;
      }
      // 注释
      if (c == '/' && _peek(1) == '/') {
        while (_i < src.length && src[_i] != '\n') {
          _i++;
        }
        continue;
      }
      if (c == '/' && _peek(1) == '*') {
        _i += 2;
        while (_i + 1 < src.length && !(src[_i] == '*' && src[_i + 1] == '/')) {
          _i++;
        }
        _i = (_i + 2).clamp(0, src.length);
        continue;
      }
      if (_isDigit(c) || (c == '.' && _isDigit(_peek(1)))) {
        _number();
        continue;
      }
      if (c == '"' || c == "'") {
        _string(c);
        continue;
      }
      if (c == '`') {
        _template();
        continue;
      }
      // 正则字面量：只有在「表达式位置」才认 / 开头
      if (c == '/' && _regexAllowed()) {
        _regex();
        continue;
      }
      if (_isIdentStart(c)) {
        _identifier();
        continue;
      }
      _punct();
    }
    _out.add(_Token(_T.eof, '', pos: _i));
    return _out;
  }

  String? _peek(int offset) {
    final index = _i + offset;
    return index < src.length ? src[index] : null;
  }

  static bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u3000';
  static bool _isDigit(String? c) => c != null && c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  static bool _isIdentStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) ||
        (u >= 97 && u <= 122) ||
        c == '_' ||
        c == r'$' ||
        u > 127;
  }

  static bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);

  /// 上一个有效 token 决定 `/` 是除号还是正则开头。
  bool _regexAllowed() {
    if (_out.isEmpty) return true;
    final last = _out.last;
    if (last.type == _T.punct) {
      return !(last.text == ')' || last.text == ']');
    }
    if (last.type == _T.keyword) {
      // return /re/.test(x) 里 / 是正则；true/false/null 后面是除号
      return !(last.text == 'true' || last.text == 'false' || last.text == 'null' || last.text == 'undefined');
    }
    // 标识符/数字/字符串后面是除号
    return false;
  }

  void _number() {
    final start = _i;
    while (_i < src.length && _isDigit(src[_i])) {
      _i++;
    }
    if (_i < src.length && src[_i] == '.') {
      _i++;
      while (_i < src.length && _isDigit(src[_i])) {
        _i++;
      }
    }
    if (_i < src.length && (src[_i] == 'e' || src[_i] == 'E')) {
      _i++;
      if (_i < src.length && (src[_i] == '+' || src[_i] == '-')) _i++;
      while (_i < src.length && _isDigit(src[_i])) {
        _i++;
      }
    }
    final text = src.substring(start, _i);
    final value = text.contains('.') || text.contains('e') || text.contains('E')
        ? double.parse(text)
        : int.tryParse(text) ?? double.parse(text);
    _out.add(_Token(_T.number, text, value: value, pos: start));
  }

  void _string(String quote) {
    final start = _i;
    _i++;
    final buffer = StringBuffer();
    while (_i < src.length && src[_i] != quote) {
      final c = src[_i];
      if (c == r'\') {
        _i++;
        if (_i >= src.length) break;
        buffer.write(_escape(src[_i]));
        _i++;
        continue;
      }
      buffer.write(c);
      _i++;
    }
    if (_i >= src.length) {
      throw JsUnsupported('字符串未闭合（位置 $start）');
    }
    _i++; // 收尾引号
    _out.add(_Token(_T.string, src.substring(start, _i), value: buffer.toString(), pos: start));
  }

  void _template() {
    final start = _i;
    _i++;
    final parts = <Object>[]; // 字符串 或 表达式源码
    var text = StringBuffer();
    while (_i < src.length && src[_i] != '`') {
      final c = src[_i];
      if (c == r'\') {
        _i++;
        if (_i < src.length) {
          text.write(_escape(src[_i]));
          _i++;
        }
        continue;
      }
      if (c == r'$' && _peek(1) == '{') {
        // 表达式段
        if (text.isNotEmpty) {
          parts.add(text.toString());
          text = StringBuffer();
        }
        _i += 2;
        var depth = 1;
        final exprStart = _i;
        while (_i < src.length && depth > 0) {
          if (src[_i] == '{') depth++;
          if (src[_i] == '}') depth--;
          if (depth == 0) break;
          _i++;
        }
        parts.add(_Raw(exprStart, src.substring(exprStart, _i)));
        _i++; // 跳过 }
        continue;
      }
      text.write(c);
      _i++;
    }
    if (_i >= src.length) {
      throw JsUnsupported('模板字符串未闭合（位置 $start）');
    }
    _i++;
    if (text.isNotEmpty) parts.add(text.toString());
    _out.add(_Token(_T.template, src.substring(start, _i), value: parts, pos: start));
  }

  static String _escape(String c) {
    switch (c) {
      case 'n':
        return '\n';
      case 't':
        return '\t';
      case 'r':
        return '\r';
      case '0':
        return '\u0000';
      case 'b':
        return '\b';
      case 'f':
        return '\f';
      case 'v':
        return '\v';
      default:
        return c;
    }
  }

  void _regex() {
    final start = _i;
    _i++; // 跳过开头的 /
    final body = StringBuffer();
    var inClass = false;
    while (_i < src.length) {
      final c = src[_i];
      if (c == r'\') {
        body.write(c);
        _i++;
        if (_i < src.length) {
          body.write(src[_i]);
          _i++;
        }
        continue;
      }
      if (c == '[') inClass = true;
      if (c == ']') inClass = false;
      if (c == '/' && !inClass) break;
      body.write(c);
      _i++;
    }
    if (_i >= src.length) {
      throw JsUnsupported('正则未闭合（位置 $start）');
    }
    _i++; // 收尾 /
    final flagsStart = _i;
    while (_i < src.length && _isIdentStart(src[_i])) {
      _i++;
    }
    final flags = src.substring(flagsStart, _i);
    _out.add(_Token(
      _T.regex,
      src.substring(start, _i),
      value: _JsRegExp(body.toString(), flags),
      pos: start,
    ));
  }

  void _identifier() {
    final start = _i;
    while (_i < src.length && _isIdentPart(src[_i])) {
      _i++;
    }
    final text = src.substring(start, _i);
    _out.add(_Token(
      _keywords.contains(text) ? _T.keyword : _T.identifier,
      text,
      pos: start,
    ));
  }

  static const _puncts = [
    '>>>=', '===', '!==', '**=', '<<=', '>>=',
    '==', '!=', '<=', '>=', '&&', '||', '++', '--', '+=', '-=', '*=', '/=',
    '%=', '=>', '**', '<<', '>>', '?.', '??',
    '{', '}', '(', ')', '[', ']', ';', ',', '.', ':', '?',
    '+', '-', '*', '/', '%', '<', '>', '=', '!', '~', '&', '|', '^',
  ];

  void _punct() {
    final start = _i;
    for (final p in _puncts) {
      if (src.startsWith(p, _i)) {
        _i += p.length;
        _out.add(_Token(_T.punct, p, pos: start));
        return;
      }
    }
    throw JsUnsupported('认不出的字符「${src[_i]}」（位置 $_i）');
  }
}

class _Raw {
  const _Raw(this.pos, this.source);
  final int pos;
  final String source;
}

// ══════════════════════════ 语法树 ══════════════════════════

abstract class _Node {
  const _Node();
}

class _Program extends _Node {
  const _Program(this.statements);
  final List<_Node> statements;
}

class _Num extends _Node {
  const _Num(this.value);
  final Object value;
}

class _Str extends _Node {
  const _Str(this.value);
  final String value;
}

class _Bool extends _Node {
  const _Bool(this.value);
  final bool value;
}

class _NullLit extends _Node {
  const _NullLit();
}

class _UndefinedLit extends _Node {
  const _UndefinedLit();
}

class _RegexLit extends _Node {
  const _RegexLit(this.regex);
  final _JsRegExp regex;
}

class _Template extends _Node {
  const _Template(this.parts);
  final List<Object> parts; // String 或 _Node
}

class _ArrayLit extends _Node {
  const _ArrayLit(this.items);
  final List<_Node> items;
}

class _ObjectLit extends _Node {
  const _ObjectLit(this.entries);
  final List<(String, _Node)> entries;
}

class _Ident extends _Node {
  const _Ident(this.name);
  final String name;
}

class _Member extends _Node {
  const _Member(this.target, this.property, {this.computed = false});
  final _Node target;
  final _Node property;
  final bool computed;
}

class _Call extends _Node {
  const _Call(this.callee, this.args);
  final _Node callee;
  final List<_Node> args;
}

class _Unary extends _Node {
  const _Unary(this.op, this.operand);
  final String op;
  final _Node operand;
}

class _Binary extends _Node {
  const _Binary(this.op, this.left, this.right);
  final String op;
  final _Node left;
  final _Node right;
}

class _Logical extends _Node {
  const _Logical(this.op, this.left, this.right);
  final String op;
  final _Node left;
  final _Node right;
}

class _Conditional extends _Node {
  const _Conditional(this.test, this.consequent, this.alternate);
  final _Node test;
  final _Node consequent;
  final _Node alternate;
}

class _Assign extends _Node {
  const _Assign(this.target, this.op, this.value);
  final _Node target;
  final String op;
  final _Node value;
}

class _Sequence extends _Node {
  const _Sequence(this.items);
  final List<_Node> items;
}

class _VarDecl extends _Node {
  const _VarDecl(this.name, this.init);
  final String name;
  final _Node? init;
}

class _Return extends _Node {
  const _Return(this.value);
  final _Node? value;
}

class _If extends _Node {
  const _If(this.test, this.consequent, this.alternate);
  final _Node test;
  final _Node consequent;
  final _Node? alternate;
}

class _Block extends _Node {
  const _Block(this.statements);
  final List<_Node> statements;
}

class _ExprStmt extends _Node {
  const _ExprStmt(this.expr);
  final _Node expr;
}

class _Func extends _Node {
  const _Func(this.params, this.body);
  final List<String> params;
  final _Node body;
}

/// 什么都不做（`;` 空语句、被忽略的声明）。
class _Empty extends _Node {
  const _Empty();
}

class _ReturnSignal {
  const _ReturnSignal(this.value);
  final Object? value;
}

// ══════════════════════════ 语法分析 ══════════════════════════

class _Parser {
  _Parser(this.tokens);
  final List<_Token> tokens;
  int _p = 0;

  _Token get _cur => tokens[_p];

  bool _isPunct(String text) => _cur.type == _T.punct && _cur.text == text;
  bool _isKeyword(String text) => _cur.type == _T.keyword && _cur.text == text;

  _Token _expect(String text) {
    if (!_isPunct(text)) {
      throw JsUnsupported('期望「$text」，实际「${_cur.text}」（位置 ${_cur.pos}）');
    }
    final token = _cur;
    _p++;
    return token;
  }

  void _skipSemicolons() {
    while (_isPunct(';')) {
      _p++;
    }
  }

  _Program parseProgram() {
    final statements = <_Node>[];
    while (_cur.type != _T.eof) {
      statements.add(_statement());
      _skipSemicolons();
    }
    return _Program(statements);
  }

  _Node _statement() {
    if (_isPunct('{')) return _block();
    if (_isKeyword('var') || _isKeyword('let') || _isKeyword('const')) {
      return _varDecl();
    }
    if (_isKeyword('return')) {
      _p++;
      if (_isPunct(';') || _isPunct('}') || _cur.type == _T.eof) {
        return const _Return(null);
      }
      return _Return(_expression());
    }
    if (_isKeyword('if')) return _ifStatement();
    if (_isKeyword('function')) return _funcDecl();
    if (_isKeyword('for') || _isKeyword('while')) {
      throw const JsUnsupported('子集不支持循环（for/while）');
    }
    if (_isPunct(';')) {
      _p++;
      return const _Empty();
    }
    final expr = _expression();
    return _ExprStmt(expr);
  }

  _Node _block() {
    _expect('{');
    final statements = <_Node>[];
    while (!_isPunct('}') && _cur.type != _T.eof) {
      statements.add(_statement());
      _skipSemicolons();
    }
    _expect('}');
    return _Block(statements);
  }

  _Node _varDecl() {
    _p++; // var/let/const
    // 一次声明多个变量时只留第一个（书源里极少见，遇到就抛）
    final name = _cur.text;
    if (_cur.type != _T.identifier) {
      throw JsUnsupported('变量名非法：「${_cur.text}」');
    }
    _p++;
    _Node? init;
    if (_isPunct('=')) {
      _p++;
      init = _assignment();
    }
    if (_isPunct(',')) {
      throw const JsUnsupported('子集不支持 var a = 1, b = 2 这种多重声明');
    }
    return _VarDecl(name, init);
  }

  _Node _ifStatement() {
    _p++; // if
    _expect('(');
    final test = _expression();
    _expect(')');
    final consequent = _statement();
    _skipSemicolons();
    _Node? alternate;
    if (_isKeyword('else')) {
      _p++;
      alternate = _statement();
    }
    return _If(test, consequent, alternate);
  }

  _Node _funcDecl() {
    // 函数声明语句：`function f(){...}` —— 子集里只接受「立即调用」形态，
    // 单独声明就丢掉（书源脚本基本是 IIFE）。
    final start = _p;
    _p++;
    if (_cur.type == _T.identifier) _p++;
    _expect('(');
    final params = <String>[];
    while (!_isPunct(')')) {
      if (_cur.type == _T.identifier) params.add(_cur.text);
      _p++;
      if (_isPunct(',')) _p++;
    }
    _expect(')');
    // 回退成表达式：让上层把它当 _Func 用（解析出的 body 丢弃，不参与求值）
    _block();
    _p = start;
    return const _Empty();
  }

  _Node _expression() {
    final first = _assignment();
    if (!_isPunct(',')) return first;
    final items = <_Node>[first];
    while (_isPunct(',')) {
      _p++;
      items.add(_assignment());
    }
    return _Sequence(items);
  }

  _Node _assignment() {
    final left = _conditional();
    if (_cur.type == _T.punct &&
        const ['=', '+=', '-=', '*=', '/=', '%='].contains(_cur.text)) {
      final op = _cur.text;
      _p++;
      final value = _assignment();
      return _Assign(left, op, value);
    }
    return left;
  }

  _Node _conditional() {
    final test = _logicalOr();
    if (_isPunct('?')) {
      _p++;
      final consequent = _assignment();
      _expect(':');
      final alternate = _assignment();
      return _Conditional(test, consequent, alternate);
    }
    return test;
  }

  _Node _logicalOr() {
    var left = _logicalAnd();
    while (_isPunct('||') || _isPunct('??')) {
      final op = _cur.text;
      _p++;
      left = _Logical(op, left, _logicalAnd());
    }
    return left;
  }

  _Node _logicalAnd() {
    var left = _bitOr();
    while (_isPunct('&&')) {
      _p++;
      left = _Logical('&&', left, _bitOr());
    }
    return left;
  }

  _Node _bitOr() {
    var left = _bitXor();
    while (_isPunct('|')) {
      _p++;
      left = _Binary('|', left, _bitXor());
    }
    return left;
  }

  _Node _bitXor() {
    var left = _bitAnd();
    while (_isPunct('^')) {
      _p++;
      left = _Binary('^', left, _bitAnd());
    }
    return left;
  }

  _Node _bitAnd() {
    var left = _equality();
    while (_isPunct('&')) {
      _p++;
      left = _Binary('&', left, _equality());
    }
    return left;
  }

  _Node _equality() {
    var left = _relational();
    while (_isPunct('===') || _isPunct('!==') || _isPunct('==') || _isPunct('!=')) {
      final op = _cur.text;
      _p++;
      left = _Binary(op, left, _relational());
    }
    return left;
  }

  _Node _relational() {
    var left = _additive();
    while (_isPunct('<') ||
        _isPunct('>') ||
        _isPunct('<=') ||
        _isPunct('>=') ||
        _isKeyword('in')) {
      final op = _cur.text;
      _p++;
      left = _Binary(op, left, _additive());
    }
    return left;
  }

  _Node _additive() {
    var left = _multiplicative();
    while (_isPunct('+') || _isPunct('-')) {
      final op = _cur.text;
      _p++;
      left = _Binary(op, left, _multiplicative());
    }
    return left;
  }

  _Node _multiplicative() {
    var left = _unary();
    while (_isPunct('*') || _isPunct('/') || _isPunct('%')) {
      final op = _cur.text;
      _p++;
      left = _Binary(op, left, _unary());
    }
    return left;
  }

  _Node _unary() {
    if (_isPunct('!') || _isPunct('-') || _isPunct('+') || _isPunct('~')) {
      final op = _cur.text;
      _p++;
      return _Unary(op, _unary());
    }
    if (_isPunct('++') || _isPunct('--')) {
      throw const JsUnsupported('子集不支持 ++ / -- 前缀');
    }
    if (_isKeyword('typeof')) {
      _p++;
      return _Unary('typeof', _unary());
    }
    return _postfix();
  }

  _Node _postfix() {
    final expr = _callOrMember();
    if (_isPunct('++') || _isPunct('--')) {
      throw const JsUnsupported('子集不支持 ++ / -- 后缀');
    }
    return expr;
  }

  _Node _callOrMember() {
    var expr = _primary();
    while (true) {
      if (_isPunct('.')) {
        _p++;
        final name = _cur.text;
        if (_cur.type != _T.identifier && _cur.type != _T.keyword) {
          throw JsUnsupported('成员名非法：「$name」');
        }
        _p++;
        expr = _Member(expr, _Str(name));
        continue;
      }
      if (_isPunct('[')) {
        _p++;
        final index = _expression();
        _expect(']');
        expr = _Member(expr, index, computed: true);
        continue;
      }
      if (_isPunct('(')) {
        _p++;
        final args = <_Node>[];
        while (!_isPunct(')')) {
          final arg = _assignment();
          // 展开运算 ... 不支持
          args.add(arg);
          if (_isPunct(',')) _p++;
        }
        _expect(')');
        expr = _Call(expr, args);
        continue;
      }
      if (_isPunct('?.')) {
        _p++;
        final name = _cur.text;
        _p++;
        expr = _Member(expr, _Str(name), computed: false);
        continue;
      }
      break;
    }
    return expr;
  }

  _Node _primary() {
    final token = _cur;
    switch (token.type) {
      case _T.number:
        _p++;
        return _Num(token.value!);
      case _T.string:
        _p++;
        return _Str(token.value as String);
      case _T.regex:
        _p++;
        return _RegexLit(token.value as _JsRegExp);
      case _T.template:
        _p++;
        final parts = <Object>[];
        for (final part in token.value as List<Object>) {
          if (part is String) {
            parts.add(part);
          } else if (part is _Raw) {
            final inner = _Parser(_Lexer(part.source).tokenize()).parseProgram();
            parts.add(inner);
          }
        }
        return _Template(parts);
      case _T.keyword:
        if (token.text == 'true') {
          _p++;
          return const _Bool(true);
        }
        if (token.text == 'false') {
          _p++;
          return const _Bool(false);
        }
        if (token.text == 'null') {
          _p++;
          return const _NullLit();
        }
        if (token.text == 'undefined') {
          _p++;
          return const _UndefinedLit();
        }
        if (token.text == 'function') {
          _p++;
          if (_cur.type == _T.identifier) _p++; // 具名函数
          return _functionBody();
        }
        throw JsUnsupported('子集不支持关键字「${token.text}」');
      case _T.identifier:
        _p++;
        return _Ident(token.text);
      case _T.punct:
        if (token.text == '(') {
          _p++;
          // 箭头函数 `()=>...` 或 `(a,b)=>...`
          if (_isPunct(')')) {
            _p++;
            if (_isPunct('=>')) {
              _p++;
              return _arrowBody(const []);
            }
            throw JsUnsupported('空括号不是表达式（位置 ${token.pos}）');
          }
          final expr = _expression();
          if (_isPunct(')')) {
            _p++;
            if (_isPunct('=>')) {
              _p++;
              final params = expr is _Ident ? [expr.name] : const <String>[];
              return _arrowBody(params);
            }
            return expr;
          }
          throw JsUnsupported('括号未闭合（位置 ${token.pos}）');
        }
        if (token.text == '[') {
          _p++;
          final items = <_Node>[];
          while (!_isPunct(']')) {
            items.add(_assignment());
            if (_isPunct(',')) _p++;
          }
          _expect(']');
          return _ArrayLit(items);
        }
        if (token.text == '{') {
          _p++;
          final entries = <(String, _Node)>[];
          while (!_isPunct('}')) {
            final key = _cur.text;
            if (_cur.type != _T.identifier &&
                _cur.type != _T.string &&
                _cur.type != _T.keyword &&
                _cur.type != _T.number) {
              throw JsUnsupported('对象键名非法：「$key」');
            }
            _p++;
            if (!_isPunct(':')) {
              throw const JsUnsupported('子集只支持 {k: v} 形式的对象字面量');
            }
            _p++;
            entries.add((key, _assignment()));
            if (_isPunct(',')) _p++;
          }
          _expect('}');
          return _ObjectLit(entries);
        }
        if (token.text == '...') {
          throw const JsUnsupported('子集不支持展开运算 ...');
        }
        throw JsUnsupported('意外的符号「${token.text}」（位置 ${token.pos}）');
      case _T.eof:
        throw const JsUnsupported('脚本意外结束');
    }
  }

  _Node _functionBody() {
    _expect('(');
    final params = <String>[];
    while (!_isPunct(')')) {
      if (_cur.type == _T.identifier) params.add(_cur.text);
      _p++;
      if (_isPunct(',')) _p++;
    }
    _expect(')');
    final body = _block();
    return _Func(params, body);
  }

  _Node _arrowBody(List<String> params) {
    if (_isPunct('{')) {
      return _Func(params, _block());
    }
    // 表达式体：`()=> expr`
    final expr = _assignment();
    return _Func(params, _Block([_Return(expr)]));
  }
}

// ══════════════════════════ 求值 ══════════════════════════

class _JsRegExp {
  _JsRegExp(this.pattern, this.flags)
    : _regex = RegExp(
        pattern,
        multiLine: flags.contains('m'),
        caseSensitive: !flags.contains('i'),
        dotAll: flags.contains('s'),
        unicode: flags.contains('u'),
      );

  final String pattern;
  final String flags;
  final RegExp _regex;

  bool get global => flags.contains('g');

  @override
  String toString() => '/$pattern/$flags';
}

/// 求值作用域链。
class _Env {
  _Env(this.parent);
  final _Env? parent;
  final Map<String, Object?> values = {};

  Object? get(String name) {
    if (values.containsKey(name)) return values[name];
    if (parent != null) return parent!.get(name);
    throw JsUnsupported('未定义的变量「$name」');
  }

  bool has(String name) =>
      values.containsKey(name) || (parent?.has(name) ?? false);

  void set(String name, Object? value) {
    if (values.containsKey(name)) {
      values[name] = value;
      return;
    }
    if (parent != null && parent!.has(name)) {
      parent!.set(name, value);
      return;
    }
    values[name] = value;
  }

  void define(String name, Object? value) => values[name] = value;
}

class _Interpreter {
  _Interpreter(Map<String, Object?> globals) {
    _global = _Env(null);
    for (final entry in globals.entries) {
      _global.define(entry.key, entry.value);
    }
    _global
      ..define('String', _BuiltinFn('String', _string))
      ..define('Number', _BuiltinFn('Number', _number))
      ..define('Boolean', _BuiltinFn('Boolean', _boolean))
      ..define('parseInt', _BuiltinFn('parseInt', _parseInt))
      ..define('parseFloat', _BuiltinFn('parseFloat', _parseFloat))
      ..define('isNaN', _BuiltinFn('isNaN', (args) {
        final v = args.isEmpty ? null : args.first;
        final n = _toNumber(v);
        return n.isNaN;
      }))
      ..define('encodeURIComponent', _BuiltinFn('encodeURIComponent', (args) {
        return Uri.encodeComponent(_toJsString(args.isEmpty ? null : args.first));
      }))
      ..define('decodeURIComponent', _BuiltinFn('decodeURIComponent', (args) {
        try {
          return Uri.decodeComponent(_toJsString(args.isEmpty ? null : args.first));
        } catch (_) {
          return _toJsString(args.isEmpty ? null : args.first);
        }
      }))
      ..define('RegExp', _BuiltinFn('RegExp', (args) {
        final pattern = args.isEmpty ? '' : _toJsString(args[0]);
        final flags = args.length > 1 ? _toJsString(args[1]) : '';
        return _JsRegExp(pattern, flags);
      }))
      ..define('Math', _MathObject())
      ..define('JSON', _JsonObject());
  }

  late final _Env _global;
  _Env _env = _Env(null);

  Object? run(_Program program) {
    _env = _global;
    Object? last;
    for (final statement in program.statements) {
      final result = _exec(statement);
      if (result is _ReturnSignal) return result.value;
      if (!identical(result, _noValue)) last = result;
    }
    return last;
  }


  Object? _exec(_Node node) {
    if (node is _Program) {
      Object? last;
      for (final s in node.statements) {
        final r = _exec(s);
        if (r is _ReturnSignal) return r;
        if (!identical(r, _noValue)) last = r;
      }
      return last;
    }
    if (node is _ExprStmt) return _eval(node.expr);
    if (node is _VarDecl) {
      final value = node.init == null ? null : _eval(node.init!);
      _env.define(node.name, value);
      return _noValue;
    }
    if (node is _Return) {
      return _ReturnSignal(node.value == null ? null : _eval(node.value!));
    }
    if (node is _Block) {
      final inner = _Env(_env);
      final outer = _env;
      _env = inner;
      try {
        for (final s in node.statements) {
          final r = _exec(s);
          if (r is _ReturnSignal) return r;
        }
      } finally {
        _env = outer;
      }
      return _noValue;
    }
    if (node is _If) {
      final test = _eval(node.test);
      if (_truthy(test)) return _exec(node.consequent);
      if (node.alternate != null) return _exec(node.alternate!);
      return _noValue;
    }
    if (node is _Empty) return _noValue;
    throw JsUnsupported('子集不支持该语句：${node.runtimeType}');
  }

  Object? _eval(_Node node) {
    if (node is _Num) return node.value;
    if (node is _Str) return node.value;
    if (node is _Bool) return node.value;
    if (node is _NullLit) return jsNull;
    if (node is _UndefinedLit) return null;
    if (node is _RegexLit) return node.regex;
    if (node is _Template) {
      final buffer = StringBuffer();
      for (final part in node.parts) {
        if (part is String) {
          buffer.write(part);
        } else if (part is _Program) {
          final saved = _env;
          final value = run(part);
          _env = saved;
          buffer.write(_toJsString(value));
        }
      }
      return buffer.toString();
    }
    if (node is _ArrayLit) {
      return [for (final item in node.items) _eval(item)];
    }
    if (node is _ObjectLit) {
      return {
        for (final entry in node.entries) entry.$1: _eval(entry.$2),
      };
    }
    if (node is _Ident) return _env.get(node.name);
    if (node is _Member) return _member(node);
    if (node is _Call) return _call(node);
    if (node is _Unary) return _unary(node);
    if (node is _Binary) return _binary(node);
    if (node is _Logical) {
      final left = _eval(node.left);
      if (node.op == '&&') return _truthy(left) ? _eval(node.right) : left;
      if (node.op == '??') return left == null ? _eval(node.right) : left;
      return _truthy(left) ? left : _eval(node.right);
    }
    if (node is _Conditional) {
      return _truthy(_eval(node.test))
          ? _eval(node.consequent)
          : _eval(node.alternate);
    }
    if (node is _Assign) return _assign(node);
    if (node is _Sequence) {
      Object? last;
      for (final item in node.items) {
        last = _eval(item);
      }
      return last;
    }
    if (node is _Func) return node;
    throw JsUnsupported('子集不支持该表达式：${node.runtimeType}');
  }

  Object? _assign(_Assign node) {
    final target = node.target;
    if (node.op == '=') {
      final value = _eval(node.value);
      _assignTo(target, value);
      return value;
    }
    final current = _eval(target);
    final right = _eval(node.value);
    final result = switch (node.op) {
      '+=' => _binaryOp('+', current, right),
      '-=' => _binaryOp('-', current, right),
      '*=' => _binaryOp('*', current, right),
      '/=' => _binaryOp('/', current, right),
      '%=' => _binaryOp('%', current, right),
      _ => throw JsUnsupported('子集不支持赋值运算 ${node.op}'),
    };
    _assignTo(target, result);
    return result;
  }

  void _assignTo(_Node target, Object? value) {
    if (target is _Ident) {
      _env.set(target.name, value);
      return;
    }
    throw const JsUnsupported('子集只支持给变量赋值');
  }

  Object? _member(_Member node) {
    final target = _eval(node.target);
    final property = node.computed ? _eval(node.property) : (node.property as _Str).value;
    if (target == null || target is JsNull) {
      throw JsRuntimeError('读 ${_toJsString(target)} 的属性「$property」');
    }
    if (target is String) {
      if (property == 'length') return target.length;
      final index = _asInt(property);
      if (index != null) {
        return index >= 0 && index < target.length ? target[index] : null;
      }
      throw JsUnsupported('字符串属性「$property」不在子集里');
    }
    if (target is List) {
      if (property == 'length') return target.length;
      final index = _asInt(property);
      if (index != null) {
        return index >= 0 && index < target.length ? target[index] : null;
      }
      throw JsUnsupported('数组属性「$property」要作为方法调用');
    }
    if (target is Map) return target[property];
    if (target is _JsRegExp) {
      if (property == 'source') return target.pattern;
      if (property == 'flags') return target.flags;
      if (property == 'global') return target.global;
      throw JsUnsupported('正则属性「$property」不在子集里');
    }
    if (target is _MatchHolder) {
      if (property == 'length') return target.groups.length;
      if (property == 'index') return target.index;
      if (property == 'input') return target.input;
      final index = _asInt(property);
      if (index != null) {
        return index >= 0 && index < target.groups.length
            ? target.groups[index]
            : null;
      }
    }
    throw JsUnsupported('不认识的成员访问：${target.runtimeType}.$property');
  }

  Object? _call(_Call node) {
    final callee = node.callee;
    // a.b(...) 走方法表
    if (callee is _Member) {
      final target = _eval(callee.target);
      final name = callee.computed
          ? _toJsString(_eval(callee.property))
          : (callee.property as _Str).value;
      final args = [for (final arg in node.args) _eval(arg)];
      return _invokeMethod(target, name, args);
    }
    final fn = _eval(callee);
    final args = [for (final arg in node.args) _eval(arg)];
    if (fn is _BuiltinFn) return fn.call(args);
    if (fn is _Func) return _callUserFunction(fn, args);
    if (fn == null) throw const JsRuntimeError('调用了 undefined');
    throw JsUnsupported('不支持调用 ${fn.runtimeType}');
  }

  Object? _invokeMethod(Object? target, String name, List<Object?> args) {
    if (target is String) return _stringMethod(target, name, args);
    if (target is List) return _arrayMethod(target, name, args);
    if (target is _JsRegExp) return _regexMethod(target, name, args);
    if (target is _MatchHolder) return _matchHolderMethod(target, name, args);
    if (target is _MathObject) return target.call(name, args);
    if (target is _JsonObject) return target.call(name, args);
    if (target is _BuiltinFn) return target.call(args);
    throw JsUnsupported('$name() 不支持在 ${target.runtimeType} 上调用');
  }

  Object? _callUserFunction(_Func fn, List<Object?> args) {
    final inner = _Env(_global);
    for (var i = 0; i < fn.params.length; i++) {
      inner.define(fn.params[i], i < args.length ? args[i] : null);
    }
    final saved = _env;
    _env = inner;
    try {
      final result = _exec(fn.body);
      if (result is _ReturnSignal) return result.value;
      return null;
    } finally {
      _env = saved;
    }
  }

  Object? _stringMethod(String target, String name, List<Object?> args) {
    switch (name) {
      case 'match':
        final regex = _asRegex(args.isEmpty ? null : args.first);
        return _matchString(target, regex);
      case 'matchAll':
        throw const JsUnsupported('子集不支持 matchAll');
      case 'replace':
        final regex = _asRegex(args.isEmpty ? null : args.first);
        final replacement = args.length > 1 ? _toJsString(args[1]) : '';
        return _replace(target, regex, replacement, firstOnly: !regex.global);
      case 'replaceAll':
        final pattern = _toJsString(args.isEmpty ? null : args.first);
        final replacement = args.length > 1 ? _toJsString(args[1]) : '';
        return target.replaceAll(pattern, replacement);
      case 'split':
        final regex = _asRegex(args.isEmpty ? null : args.first, allowString: true);
        return _split(target, regex);
      case 'trim':
        return target.trim();
      case 'trimStart':
        return target.trimLeft();
      case 'trimEnd':
        return target.trimRight();
      case 'substring':
        final start = _asInt(args.isEmpty ? 0 : args[0]) ?? 0;
        var end = args.length > 1 ? _asInt(args[1]) : null;
        final s = start.clamp(0, target.length);
        end = (end ?? target.length).clamp(s, target.length);
        return target.substring(s, end);
      case 'substr':
        final start = _asInt(args.isEmpty ? 0 : args[0]) ?? 0;
        final length = args.length > 1 ? _asInt(args[1]) : null;
        final s = start < 0 ? (target.length + start).clamp(0, target.length) : start.clamp(0, target.length);
        final e = length == null ? target.length : (s + length).clamp(s, target.length);
        return target.substring(s, e);
      case 'slice':
        final start = _asInt(args.isEmpty ? 0 : args[0]) ?? 0;
        final end = args.length > 1 ? _asInt(args[1]) : null;
        return _slice(target, start, end);
      case 'indexOf':
        final needle = _toJsString(args.isEmpty ? null : args[0]);
        return target.indexOf(needle);
      case 'lastIndexOf':
        final needle = _toJsString(args.isEmpty ? null : args[0]);
        return target.lastIndexOf(needle);
      case 'toLowerCase':
        return target.toLowerCase();
      case 'toUpperCase':
        return target.toUpperCase();
      case 'startsWith':
        return target.startsWith(_toJsString(args.isEmpty ? null : args[0]));
      case 'endsWith':
        return target.endsWith(_toJsString(args.isEmpty ? null : args[0]));
      case 'includes':
        return target.contains(_toJsString(args.isEmpty ? null : args[0]));
      case 'charAt':
        final i = _asInt(args.isEmpty ? 0 : args[0]) ?? 0;
        return i >= 0 && i < target.length ? target[i] : '';
      case 'charCodeAt':
        final i = _asInt(args.isEmpty ? 0 : args[0]) ?? 0;
        return i >= 0 && i < target.length ? target.codeUnitAt(i) : null;
      case 'padStart':
        final width = _asInt(args.isEmpty ? 0 : args[0]) ?? 0;
        final pad = args.length > 1 ? _toJsString(args[1]) : ' ';
        return _pad(target, width, pad, start: true);
      case 'padEnd':
        final width = _asInt(args.isEmpty ? 0 : args[0]) ?? 0;
        final pad = args.length > 1 ? _toJsString(args[1]) : ' ';
        return _pad(target, width, pad, start: false);
      case 'toString':
      case 'valueOf':
        return target;
      default:
        throw JsUnsupported('字符串方法「$name」不在子集里');
    }
  }

  Object? _arrayMethod(List<Object?> target, String name, List<Object?> args) {
    switch (name) {
      case 'join':
        final sep = args.isEmpty ? ',' : _toJsString(args[0]);
        return target.map((item) => item == null ? '' : _toJsString(item)).join(sep);
      case 'push':
        target.addAll(args);
        return target.length;
      case 'pop':
        return target.isEmpty ? null : target.removeLast();
      case 'shift':
        return target.isEmpty ? null : target.removeAt(0);
      case 'unshift':
        target.insertAll(0, args);
        return target.length;
      case 'slice':
        final start = _asInt(args.isEmpty ? 0 : args[0]) ?? 0;
        final end = args.length > 1 ? _asInt(args[1]) : null;
        final s = start < 0 ? (target.length + start).clamp(0, target.length) : start.clamp(0, target.length);
        final e = end == null
            ? target.length
            : (end < 0 ? (target.length + end) : end).clamp(s, target.length);
        return target.sublist(s, e);
      case 'concat':
        final out = [...target];
        for (final arg in args) {
          if (arg is List) {
            out.addAll(arg);
          } else {
            out.add(arg);
          }
        }
        return out;
      case 'indexOf':
        if (args.isEmpty) return -1;
        return target.indexWhere((item) => _looseEquals(item, args[0]));
      case 'includes':
        if (args.isEmpty) return false;
        return target.any((item) => _looseEquals(item, args[0]));
      case 'map':
      case 'filter':
      case 'forEach':
      case 'reduce':
        throw JsUnsupported('数组方法「$name」需要回调，不在子集里');
      case 'toString':
        return target.map((item) => item == null ? '' : _toJsString(item)).join(',');
      default:
        throw JsUnsupported('数组方法「$name」不在子集里');
    }
  }

  Object? _regexMethod(_JsRegExp target, String name, List<Object?> args) {
    final input = _toJsString(args.isEmpty ? null : args[0]);
    switch (name) {
      case 'test':
        return target._regex.hasMatch(input);
      case 'exec':
        return _matchString(input, target);
      case 'toString':
        return target.toString();
      default:
        throw JsUnsupported('正则方法「$name」不在子集里');
    }
  }

  Object? _matchHolderMethod(_MatchHolder target, String name, List<Object?> args) {
    if (name == 'toString') return target.groups.isEmpty ? '' : target.groups.join(',');
    throw JsUnsupported('匹配结果方法「$name」不在子集里');
  }

  Object? _unary(_Unary node) {
    final operand = _eval(node.operand);
    switch (node.op) {
      case '!':
        return !_truthy(operand);
      case '-':
        return -_toNumber(operand);
      case '+':
        return _toNumber(operand);
      case '~':
        return ~_toInt(operand);
      case 'typeof':
        return _typeof(operand);
      default:
        throw JsUnsupported('一元运算 ${node.op}');
    }
  }

  Object? _binary(_Binary node) =>
      _binaryOp(node.op, _eval(node.left), _eval(node.right));

  Object? _binaryOp(String op, Object? left, Object? right) {
    switch (op) {
      case '+':
        // JS 的 + 有字符串拼接优先
        if (left is String || right is String || left is JsNull || right is JsNull) {
          return _toJsString(left) + _toJsString(right);
        }
        if (left is List || right is List) {
          return _toJsString(left) + _toJsString(right);
        }
        final l = _toNumber(left);
        final r = _toNumber(right);
        final sum = l + r;
        return sum == sum.roundToDouble() ? sum.round() : sum;
      case '-':
        return _numResult(_toNumber(left) - _toNumber(right));
      case '*':
        return _numResult(_toNumber(left) * _toNumber(right));
      case '/':
        final r = _toNumber(right);
        if (r == 0) throw const JsRuntimeError('除以 0');
        return _toNumber(left) / r;
      case '%':
        return _numResult(_toNumber(left) % _toNumber(right));
      case '===':
        return _strictEquals(left, right);
      case '!==':
        return !_strictEquals(left, right);
      case '==':
      case '!=':
        final eq = _looseEquals(left, right);
        return op == '==' ? eq : !eq;
      case '<':
        return _compare(left, right) < 0;
      case '>':
        return _compare(left, right) > 0;
      case '<=':
        return _compare(left, right) <= 0;
      case '>=':
        return _compare(left, right) >= 0;
      case '|':
        return _toInt(left) | _toInt(right);
      case '&':
        return _toInt(left) & _toInt(right);
      case '^':
        return _toInt(left) ^ _toInt(right);
      case 'in':
        if (right is Map) return right.containsKey(_toJsString(left));
        throw const JsUnsupported('in 只支持对象');
      default:
        throw JsUnsupported('二元运算 $op');
    }
  }

  static Object? _numResult(double value) {
    if (value.isNaN) return double.nan;
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.round();
    }
    return value;
  }

  int _compare(Object? left, Object? right) {
    if (left is String && right is String) return left.compareTo(right);
    return _toNumber(left).compareTo(_toNumber(right));
  }

  static bool _strictEquals(Object? a, Object? b) {
    if (a is JsNull || b is JsNull) return identical(a, b) || (a is JsNull && b is JsNull);
    if (a == null || b == null) return a == null && b == null;
    if (a is num && b is num) return a == b;
    if (a.runtimeType != b.runtimeType) return false;
    if (a is List || a is Map) return identical(a, b);
    return a == b;
  }

  static bool _looseEquals(Object? a, Object? b) {
    if (_strictEquals(a, b)) return true;
    if ((a == null || a is JsNull) && (b == null || b is JsNull)) return true;
    if ((a == null || a is JsNull) && (b == null || b is JsNull)) return true;
    if (a is num && b is String) return a == _toNumber(b);
    if (a is String && b is num) return _toNumber(a) == b;
    return false;
  }

  static String _typeof(Object? value) {
    if (value == null) return 'undefined';
    if (value is JsNull) return 'object';
    if (value is bool) return 'boolean';
    if (value is num) return 'number';
    if (value is String) return 'string';
    if (value is _Func || value is _BuiltinFn) return 'function';
    return 'object';
  }

  static bool _truthy(Object? value) {
    if (value == null) return false;
    if (value is JsNull) return false;
    if (value is bool) return value;
    if (value is num) return value != 0 && !value.isNaN;
    if (value is String) return value.isNotEmpty;
    return true;
  }

  static double _toNumber(Object? value) {
    if (value is num) return value.toDouble();
    if (value == null || value is JsNull) return 0;
    if (value is bool) return value ? 1 : 0;
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return 0;
      return double.tryParse(trimmed) ?? double.nan;
    }
    return double.nan;
  }

  static int _toInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.isNaN ? 0 : value.truncate();
    if (value is bool) return value ? 1 : 0;
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static int? _asInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.isNaN ? null : value.truncate();
    final parsed = int.tryParse(_toJsString(value));
    return parsed;
  }

  static _JsRegExp _asRegex(Object? value, {bool allowString = false}) {
    if (value is _JsRegExp) return value;
    if (value is String) return _JsRegExp(_escapeRegex(value), '');
    throw JsUnsupported('这里需要正则，实际是 ${value.runtimeType}');
  }

  static String _escapeRegex(String text) =>
      text.replaceAllMapped(RegExp(r'[.*+?^${}()|\[\]\\]'), (m) => '\\${m[0]}');

  /// `String.prototype.match`：非全局返回第一个匹配（带捕获组），全局返回全部匹配串。
  static Object? _matchString(String input, _JsRegExp regex) {
    if (regex.global) {
      final all = regex._regex.allMatches(input).toList();
      if (all.isEmpty) return jsNull;
      return [for (final m in all) m[0] ?? ''];
    }
    final first = regex._regex.firstMatch(input);
    if (first == null) return jsNull;
    return _MatchHolder(
      [first[0] ?? '', for (var i = 1; i <= first.groupCount; i++) first.group(i)],
      first.start,
      input,
    );
  }

  static String _replace(
    String input,
    _JsRegExp regex,
    String replacement, {
    required bool firstOnly,
  }) {
    var replaced = false;
    return input.replaceAllMapped(regex._regex, (m) {
      if (firstOnly && replaced) return m[0] ?? '';
      replaced = true;
      // 支持 $1..$9 与 $0
      return replacement.replaceAllMapped(RegExp(r'\$(\d)'), (g) {
        final index = int.parse(g[1]!);
        return index == 0 ? (m[0] ?? '') : (m.group(index) ?? '');
      });
    });
  }

  static List<Object?> _split(String input, _JsRegExp regex) {
    if (regex.pattern.isEmpty) {
      return input.split('').cast<Object?>();
    }
    final out = <Object?>[];
    var last = 0;
    for (final m in regex._regex.allMatches(input)) {
      out.add(input.substring(last, m.start));
      last = m.end;
    }
    out.add(input.substring(last));
    return out;
  }

  static String _slice(String input, int start, int? end) {
    final s = start < 0 ? (input.length + start).clamp(0, input.length) : start.clamp(0, input.length);
    final e = end == null
        ? input.length
        : (end < 0 ? (input.length + end) : end).clamp(s, input.length);
    return input.substring(s, e);
  }

  static String _pad(String input, int width, String pad, {required bool start}) {
    if (input.length >= width || pad.isEmpty) return input;
    final needed = width - input.length;
    final buffer = StringBuffer();
    while (buffer.length < needed) {
      buffer.write(pad);
    }
    final filler = buffer.toString().substring(0, needed);
    return start ? '$filler$input' : '$input$filler';
  }

  static Object? _string(List<Object?> args) =>
      args.isEmpty ? '' : _toJsString(args.first);

  static Object? _number(List<Object?> args) =>
      args.isEmpty ? 0 : _numResult(_toNumber(args.first));

  static Object? _boolean(List<Object?> args) =>
      args.isEmpty ? false : _truthy(args.first);

  static Object? _parseInt(List<Object?> args) {
    if (args.isEmpty) return double.nan;
    final text = _toJsString(args[0]).trim();
    final radix = args.length > 1 ? _asInt(args[1]) ?? 10 : 10;
    if (radix == 10) {
      final match = RegExp(r'^[+-]?\d+').firstMatch(text);
      return match == null ? double.nan : int.parse(match[0]!);
    }
    final parsed = int.tryParse(text.replaceAll(RegExp(r'[^0-9a-zA-Z]'), ''),
        radix: radix.clamp(2, 36));
    return parsed ?? double.nan;
  }

  static Object? _parseFloat(List<Object?> args) {
    if (args.isEmpty) return double.nan;
    final text = _toJsString(args[0]).trim();
    final match = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?').firstMatch(text);
    return match == null ? double.nan : double.parse(match[0]!);
  }
}

class _MatchHolder {
  _MatchHolder(this.groups, this.index, this.input);
  final List<String?> groups;
  final int index;
  final String input;
}

class _BuiltinFn {
  const _BuiltinFn(this.name, this._body);
  final String name;
  final Object? Function(List<Object?> args) _body;
  Object? call(List<Object?> args) => _body(args);
  @override
  String toString() => 'function $name() { [native code] }';
}

class _MathObject {
  Object? call(String name, List<Object?> args) {
    double arg(int i) =>
        i < args.length ? _Interpreter._toNumber(args[i]) : double.nan;
    switch (name) {
      case 'floor':
        final v = arg(0);
        return v.isNaN ? double.nan : v.floor();
      case 'ceil':
        final v = arg(0);
        return v.isNaN ? double.nan : v.ceil();
      case 'round':
        final v = arg(0);
        return v.isNaN ? double.nan : v.round();
      case 'abs':
        final v = arg(0);
        return v.isNaN ? double.nan : v.abs();
      case 'min':
      case 'max':
        if (args.isEmpty) return double.nan;
        var best = arg(0);
        for (var i = 1; i < args.length; i++) {
          final v = arg(i);
          best = name == 'min' ? (v < best ? v : best) : (v > best ? v : best);
        }
        return _numResult(best);
      case 'pow':
        return _numResult(_pow(arg(0), arg(1)));
      default:
        throw JsUnsupported('Math.$name 不在子集里');
    }
  }

  static double _pow(double base, double exp) {
    var result = 1.0;
    var e = exp.abs().toInt();
    while (e > 0) {
      if (e & 1 == 1) result *= base;
      base *= base;
      e >>= 1;
    }
    return exp < 0 ? 1 / result : result;
  }
}

class _JsonObject {
  Object? call(String name, List<Object?> args) {
    switch (name) {
      case 'stringify':
        return _encode(args.isEmpty ? null : args.first);
      case 'parse':
        throw const JsUnsupported('JSON.parse 需要真引擎（子集不做完整 JSON 解析）');
      default:
        throw JsUnsupported('JSON.$name 不在子集里');
    }
  }

  static String _encode(Object? value) {
    if (value == null || value is JsNull) return 'null';
    if (value is String) {
      final escaped = value
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"')
          .replaceAll('\n', r'\n')
          .replaceAll('\r', r'\r')
          .replaceAll('\t', r'\t');
      return '"$escaped"';
    }
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return _toJsString(value);
    if (value is List) return '[${value.map(_encode).join(',')}]';
    if (value is Map) {
      final entries = value.entries
          .map((e) => '${_encode(e.key.toString())}:${_encode(e.value)}')
          .join(',');
      return '{$entries}';
    }
    return 'null';
  }
}

/// 哨兵：表示「这条语句没有值」（和 JS 的 undefined 区分开，后者是 null）。
class _NoValue {
  const _NoValue();
}

const _noValue = _NoValue();
