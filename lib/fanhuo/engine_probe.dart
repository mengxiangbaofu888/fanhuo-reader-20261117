/// 引擎自检：证明 QuickJS 在这台机器上真的能跑书源脚本。
///
/// 为什么需要这个：单元测试跑在桌面 Dart VM 上，**没有 QuickJS 原生库**，
/// 所以测试只能验证「回落逻辑对不对」，验证不了「引擎真能跑」。
/// 而 `flutter_js` 的作者在自己的 CMake 里写过
/// `crashing with SEGV_MAPERR on ARM based devices`，ARM 设备上是有前科的。
///
/// 这段代码让用户在管理页按一下就能看到结论，不用连电脑看日志。
library;

import 'js_engine.dart';
import 'js_host_api.dart';
import 'multi_source_search.dart';

/// 一次自检的结论。
enum EngineProbeStatus { ok, engineUnavailable, scriptFailed, assertionFailed }

class EngineProbeResult {
  const EngineProbeResult(this.status, this.detail, {this.elapsed});
  final EngineProbeStatus status;
  final String detail;
  final Duration? elapsed;

  bool get ok => status == EngineProbeStatus.ok;

  String get label => switch (status) {
    EngineProbeStatus.ok => '引擎可用',
    EngineProbeStatus.engineUnavailable => '引擎不可用',
    EngineProbeStatus.scriptFailed => '脚本执行失败',
    EngineProbeStatus.assertionFailed => '结果不对',
  };
}

/// 自检用的脚本：把书源最容易踩的几个点都过一遍。
///
/// 不联网（用一个假 fetch 注入固定页面），所以断网也能跑。
/// 覆盖：正则 + 捕获组、字符串拼接、`result` 全局变量、
/// `java.timeFormat`、`base64Decode`、`md5`。
const _probeScript = r'''
// 1) result 全局变量 + 正则捕获组
var id = result.match(/\/(\d+)\/?$/)[1];
// 2) 字符串拼接与算术
var cover = 'https://img.example.com/' + parseInt(id / 1000) + '/' + id + 's.jpg';
// 3) 宿主 API：时间格式化
var stamp = java.timeFormat('1794963907');
// 4) 宿主 API：base64 与 md5
var decoded = base64Decode('5Lit5paH');
var digest = md5('abc');
// 5) 返回值拼在一起，让 Dart 侧逐项比对
cover + '|' + stamp + '|' + decoded + '|' + digest;
''';

/// 期望结果。脚本或宿主 API 任何一环坏了都会对不上。
final _expected =
    'https://img.example.com/12/12345s.jpg'
    '|2026/11/18 09:05'
    '|中文'
    '|900150983cd24fb0d6963f7d28e17f72';

/// 跑一次自检。
Future<EngineProbeResult> runEngineProbe({
  SourceFetcher? fetch,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final started = DateTime.now();
  final fakeFetch = fetch ??
      (request, {String? header}) async => '<div id="content">自检</div>';
  try {
    final actual = await jsEnginePool
        .run(
          _probeScript,
          context: JsRuntimeContext(
            fetch: fakeFetch,
            allowList: HostAllowList(['example.com']),
            result: 'https://example.com/book/12345/',
          ),
          globals: {
            'result': 'https://example.com/book/12345/',
            'baseUrl': 'https://example.com',
            'key': '',
          },
        )
        .timeout(timeout);
    final elapsed = DateTime.now().difference(started);
    final trimmed = actual.trim();
    if (trimmed == _expected) {
      return EngineProbeResult(
        EngineProbeStatus.ok,
        '全部通过（$elapsed）',
        elapsed: elapsed,
      );
    }
    return EngineProbeResult(
      EngineProbeStatus.assertionFailed,
      '期望 $_expected\n实际 $trimmed',
      elapsed: elapsed,
    );
  } on JsEngineFailure catch (error) {
    // 「不可用」和「跑挂了」要分开报：前者是平台/依赖问题，后者是脚本问题
    final unavailable = error.message.contains('不可用');
    return EngineProbeResult(
      unavailable
          ? EngineProbeStatus.engineUnavailable
          : EngineProbeStatus.scriptFailed,
      error.message,
      elapsed: DateTime.now().difference(started),
    );
  } catch (error) {
    return EngineProbeResult(
      EngineProbeStatus.scriptFailed,
      '$error',
      elapsed: DateTime.now().difference(started),
    );
  }
}
