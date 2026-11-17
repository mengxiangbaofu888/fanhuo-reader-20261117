/// 书源规则引擎 —— 把阅读（Legado）/ 旷野书屋那套规则语法，
/// 在 Dart 侧重新实现一个可运行的子集。
///
/// 支持的语法（按旷野 133 个书源的实际使用率排）：
///   1. 默认规则：`class.foo.0@tag.a@text`、`id.content@html`、`tag.dd@tag.h3@tag.a@href`
///      —— 圆点数字 `[n]` 取第 n 个，负数从后取；末段是属性名（text / html / href / src / content…）
///   2. `@css:选择器` —— 走 csslib 解析器
///   3. `@XPath:` / 以 `//` 开头 —— 走 xml 包
///   4. 提炼规则：`##正则` 或 `##正则##替换`（`##` 之后是排除/替换）
///   5. `{{key}}` / `{{page}}` 变量替换（URL 里）
/// 6. `searchUrl` 的 JSON 形配置：`url,{\n "method":"POST",\n "body":"...",\n "charset":"gbk"}`
///
/// JS 规则分三档处理（见 [js_subset] 与 [executeJs]）：
///   - **simple（605 条）**：纯字符串/正则/算术 → 由内置子集解释器执行，不需要真引擎
///   - mid（373 条）：`java.ajax` / `base64` / `JSON.parse` → 抛 [RuleUnsupported]，
///     等 1.5.0 接 QuickJS 后回落真引擎
///   - hard（15 条）：`Packages.javax.crypto` 签名 → 标「不支持」
/// 无论哪一档，跑不了的都抛 [RuleUnsupported] 并写清原因，绝不静默返回空。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'js_subset.dart';

/// 规则无法在纯 Dart 侧求值。
class RuleUnsupported implements Exception {
  const RuleUnsupported(this.rule, this.reason);
  final String rule;
  final String reason;
  @override
  String toString() => '规则需要 JS 求值：$rule（$reason）';
}

/// 解析失败。
class RuleSyntaxError implements Exception {
  const RuleSyntaxError(this.rule, this.message);
  final String rule;
  final String message;
  @override
  String toString() => '规则语法错误：$rule —— $message';
}

/// 一条规则解析后的两部分：取值规则 + 提炼规则。
class ParsedRule {
  const ParsedRule({required this.selector, this.extract, this.replace});
  final String selector;
  final String? extract;
  final String? replace;
}

/// 规则引擎本体。无状态，随便并发调。
abstract final class RuleEngine {
  /// 规则里出现这些就说明要执行 JS。
  static bool needsJs(String rule) {
    final lower = rule.toLowerCase();
    return lower.contains('@js:') || lower.contains('<js>') || lower.contains('</js>');
  }

  /// 这段规则能不能用**内置子集解释器**跑（不依赖真引擎）。
  ///
  /// 返回 true 只代表「语法上像子集」，真正能不能跑要等 [executeJs] 试。
  /// 这里做的是廉价预筛，用来在搜索队列里区分「可跑 / 需引擎」。
  static bool jsLikelySubset(String rule) {
    if (!needsJs(rule)) return false;
    final script = extractJs(rule);
    if (script == null) return false;
    // 这些 API 一定需要真引擎或 Java 反射
    const blockers = [
      'java.',
      'Java.',
      'Packages.',
      'JavaImporter',
      'importPackage',
      'javax.',
      'Cipher',
      '__dex__',
      'JSON.parse',
      'base64Decode',
      'base64Encode',
      'md5',
      'MD5',
      'cookie.',
      'new Date',
      'Date(',
    ];
    return !blockers.any(script.contains);
  }

  /// 从规则里抠出 JS 源码。两种写法：
  ///   `rule@js:代码`  → 代码在 `@js:` 之后
  ///   `<js>代码</js>` → 代码在标签之间
  static String? extractJs(String rule) {
    final jsIndex = rule.indexOf('@js:');
    if (jsIndex >= 0) return rule.substring(jsIndex + 4);
    final open = rule.indexOf('<js>');
    if (open >= 0) {
      final close = rule.indexOf('</js>', open + 4);
      final end = close < 0 ? rule.length : close;
      return rule.substring(open + 4, end);
    }
    if (rule.toLowerCase().contains('</js>')) return null;
    return null;
  }

