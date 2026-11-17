/// AI 正文纠错：厂商目录 + 三种协议的请求构造 + 纠错任务的提示词与解析。
///
/// 不依赖任何第三方包，只依赖 `dart:convert`。
/// 网络由调用方注入 [HttpPost]（Flutter 侧用 HttpClient，测试侧用假实现）。
///
/// 设计要点：
///   - key 只存在本机（SharedPreferences），不进日志、不进备份、不进崩溃上报
///   - 纠错是「替换」不是「重写」：模型必须逐行回传，行数对不上就整体作废
///   - 任何一段校验不过，退回原文，绝不让模型猜着改
library;

import 'dart:convert';

/// 三种协议。
enum AiProtocol {
  /// OpenAI /chat/completions（DeepSeek、Kimi、智谱、通义、豆包、Grok、OpenRouter、Ollama…都是这套）
  openai,

  /// Anthropic /messages
  anthropic,

  /// Google /models/{model}:generateContent
  gemini,
}

/// 一个厂商预设。
class AiProvider {
  const AiProvider({
    required this.id,
    required this.label,
    required this.protocol,
    required this.baseUrl,
    required this.models,
    required this.defaultModel,
    required this.keyHint,
    required this.contextTokens,
    required this.cn,
  });

  final String id;
  final String label;
  final AiProtocol protocol;
  final String baseUrl;
  final List<String> models;
  final String defaultModel;
  final String keyHint;
  final int contextTokens;

  /// 国内厂商：走不走代理由用户决定，这里只用来在设置页做个分组。
  final bool cn;

  factory AiProvider.fromJson(Map<String, dynamic> json) => AiProvider(
        id: json['id'] as String,
        label: json['label'] as String? ?? json['id'] as String,
        protocol: switch (json['kind']) {
          'anthropic' => AiProtocol.anthropic,
          'gemini' => AiProtocol.gemini,
          _ => AiProtocol.openai,
        },
        baseUrl: json['baseUrl'] as String? ?? '',
        models: [
          for (final m in (json['models'] as List? ?? const []))
            if (m is String) m,
        ],
        defaultModel: json['defaultModel'] as String? ?? '',
        keyHint: json['keyHint'] as String? ?? '',
        contextTokens: json['contextTokens'] is int ? json['contextTokens'] as int : 32768,
        cn: json['cn'] == true,
      );

  static List<AiProvider> parseCatalog(String raw) {
    final decoded = jsonDecode(raw);
    final list = (decoded is Map ? decoded['providers'] : decoded) as List? ?? const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) AiProvider.fromJson(item),
    ];
  }

  AiProvider copyWith({String? baseUrl, String? defaultModel, List<String>? models}) =>
      AiProvider(
        id: id,
        label: label,
        protocol: protocol,
        baseUrl: baseUrl ?? this.baseUrl,
        models: models ?? this.models,
        defaultModel: defaultModel ?? this.defaultModel,
        keyHint: keyHint,
        contextTokens: contextTokens,
        cn: cn,
      );
}

/// 用户配置好的一家厂商。
class AiConfig {
  const AiConfig({
    required this.providerId,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    this.maxOutputTokens = 4096,
    this.temperature = 0.1,
  });

  final String providerId;
  final String baseUrl;
  final String model;
  final String apiKey;
  final int maxOutputTokens;

  /// 纠错要稳，温度给低。
  final double temperature;

  bool get usable => baseUrl.isNotEmpty && model.isNotEmpty && (apiKey.isNotEmpty || providerId == 'ollama');

  /// 实际生效的 Base URL：用户没填（或填了空串）就回落到厂商默认。
  ///
  /// 设置页允许「留空表示用默认」，所以这一步必须在 [AiConfig] 里做，
  /// 不能指望调用方每次都把默认值抄进来。
  AiConfig resolveBaseUrl(AiProvider provider) {
    if (baseUrl.isNotEmpty) return this;
    if (provider.baseUrl.isEmpty) return this;
    return AiConfig(
      providerId: providerId,
      baseUrl: provider.baseUrl,
      model: model,
      apiKey: apiKey,
      maxOutputTokens: maxOutputTokens,
      temperature: temperature,
    );
  }

