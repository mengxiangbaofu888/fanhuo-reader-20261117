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
/// `java.timeFormat`、`base64Decode`、`md5`，以及**异步的 `java.ajax`**。
///
/// `java.ajax` 单独一行执行是故意的：`evaluateAsync` 只有脚本最外层表达式
/// 是 Promise 时才会等它，所以把网络那一项放最后、单独一句。
const _probeScript = r'''
var id = result.match(/\/(\d+)\/?$/)[1];
var cover = 'https://img.example.com/' + parseInt(id / 1000) + '/' + id + 's.jpg';
var stamp = java.timeFormat('1794963907');
var decoded = base64Decode('5Lit5paH');
var digest = md5('abc');
var fixed = [cover, stamp, decoded, digest].join('|');
fixed;
''';

/// 异步那一项：自检用假 fetch，返回固定串。
const _probeAsyncScript = r'''
java.ajax(baseUrl + '/probe').then(function (t) { return t; });
''';

/// 假 fetch 的固定返回，用于验证异步桥。
const _probeFetchBody = 'AJAX_OK';

/// 期望结果。脚本或宿主 API 任何一环坏了都会对不上。
final _expected =
    'https://img.example.com/12/12345s.jpg'
    '|2026/11/18 09:05'
    '|中文'
    '|900150983cd24fb0d6963f7d28e17f72';

/// 跑一次自检。
  ///
  /// 两段：
  ///   1. 同步部分（正则/字符串/时间/base64/md5）—— 拼成一个串整体比对
  ///   2. 异步部分（`java.ajax` 返回 Promise）—— 单独比对，验证 Promise 桥
  Future<EngineProbeResult> runEngineProbe({
    SourceFetcher? fetch,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final started = DateTime.now();
    final fakeFetch =
        fetch ?? (request, {String? header}) async => _probeFetchBody;
    JsRuntimeContext context() => JsRuntimeContext(
          fetch: fakeFetch,
          allowList: HostAllowList(['example.com']),
          result: 'https://example.com/book/12345/',
        );
    const globals = {
      'result': 'https://example.com/book/12345/',
      'baseUrl': 'https://example.com',
      'key': '',
    };
    try {
      final actual = await jsEnginePool
          .run(_probeScript, context: context(), globals: globals)
          .timeout(timeout);
      final trimmed = actual.trim();
      if (trimmed != _expected) {
        return EngineProbeResult(
          EngineProbeStatus.assertionFailed,
          '同步部分不对\n期望 $_expected\n实际 $trimmed',
          elapsed: DateTime.now().difference(started),
        );
      }

      // 异步桥：脚本最外层是一个 Promise，evaluateAsync 应当等它
      final asyncActual = await jsEnginePool
          .run(_probeAsyncScript, context: context(), globals: globals)
          .timeout(timeout);
      final asyncTrimmed = asyncActual.trim();
      final elapsed = DateTime.now().difference(started);
      if (asyncTrimmed != _probeFetchBody) {
        return EngineProbeResult(
          EngineProbeStatus.assertionFailed,
          '异步桥不对（java.ajax 应当返回 $_probeFetchBody，实际 $asyncTrimmed）',
          elapsed: elapsed,
        );
      }
      return EngineProbeResult(
        EngineProbeStatus.ok,
        '同步 4 项 + 异步 1 项全过（$elapsed）',
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