  /// 执行规则里的 JS。
  ///
  /// 顺序固定：**先子集，再抛 RuleUnsupported**（1.5.0 会在这里回落 QuickJS）。
  /// 子集里不支持 → 抛 [RuleUnsupported] 且 reason 写「超出 JS 子集」，
  /// 上层据此决定「跳过该源 / 标不支持」，绝不静默返回空字符串。
  static String executeJs(
    String rule, {
    required String result,
    String base = '',
    String key = '',
  }) {
    final script = extractJs(rule);
    if (script == null || script.trim().isEmpty) {
      throw RuleUnsupported(rule, 'JS 规则里没有脚本');
    }
    try {
      return js_subset.evaluateJs(
        script,
        js_subset.JsScope(result: result, baseUrl: base, key: key),
      );
    } on js_subset.JsUnsupported catch (error) {
      throw RuleUnsupported(rule, '超出 JS 子集：${error.message}');
    }
  }

  /// 把 `A##B##C` 拆成 selector / extract / replace。
  static ParsedRule parse(String raw) {
    if (needsJs(raw)) throw RuleUnsupported(raw, '含 JS 规则');
    final parts = raw.split('##');
    final selector = parts[0].trim();
    final extract = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
    final replace = parts.length > 2 ? parts[2] : null;
    if (selector.isEmpty) throw RuleSyntaxError(raw, '选择器为空');
    return ParsedRule(
      selector: selector,
      extract: extract,
      replace: _normalizeReplacement(replace),
    );
  }

  /// 阅读规则里 `$1` 是分组引用，`\n` 是换行。原样保留分组引用，只把字面量 `\n` 换成换行。
  static String? _normalizeReplacement(String? replace) {
    if (replace == null) return null;
    return replace.replaceAll(r'\n', '\n');
  }

  /// 对一份已解析的 HTML 文档取一段文本。
  ///
  /// [base] 用于把 `href` / `src` 补成绝对地址。
  static String? pick(
    dom.Document document,
    String rawRule, {
    String base = '',
    bool all = false,
  }) {
    final rule = parse(rawRule);
    final nodes = _select(document, rule.selector, base);
    if (nodes.isEmpty) return null;
    final values = <String>[];
    for (final node in all ? nodes : [nodes.first]) {
      final value = _valueOf(node, rule.selector, base);
      if (value != null && value.trim().isNotEmpty) values.add(value);
    }
    if (values.isEmpty) return null;
    var joined = all ? values.join('\n') : values.first;
    joined = _applyExtract(rawRule, rule, joined);
    return joined.trim().isEmpty ? null : joined.trim();
  }

  /// 把已经选中的节点按属性/文本取值（`@href` / `@src` / `@text` / `@html`）。
  ///
  /// 和 `pickIn` 分开是必要的：`pickIn` 是「从 root 子树里选」，这里是对
  /// **已经选到的那一个节点**取属性，不再做任何选择。
  static String? valueOf(
    dom.Node node,
    String rawRule, {
    String base = '',
  }) {
    final rule = parse(rawRule);
    var value = _valueOf(node, rule.selector, base);
    if (value == null) return null;
    value = _applyExtract(rawRule, rule, value);
    return value.trim().isEmpty ? null : value.trim();
  }

  /// 提炼规则：阅读里 `##正则` 是**排除**（删掉匹配到的部分），
  /// `##正则##替换` 是**匹配后替换**。没有替换段时按删除处理。
  static String _applyExtract(String rawRule, ParsedRule rule, String value) {
    if (rule.extract == null) return value;
    RegExp re;
    try {
      re = RegExp(rule.extract!);
    } catch (error) {
      throw RuleSyntaxError(rawRule, '正则编译失败：$error');
    }
    final replacement = rule.replace ?? '';
    if (replacement.isEmpty) {
      return value.replaceAll(re, '');
    }
    return value.replaceAllMapped(re, (m) => _expandGroups(replacement, m));
  }

  /// 取多节点（列表型规则，比如搜索结果的 bookList / 目录的 chapterList）。
  static List<dom.Element> selectNodes(dom.Document document, String rawRule) {
    final rule = parse(rawRule);
    return _select(document, rule.selector, '').whereType<dom.Element>().toList();
  }
  /// 从某个已选中的节点往**下**取多节点（相对规则）。
  static List<dom.Element> selectNodesFrom(dom.Element root, String rawRule) {
    final rule = parse(rawRule);
    return _selectFrom(root, rule.selector, '').whereType<dom.Element>().toList();
  }

  /// 在一个已选中的节点内部继续取（搜索结果里，name/author 都是相对 bookList 节点的）。
  ///
  /// `document` 参数保留是为了调用方接口稳定（有些规则要跨节点取上下文），
  /// 下钻本身只从 `root` 子树开始 —— 这与阅读里「bookList 之后的规则都相对条目」一致。
  static String? pickIn(
    dom.Element root,
    dom.Document document,
    String rawRule, {
    String base = '',
  }) {
    final rule = parse(rawRule);
    final nodes = _selectFrom(root, rule.selector, base);
    if (nodes.isEmpty) return null;
    var value = _valueOf(nodes.first, rule.selector, base);
    if (value == null) return null;
    value = _applyExtract(rawRule, rule, value);
    return value.trim().isEmpty ? null : value.trim();
  }