  Map<String, Object?> toJson() => {
        'providerId': providerId,
        'baseUrl': baseUrl,
        'model': model,
        'maxOutputTokens': maxOutputTokens,
        'temperature': temperature,
        // key 单独存，绝不进这个 Map
      };

  /// 从存储恢复（key 由调用方从安全存储读出来再补上）。
  static AiConfig fromJson(Map<String, dynamic> json, {String apiKey = ''}) => AiConfig(
        providerId: json['providerId'] as String? ?? 'deepseek',
        baseUrl: json['baseUrl'] as String? ?? '',
        model: json['model'] as String? ?? '',
        apiKey: apiKey,
        maxOutputTokens: json['maxOutputTokens'] is int ? json['maxOutputTokens'] as int : 4096,
        temperature: json['temperature'] is num ? (json['temperature'] as num).toDouble() : 0.1,
      );
}

/// 发一个 POST，回 (状态码, 响应体)。
typedef HttpPost = Future<HttpResponse> Function(
  String url,
  Map<String, String> headers,
  String body,
);

class HttpResponse {
  const HttpResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

/// 构造三家协议各自的请求。
class AiRequest {
  const AiRequest({
    required this.url,
    required this.headers,
    required this.body,
    required this.path,
  });

  final String url;
  final Map<String, String> headers;
  final String body;

  /// openai / anthropic / gemini，日志里打这个而不是打 URL（URL 里可能带 key）。
  final String path;
}

AiRequest buildRequest({
  required AiProvider provider,
  required AiConfig config,
  required String systemPrompt,
  required String userPrompt,
}) {
  final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
  switch (provider.protocol) {
    case AiProtocol.openai:
      return AiRequest(
        url: '$base/chat/completions',
        headers: {
          'Content-Type': 'application/json',
          if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
        },
        body: jsonEncode({
          'model': config.model,
          'temperature': config.temperature,
          'max_tokens': config.maxOutputTokens,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userPrompt},
          ],
        }),
        path: 'openai',
      );
    case AiProtocol.anthropic:
      return AiRequest(
        url: '$base/messages',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': config.apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: jsonEncode({
          'model': config.model,
          'max_tokens': config.maxOutputTokens,
          'temperature': config.temperature,
          'system': systemPrompt,
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': userPrompt},
              ],
            },
          ],
        }),
        path: 'anthropic',
      );
    case AiProtocol.gemini:
      return AiRequest(
        url: '$base/models/${config.model}:generateContent?key=${Uri.encodeQueryComponent(config.apiKey)}',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'systemInstruction': {
            'parts': [
              {'text': systemPrompt},
            ],
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': userPrompt},
              ],
            },
          ],
          'generationConfig': {
            'temperature': config.temperature,
            'maxOutputTokens': config.maxOutputTokens,
          },
        }),
        path: 'gemini',
      );
  }
}

/// 从响应体里抠出模型回的正文。
String parseResponse(AiProtocol protocol, String body) {
  final decoded = jsonDecode(body);
  switch (protocol) {
    case AiProtocol.openai:
      final choices = (decoded as Map)['choices'];
      if (choices is List && choices.isNotEmpty) {
        final message = (choices.first as Map)['message'];
        if (message is Map && message['content'] is String) {
          return message['content'] as String;
        }
      }
      throw const AiError('返回里没有 choices[0].message.content');
    case AiProtocol.anthropic:
      final content = (decoded as Map)['content'];
      if (content is List) {
        final buffer = StringBuffer();
        for (final block in content) {
          if (block is Map && block['type'] == 'text' && block['text'] is String) {
            buffer.write(block['text']);
          }
        }
        if (buffer.isNotEmpty) return buffer.toString();
      }
      throw const AiError('返回里没有 content[0].text');
    case AiProtocol.gemini:
      final candidates = (decoded as Map)['candidates'];
      if (candidates is List && candidates.isNotEmpty) {
        final parts = (candidates.first as Map)['content'];
        if (parts is Map && parts['parts'] is List) {
          final buffer = StringBuffer();
          for (final part in parts['parts'] as List) {
            if (part is Map && part['text'] is String) buffer.write(part['text']);
          }
          if (buffer.isNotEmpty) return buffer.toString();
        }
      }
      throw const AiError('返回里没有 candidates[0].content.parts[0].text');
  }
}

