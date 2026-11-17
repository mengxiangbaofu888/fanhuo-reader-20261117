import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:wenku8_flutter/fanhuo/ai_proofread.dart';

/// 假网络：按顺序吐预设好的响应，并记下收到的请求。
class FakePost {
  FakePost(this.responses);
  final List<HttpResponse> responses;
  final List<AiRequest> requests = [];

  Future<HttpResponse> call(
    String url,
    Map<String, String> headers,
    String body,
  ) async {
    requests.add(AiRequest(url: url, headers: headers, body: body, path: 'test'));
    if (requests.length > responses.length) {
      throw StateError('第 ${requests.length} 次请求没有预备响应');
    }
    return responses[requests.length - 1];
  }
}

HttpResponse _ok(Map<String, Object?> json) =>
    HttpResponse(200, jsonEncode(json));

Map<String, Object?> _openAi(String content) => {
      'choices': [
        {
          'message': {'role': 'assistant', 'content': content},
        },
      ],
    };

Map<String, Object?> _anthropic(String content) => {
      'content': [
        {'type': 'text', 'text': content},
      ],
    };

Map<String, Object?> _gemini(String content) => {
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': content},
            ],
          },
        },
      ],
    };

const _deepseek = AiProvider(
  id: 'deepseek',
  label: 'DeepSeek',
  protocol: AiProtocol.openai,
  baseUrl: 'https://api.deepseek.com/v1',
  models: ['deepseek-chat'],
  defaultModel: 'deepseek-chat',
  keyHint: '',
  contextTokens: 65536,
  cn: true,
);

const _claude = AiProvider(
  id: 'claude',
  label: 'Claude',
  protocol: AiProtocol.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  models: ['claude-haiku-4-5'],
  defaultModel: 'claude-haiku-4-5',
  keyHint: '',
  contextTokens: 200000,
  cn: false,
);

const _gemini = AiProvider(
  id: 'gemini',
  label: 'Gemini',
  protocol: AiProtocol.gemini,
  baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  models: ['gemini-2.5-flash'],
  defaultModel: 'gemini-2.5-flash',
  keyHint: '',
  contextTokens: 1048576,
  cn: false,
);

AiConfig _config(String model, {String key = 'sk-test'}) =>
    AiConfig(providerId: 'x', baseUrl: '', model: model, apiKey: key);