  static String _expandGroups(String template, Match m) {
    return template.replaceAllMapped(RegExp(r'\$(\d)'), (g) {
      final index = int.tryParse(g.group(1)!) ?? 0;
      if (index == 0) return m.group(0) ?? '';
      return m.group(index) ?? '';
    });
  }

  /// `class.foo.0@tag.a@href` 这样的默认规则：逐段下钻。
  static List<dom.Node> _select(dom.Document document, String selector, String base) {
    if (selector.startsWith('@css:')) {
      final css = selector.substring(5).trim();
      return _cssSelect(document.documentElement!, css);
    }
    if (selector.startsWith('@XPath:') || selector.startsWith('//') || selector.startsWith('/html')) {
      throw RuleUnsupported(selector, 'XPath 需要 xml 包，第一期不实现');
    }
    return _walk(document.documentElement!, selector, base);
  }

  static List<dom.Node> _selectFrom(dom.Element root, String selector, String base) {
    if (selector.startsWith('@css:')) {
      return _cssSelect(root, selector.substring(5).trim());
    }
    return _walk(root, selector, base);
  }

  /// 逐段下钻：`class.a.b.0@tag.x@text`
  static List<dom.Node> _walk(dom.Node start, String selector, String base) {
    final steps = selector.split('@');
    var current = <dom.Node>[start];
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i].trim();
      if (step.isEmpty) continue;
      final isLast = i == steps.length - 1;
      if (isLast && _isAttributeStep(step)) break; // 取值步交给 _valueOf
      final next = <dom.Node>[];
      for (final node in current) {
        next.addAll(_applyStep(node, step));
      }
      current = next;
      if (current.isEmpty) return const [];
    }
    return current;
  }

  static const _attributes = {
    'text', 'textNodes', 'ownText', 'html', 'all', 'href', 'src', 'content',
    'title', 'alt', 'value', 'data-src', 'data-original', 'class', 'id',
    'contentUrl', 'textHtml',
  };

  /// `@text` / `@src` 这种「取值步」不是选择步。
  ///
  /// 只有 `@` 之后**裸写**的才是取值（`tag.a@href`）；
  /// 带点的一律是选择（`tag.a@tag.img`、`class.foo.0@tag.span`）——
  /// 否则 `tag.img` 会被当成「取属性 img」，整条链在最后一步被吞掉。
  static bool _isAttributeStep(String step) {
    return _attributes.contains(step) && !step.contains('.');
  }

  static List<dom.Node> _applyStep(dom.Node node, String step) {
    // 形如 class.foo / id.bar / tag.div / text.下一页，尾部 .n 是索引
    final parts = step.split('.');
    final kind = parts[0];
    int? index;
    String? name;
    if (parts.length >= 2) {
      final last = parts.last;
      final parsed = int.tryParse(last);
      if (parsed != null) {
        index = parsed;
        if (parts.length > 2) name = parts.sublist(1, parts.length - 1).join('.');
      } else {
        // 属性步不该走到这里（_walk 里已经 break），保险起见按名字处理
        name = parts.sublist(1).join('.');
      }
    }
    // 正索引先按文档序一遍过；负索引 / 带名字的 text 步才需要完整列表。
    // 用 `take(index + 1)` 提前收敛，避免对整棵树 selector 全量匹配。

    List<dom.Node> collect(Iterable<dom.Element> candidates) {
      final out = <dom.Node>[];
      for (final element in candidates) {
        if (index != null && index >= 0 && out.length > index) break;
        out.add(element);
        if (index != null && index >= 0 && out.length > index) break;
      }
      return out;
    }

    List<dom.Node> result;
    switch (kind) {
      case 'class':
        result = node is dom.Element
            ? collect(node.querySelectorAll('.${_escapeIdent(name ?? '')}'))
            : const [];
        break;
      case 'id':
        result = node is dom.Element
            ? collect(node.querySelectorAll('#${_escapeIdent(name ?? '')}'))
            : const [];
        break;
      case 'tag':
        result = node is dom.Element
            ? collect(node.querySelectorAll(name ?? '*'))
            : const [];
        break;
      case 'children':
        result = node.nodes.toList();
        break;
      case 'text':
        // 阅读语法里 `text.下一页` 表示「文本等于 下一页 的元素」
        final wanted = name ?? '';
        result = node is dom.Element
            ? node
                .querySelectorAll('*')
                .where((e) => e.text.trim() == wanted)
                .toList()
            : const [];
        break;
      case 'textNodes':
        result = node.nodes.whereType<dom.Text>().toList();
        break;
      default:
        return const [];
    }
    if (index != null) {
      final i = index < 0 ? result.length + index : index;
      if (i < 0 || i >= result.length) return const [];
      return [result[i]];
    }
    return result;
  }

  static String _escapeIdent(String name) =>
      name.replaceAll(RegExp(r'([^\w-])'), r'\$1');

  static String? _valueOf(dom.Node node, String selector, String base) {
    final lastStep = selector.split('@').last.trim();
    if (node is dom.Element) {
      if (lastStep == 'text' || lastStep == 'ownText') return node.text;
      if (lastStep == 'html' || lastStep == 'all') return node.innerHtml;
      if (_attributes.contains(lastStep)) {
        return _attributeOf(node, lastStep, base);
      }
      return node.text;
    }
    return node.text;
  }

  /// 取元素属性。
  ///
  /// `html` 包（0.15.x）的 `Element.attributes` 是 `LinkedHashMap<Object, String>`：
  /// 普通 HTML 属性的键是 `String`（小写名），只有带命名空间的（`xlink:href` 之类）
  /// 才用 `AttributeName`。所以 `attributes['src']` 本身是对的，
  /// 但书源站常写 `SRC` / `Src`，或者用 `data-src` 懒加载，这里做两步兜底：
  ///   1. 小写名取不到 → 遍历一遍按 `key.toString().toLowerCase()` 比对
  ///   2. 要 `src` 却拿不到 → 依次试 `data-src` / `data-original` / `data-lazy-src`
  static String? _attributeOf(dom.Element node, String name, String base) {
    String? direct(String key) {
      final found = node.attributes[key];
      if (found == null || found.trim().isEmpty) return null;
      return found;
    }

    var raw = direct(name);
    if (raw == null) {
      final lower = name.toLowerCase();
      for (final entry in node.attributes.entries) {
        if (entry.key.toString().toLowerCase() == lower &&
            entry.value.trim().isNotEmpty) {
          raw = entry.value;
          break;
        }
      }
    }
    if (raw == null && name == 'src') {
      raw = direct('data-src') ?? direct('data-original') ?? direct('data-lazy-src');
    }
    if (raw == null) return null;
    return _absolute(raw.trim(), base);
  }

  static String _absolute(String raw, String base) {
    if (raw.isEmpty || base.isEmpty) return raw;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    try {
      return Uri.parse(base).resolve(raw).toString();
    } catch (_) {
      return raw;
    }
  }

  static List<dom.Node> _cssSelect(dom.Element root, String css) {
    try {
      return root.querySelectorAll(css);
    } on Exception catch (error) {
      throw RuleSyntaxError(css, '$error');
    }
  }

  // ---------- 便捷入口 ----------

  static dom.Document parseHtml(String source) => html_parser.parse(source);

  /// URL 变量替换：`{{key}}` / `{{page}}` / `{{page+1}}`。
  static String fillTemplate(String template, {required String key, int? page}) {
    var out = template.replaceAll('{{key}}', Uri.encodeQueryComponent(key));
    out = out.replaceAll('{{page}}', '${page ?? 1}');
    out = out.replaceAllMapped(RegExp(r'\{\{page\+(\d+)\}\}'), (m) {
      final plus = int.tryParse(m.group(1)!) ?? 0;
      return '${(page ?? 1) + plus}';
    });
    return out;
  }

  /// 拆 `url,{json}` 形式的 searchUrl。
  static SearchRequest parseSearchUrl(String raw, {required String key, int? page}) {
    final commaAt = raw.indexOf(',{');
    if (commaAt == -1) {
      return SearchRequest(url: fillTemplate(raw.trim(), key: key, page: page));
    }
    final url = fillTemplate(raw.substring(0, commaAt).trim(), key: key, page: page);
    final configText = raw.substring(commaAt + 1);
    final method = RegExp(r'"method"\s*:\s*"(\w+)"').firstMatch(configText)?.group(1) ?? 'GET';
    final bodyRaw = RegExp(r'"body"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(configText)?.group(1);
    final charset = RegExp(r'"charset"\s*:\s*"([\w-]+)"').firstMatch(configText)?.group(1);
    final body = bodyRaw == null
        ? null
        : fillTemplate(
            bodyRaw.replaceAll(r'\n', '\n').replaceAll(r'"', '"'),
            key: key,
            page: page,
          );
    return SearchRequest(
      url: url,
      method: method.toUpperCase(),
      body: body,
      charset: charset,
    );
  }
}

/// 一次搜索请求的最终形态。
class SearchRequest {
  const SearchRequest({
    required this.url,
    this.method = 'GET',
    this.body,
    this.charset,
  });
  final String url;
  final String method;
  final String? body;
  final String? charset;

  @override
  String toString() => '$method $url${body == null ? '' : ' body=$body'}';
}