/// 把厂商返回的英文报错翻成人话，方便用户判断是 key 错了还是额度过期了。
String humanizeHttpError(int status, String body) {
  final snippet = body.length > 300 ? '${body.substring(0, 300)}…' : body;
  switch (status) {
    case 401:
    case 403:
      return '鉴权失败（HTTP $status）：key 不对、没开通该模型，或者 Base URL 填错。$snippet';
    case 402:
      return '余额不足（HTTP 402）：去厂商控制台充值。$snippet';
    case 404:
      return '接口不存在（HTTP 404）：Base URL 或模型名不对。$snippet';
    case 413:
      return '请求体太大（HTTP 413）：这段文本超了上下文，改成按段纠错。$snippet';
    case 429:
      return '限流（HTTP 429）：太快了，等几秒再试。$snippet';
    case 500:
    case 502:
    case 503:
      return '厂商服务异常（HTTP $status）：过一会儿再试。$snippet';
    default:
      return 'HTTP $status：$snippet';
  }
}

class AiError implements Exception {
  const AiError(this.message);
  final String message;
  @override
  String toString() => message;
}

// ───────────────────────── 纠错任务 ─────────────────────────

/// 一段被标记了序号的正文。
class TextSegment {
  const TextSegment(this.index, this.text);
  final int index;
  final String text;
}

/// 纠错结果。
class ProofreadResult {
  const ProofreadResult({
    required this.segments,
    required this.changed,
    required this.raw,
  });

  /// 纠错后的段落，顺序与输入一致。
  final List<String> segments;

  /// 哪几段真的变了。
  final List<int> changed;

  /// 模型原始回包，排查用。
  final String raw;

  int get changedCount => changed.length;
  bool get anyChange => changed.isNotEmpty;
}

/// 纠错任务：给定一段正文，产出纠错结果。
class ProofreadTask {
  const ProofreadTask({
    this.maxSegmentsPerCall = 40,
    this.maxCharsPerCall = 3000,
    this.keepStyle = true,
  });

  final int maxSegmentsPerCall;
  final int maxCharsPerCall;

  /// true = 只改错字/乱码/多余字，不动文风；false = 允许顺句子。
  final bool keepStyle;

  static const systemPrompt = '''
你是一个中文小说校对器。任务：只在必要处修正文本，不要重写。

必须修正的四类问题：
1. 错别字（形近、音近误用），例如「他的的脸」→「他的脸」
2. 乱码：连续的 ???、?、、□、无意义符号堆叠、乱序方块字
3. 多余的重复字：连续的「的的的」「了了」「我我」，除非是口吃或强调
4. 明显断错位置的标点：句号跑到引号外、整段没有句读

禁止做的事：
- 不要改人名、地名、招式名、自造词
- 不要改对话语气、方言、口头禅
- 不要增删情节、不要补写
- 不要合并或拆分段落（行数必须和输入一模一样）

输出格式（严格遵守）：
- 只输出正文，每行以 [序号] 开头，序号照抄输入
- 没有问题的行，原样照抄，一个字都不许改
- 不要输出解释、不要加空行、不要用代码块包裹

例：
输入
[1] 他的的脸红了
[2] 天亮了，他起??床
输出
[1] 他的脸红了
[2] 天亮了，他起了床
''';

