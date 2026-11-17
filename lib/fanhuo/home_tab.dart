/// 把「书源」挂进上游 HomeShell 的第五个 tab，并给上游首屏做一次
/// 可用性探针（挂法 2 + 挂法 3 的最小侵入实现）。
///
/// 设计原则：
///   1. **不改上游任何页面**。只 patch `pages.dart` 的 tab 列表、`home_navigation.dart`
///      的 tabs 常量、`main.dart` 的启动降级。
///   2. 书源页自己包一层 `Atmosphere`，和上游其它 tab 视觉一致。
///   3. 探针失败时不替换上游首页 —— 用户如果就想用上游书架，加个 tab 也不碍事；
///      探针的价值是**把失败暴露成一条可见提示 + 一个直达书源的按钮**，
///      而不是在启动时把整个 App 切走。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_ui.dart';
import 'fanhuo_home.dart';
import 'fanqie_settings.dart';
import 'multi_source_search.dart';
import 'source_repository.dart';

/// 书源 tab 的完整页面（含 masthead，和上游其它 tab 对齐）。
class FanhuoHomeTab extends StatelessWidget {
  const FanhuoHomeTab({
    super.key,
    required this.repository,
    required this.fetch,
    required this.settings,
    required this.onSettingsChanged,
    this.onToggleSource,
  });

  final BookSourceRepository repository;
  final SourceFetcher fetch;
  final FanqieReaderSettings settings;
  final ValueChanged<FanqieReaderSettings> onSettingsChanged;
  final Future<bool> Function(dynamic source, bool enabled)? onToggleSource;

  /// 全局「请打开书源 tab」信号。
  ///
  /// 为什么用 ValueNotifier 而不是 MethodChannel：
  ///   HomeShell 由 MaterialApp 建，HomeHealthBanner 在它外面，
  ///   没有 InheritedWidget 或 GlobalKey 能直连到 `_selectTab`。
  ///   一个顶层的 `ValueNotifier<int>`（监听者只关心「变了」）是最小耦合的做法：
  ///   HomeShell 在 initState 里 addListener，banner 点按钮时 `value++`。
  static final ValueNotifier<int> openRequests = ValueNotifier<int>(0);

  /// banner 的按钮调这个。
  static void requestOpen() {
    openRequests.value = openRequests.value + 1;
  }

  /// 给 HomeShell 的 `_headers` 用。
  static Widget buildHeader(BuildContext context) => const Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
        child: ArchiveMasthead(title: '书源', code: '04 / SOURCE ARCHIVE'),
      );

  @override
  Widget build(BuildContext context) => Atmosphere(
        child: FanhuoHome(
          repository: repository,
          fetch: fetch,
          settings: settings,
          onSettingsChanged: onSettingsChanged,
          onToggleSource: onToggleSource,
        ),
      );
}

/// 上游首屏可用性探针。
///
/// 在 `main.dart` 里 `runApp` 之前调一次，结果是同步的「先乐观假设可用」，
/// 异步探针回来后如果有问题，用 [HomeHealthBanner] 把提示贴到首屏顶部。
///
/// 为什么不直接 await 再决定 home：
///   await 会把首帧推迟 0～3 秒，冷启动变慢；而这个 App 的首帧本来就慢，
///   再叠一层等待体验更差。所以选择「先起页面，失败了再提示」。
class HomeHealth {
  HomeHealth._();

  /// 探针：发一次最轻量的上游请求。true = 通了。
  static Future<bool> probe() async {
    try {
      // 这只走 MethodChannel，不碰 libcpp.so；桥接层没实现时这里会立刻抛，
      // 正是我们要的「不可用」信号。
      // ignore: avoid_dynamic_calls
      final result = await const MethodChannelProbe().call();
      return result;
    } catch (_) {
      return false;
    }
  }
}

/// 把 MethodChannel 的调用抽出来，方便测试替身。
class MethodChannelProbe {
  const MethodChannelProbe();
  Future<bool> call() async {
    // 与 legacy_transport.dart 用同一个 channel，但只发一次最轻的请求。
    // 这里不 import legacy_transport，是为了让 fanhuo 包不反向依赖上游文件。
    final text = await _channel.invokeMethod<String>('request', {
      'action': 'action=xml&item=sort&t=0',
    });
    return text != null && text.trim().isNotEmpty;
  }

  static const _channel = MethodChannel('org.mewx.wenku8/legacy_api');
}

/// 首屏提示条：上游内容源不可用时贴在顶部，一键去书源页。
class HomeHealthBanner extends StatefulWidget {
  const HomeHealthBanner({
    super.key,
    required this.child,
    required this.onOpenSources,
    this.probe = HomeHealth.probe,
  });

  final Widget child;
  final VoidCallback onOpenSources;
  final Future<bool> Function() probe;

  @override
  State<HomeHealthBanner> createState() => _HomeHealthBannerState();
}

class _HomeHealthBannerState extends State<HomeHealthBanner> {
  bool? _healthy; // null = 还在探
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    widget.probe().then((ok) {
      if (mounted) setState(() => _healthy = ok);
    });
  }

  @override
  Widget build(BuildContext context) {
    final showBanner = _healthy == false && !_dismissed;
    if (!showBanner) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '上游内容源连不上（缺私有 libcpp.so）。书源搜书不受影响。',
                      style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onOpenSources,
                    child: const Text('去书源'),
                  ),
                  IconButton(
                    tooltip: '忽略',
                    icon: Icon(Icons.close, size: 18, color: scheme.onErrorContainer),
                    onPressed: () => setState(() => _dismissed = true),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