void main() {
  group('厂商目录', () {
    test('从 JSON 目录解析出全部厂商，三种协议都在', () {
      final providers = AiProvider.parseCatalog(jsonEncode({
        'providers': [
          {'id': 'deepseek', 'label': 'DeepSeek', 'kind': 'openai', 'baseUrl': 'https://a/v1', 'models': ['m1'], 'defaultModel': 'm1', 'cn': true},
          {'id': 'claude', 'label': 'Claude', 'kind': 'anthropic', 'baseUrl': 'https://b/v1', 'models': ['m2'], 'defaultModel': 'm2'},
          {'id': 'gemini', 'label': 'Gemini', 'kind': 'gemini', 'baseUrl': 'https://c/v1beta', 'models': ['m3'], 'defaultModel': 'm3'},
        ],
      }));
      expect(providers.length, 3);
      expect(providers[0].protocol, AiProtocol.openai);
      expect(providers[1].protocol, AiProtocol.anthropic);
      expect(providers[2].protocol, AiProtocol.gemini);
      expect(providers[0].cn, isTrue);
    });
  });

  group('三种协议的请求构造', () {
    test('OpenAI 兼容：Bearer + messages', () {
      final request = buildRequest(
        provider: _deepseek,
        config: _config('deepseek-chat'),
        systemPrompt: 'sys',
        userPrompt: 'usr',
      );
      expect(request.url, 'https://api.deepseek.com/v1/chat/completions');
      expect(request.headers['Authorization'], 'Bearer sk-test');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'deepseek-chat');
      expect((body['messages'] as List).length, 2);
      expect(request.path, 'openai');
    });

    test('Anthropic：x-api-key + 顶层 system', () {
      final request = buildRequest(
        provider: _claude,
        config: _config('claude-haiku-4-5', key: 'sk-ant-x'),
        systemPrompt: 'sys',
        userPrompt: 'usr',
      );
      expect(request.url, 'https://api.anthropic.com/v1/messages');
      expect(request.headers['x-api-key'], 'sk-ant-x');
      expect(request.headers['anthropic-version'], isNotNull);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['system'], 'sys');
      expect(body['messages'], isA<List>());
    });

    test('Gemini：key 在查询串里，日志路径不外泄', () {
      final request = buildRequest(
        provider: _gemini,
        config: _config('gemini-2.5-flash', key: 'AIza-test'),
        systemPrompt: 'sys',
        userPrompt: 'usr',
      );
      expect(request.url, contains(':generateContent?key=AIza-test'));
      expect(request.path, 'gemini');
      expect(request.path, isNot(contains('AIza')));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['systemInstruction'], isNotNull);
    });
  });

  group('响应解析', () {
    test('三种协议都能抠出正文', () {
      expect(parseResponse(AiProtocol.openai, jsonEncode(_openAi('回'))), '回');
      expect(parseResponse(AiProtocol.anthropic, jsonEncode(_anthropic('回'))), '回');
      expect(parseResponse(AiProtocol.gemini, jsonEncode(_gemini('回'))), '回');
    });

    test('结构不对抛 AiError', () {
      expect(
        () => parseResponse(AiProtocol.openai, '{"choices":[]}'),
        throwsA(isA<AiError>()),
      );
    });
  });

  group('纠错任务', () {
    const task = ProofreadTask();

    test('分批：40 段以内一批', () {
      final batches = task.chunk(List.generate(90, (i) => '第$i段'));
      expect(batches.length, 3);
      expect(batches[0].length, 40);
      expect(batches[2].length, 10);
      expect(batches[0].first.index, 1);
      expect(batches[2].last.index, 90);
    });

    test('分批：按字数切', () {
      final long = '字' * 1200;
      final batches = task.chunk([long, long, long, long]);
      // 每批最多 3000 字 → 每批 2 段
      expect(batches.every((b) => b.length <= 2), isTrue);
    });

    test('解析：正常回包', () {
      const batch = [TextSegment(1, '他的的脸红了'), TextSegment(2, '天亮了')];
      final parsed = task.parseReply('[1] 他的脸红了\n[2] 天亮了', batch);
      expect(parsed[0].text, '他的脸红了');
      expect(parsed[1].text, '天亮了');
    });

    test('解析：漏行整批作废', () {
      const batch = [TextSegment(1, 'a'), TextSegment(2, 'b')];
      expect(() => task.parseReply('[1] a', batch), throwsA(isA<AiError>()));
    });

    test('解析：行格式不对整批作废', () {
      const batch = [TextSegment(1, 'a')];
      expect(
        () => task.parseReply('第一行：a', batch),
        throwsA(isA<AiError>()),
      );
    });

    test('解析：给了不存在的行号整批作废', () {
      const batch = [TextSegment(1, 'a')];
      expect(() => task.parseReply('[1] a\n[9] x', batch), throwsA(isA<AiError>()));
    });

    test('合并：只记真正变了的段', () {
      final result = task.merge(
        ['原文1', '原文2'],
        [
          [const TextSegment(1, '改后1'), const TextSegment(2, '原文2')],
        ],
        '',
      );
      expect(result.segments, ['改后1', '原文2']);
      expect(result.changed, [1]);
      expect(result.anyChange, isTrue);
    });

    test('提示词里写死了四类必须修与四条禁止', () {
      for (final word in ['错别字', '乱码', '多余的重复字', '标点']) {
        expect(ProofreadTask.systemPrompt, contains(word));
      }
      for (final word in ['人名', '对话语气', '增删情节', '行数必须和输入一模一样']) {
        expect(ProofreadTask.systemPrompt, contains(word));
      }
    });
  });

  group('端到端纠错', () {
    test('一段一次请求，改对了就落地', () async {
      final fake = FakePost([
        _ok(_openAi('[1] 他的脸红了\n[2] 天亮了，他起了床')),
      ]);
      final reader = Proofreader(
        provider: _deepseek,
        config: _config('deepseek-chat'),
        post: fake.call,
      );
      final result = await reader.proofread(['他的的脸红了', '天亮了，他起??床']);
      expect(result.segments, ['他的脸红了', '天亮了，他起了床']);
      expect(result.changed, [1, 2]);
      expect(fake.requests.length, 1);
    });

    test('模型乱答就整批退回，原文不动', () async {
      final fake = FakePost([_ok(_openAi('我帮你改好了：他的脸红了'))]);
      final reader = Proofreader(
        provider: _deepseek,
        config: _config('deepseek-chat'),
        post: fake.call,
      );
      expect(
        () => reader.proofread(['他的的脸红了']),
        throwsA(isA<AiError>()),
      );
    });

    test('HTTP 401 翻成人话', () async {
      final fake = FakePost([const HttpResponse(401, '{"error":"bad key"}')]);
      final reader = Proofreader(
        provider: _deepseek,
        config: _config('deepseek-chat'),
        post: fake.call,
      );
      try {
        await reader.proofread(['a']);
        fail('应该抛错');
      } on AiError catch (error) {
        expect(error.message, contains('鉴权失败'));
      }
    });

    test('未配置就报错，不发请求', () async {
      final fake = FakePost([]);
      final reader = Proofreader(
        provider: _deepseek,
        config: const AiConfig(
          providerId: 'deepseek',
          baseUrl: '',
          model: '',
          apiKey: '',
        ),
        post: fake.call,
      );
      expect(() => reader.proofread(['a']), throwsA(isA<AiError>()));
      expect(fake.requests, isEmpty);
    });

    test('ping 走同一套协议', () async {
      final fake = FakePost([_ok(_anthropic('好'))]);
      final reader = Proofreader(
        provider: _claude,
        config: _config('claude-haiku-4-5', key: 'sk-ant-x'),
        post: fake.call,
      );
      expect(await reader.ping(), '好');
    });
  });

  group('错误汉化', () {
    test('常见状态码都有中文解释', () {
      expect(humanizeHttpError(401, ''), contains('鉴权'));
      expect(humanizeHttpError(402, ''), contains('余额'));
      expect(humanizeHttpError(404, ''), contains('接口不存在'));
      expect(humanizeHttpError(413, ''), contains('太大'));
      expect(humanizeHttpError(429, ''), contains('限流'));
      expect(humanizeHttpError(503, ''), contains('服务异常'));
    });
  });
}