  /// 把正文切成若干批，每批不超过行数/字数上限。
  List<List<TextSegment>> chunk(List<String> paragraphs) {
    final batches = <List<TextSegment>>[];
    var current = <TextSegment>[];
    var chars = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      final line = paragraphs[i];
      if (current.isNotEmpty &&
          (current.length >= maxSegmentsPerCall || chars + line.length > maxCharsPerCall)) {
        batches.add(current);
        current = <TextSegment>[];
        chars = 0;
      }
      current.add(TextSegment(i + 1, line));
      chars += line.length;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  String buildUserPrompt(List<TextSegment> batch) {
    final buffer = StringBuffer();
    if (!keepStyle) buffer.writeln('允许在不改变原意的前提下顺一顺不通顺的句子。');
    buffer.writeln('输入');
    for (final segment in batch) {
      buffer.writeln('[${segment.index}] ${segment.text}');
    }
    buffer.writeln('输出');
    return buffer.toString();
  }

  /// 解析模型回包。行号对不上、条数不对、出现无法识别的行 → 抛 [AiError]，
  /// 由上层整批退回原文。
  List<TextSegment> parseReply(String reply, List<TextSegment> batch) {
    final expected = {for (final s in batch) s.index};
    final got = <int, String>{};
    final linePattern = RegExp(r'^\s*\[(\d+)\]\s?(.*)$');
    for (final line in const LineSplitter().convert(reply)) {
      if (line.trim().isEmpty) continue;
      final match = linePattern.firstMatch(line);
      if (match == null) {
        // 模型没按格式来：整批作废，别让它污染原文
        throw AiError('模型输出行格式不对：${line.length > 40 ? '${line.substring(0, 40)}…' : line}');
      }
      final index = int.tryParse(match.group(1)!);
      if (index == null || !expected.contains(index)) {
        throw AiError('模型给了不存在的行号 $index');
      }
      if (got.containsKey(index)) {
        throw AiError('模型重复给了行号 $index');
      }
      got[index] = match.group(2) ?? '';
    }
    final missing = expected.difference(got.keys.toSet());
    if (missing.isNotEmpty) {
      throw AiError('模型漏了 ${missing.length} 行（例如 ${missing.first}）');
    }
    return [
      for (final segment in batch) TextSegment(segment.index, got[segment.index]!),
    ];
  }

  /// 合并多批结果。
  ProofreadResult merge(
    List<String> original,
    List<List<TextSegment>> parsedBatches,
    String raw,
  ) {
    final fixed = List<String>.from(original);
    final changed = <int>[];
    for (final batch in parsedBatches) {
      for (final segment in batch) {
        final i = segment.index - 1;
        if (i < 0 || i >= fixed.length) continue;
        final next = segment.text;
        if (next != fixed[i]) {
          changed.add(segment.index);
          fixed[i] = next;
        }
      }
    }
    return ProofreadResult(segments: fixed, changed: changed, raw: raw);
  }
}

/// 真正的执行器：一批一批发。
class Proofreader {
  Proofreader({
    required this.provider,
    required this.config,
    required this.post,
    this.task = const ProofreadTask(),
  });

  final AiProvider provider;
  final AiConfig config;
  final HttpPost post;
  final ProofreadTask task;

  /// 用户没填 Base URL 时回落到厂商默认，所有出网前的最后一道归一化。
  AiConfig get _effective => config.resolveBaseUrl(provider);

  /// 单段文本纠错（选中一段 → AI 纠错）。
  Future<ProofreadResult> proofread(List<String> paragraphs) async {
    final effective = _effective;
    if (!effective.usable) {
      throw const AiError('AI 未配置：缺少 Base URL / 模型 / API Key');
    }
    final batches = task.chunk(paragraphs);
    final parsed = <List<TextSegment>>[];
    final rawBuffer = StringBuffer();
    for (final batch in batches) {
      final request = buildRequest(
        provider: provider,
        config: effective,
        systemPrompt: ProofreadTask.systemPrompt,
        userPrompt: task.buildUserPrompt(batch),
      );
      final response = await post(request.url, request.headers, request.body);
      rawBuffer.writeln(response.body);
      if (response.statusCode != 200) {
        throw AiError(humanizeHttpError(response.statusCode, response.body));
      }
      final reply = parseResponse(provider.protocol, response.body);
      parsed.add(task.parseReply(reply, batch));
    }
    return task.merge(paragraphs, parsed, rawBuffer.toString());
  }

  /// 连通性测试：发一句最短的话，看能不能拿到回包。
  Future<String> ping() async {
    final effective = _effective;
    final request = buildRequest(
      provider: provider,
      config: effective,
      systemPrompt: '你是一个回声器，只回一个字：好',
      userPrompt: '在吗',
    );
    final response = await post(request.url, request.headers, request.body);
    if (response.statusCode != 200) {
      throw AiError(humanizeHttpError(response.statusCode, response.body));
    }
    return parseResponse(provider.protocol, response.body).trim();
  }
}
