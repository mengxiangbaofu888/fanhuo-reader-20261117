/// 可拖拽的上下分栏：上面是书脊轮播，下面是列表。
///
/// 为什么需要：轮播高 268 且带 3D 效果，占掉大半屏幕，用户想看书单还得滑。
/// 截图里反馈「UI 显示不全，看底下的书不方便」。
///
/// 交互：
/// - 分隔条上有小横条（抓手），按住上下拖，比例 20%~75%
/// - 点一下横条：直接收到「只看列表」（20%），再点展开回去
/// - 松手时吸附到最近的一档（28% / 50% / 72%），动画 220ms
library;

import 'package:flutter/material.dart';

import 'fanqie_theme.dart';

class CollapsibleShelfLayout extends StatefulWidget {
  const CollapsibleShelfLayout({
    super.key,
    required this.header,
    required this.hero,
    required this.list,
    this.initialRatio = 0.42,
  });

  /// 顶部固定内容（标题、榜单 tabs 之类）。
  final Widget header;

  /// 轮播区，高度随拖拽变化。
  final Widget hero;

  /// 下方列表。
  final Widget list;

  /// 初始占比（轮播高 / 可用高）。
  final double initialRatio;

  @override
  State<CollapsibleShelfLayout> createState() => _CollapsibleShelfLayoutState();
}

class _CollapsibleShelfLayoutState extends State<CollapsibleShelfLayout> {
  static const _min = 0.18;
  static const _max = 0.75;
  static const _snaps = <double>[0.18, 0.42, 0.68];

  late double _ratio = widget.initialRatio.clamp(_min, _max);
  double _dragStart = 0;

  /// 拖拽中不吸顶，松手才吸。
  bool _dragging = false;

  double _snapTo(double value) {
    var best = _snaps.first;
    for (final s in _snaps) {
      if ((s - value).abs() < (best - value).abs()) best = s;
    }
    return best;
  }

  void _toggle() {
    // 已经矮了就展开，否则收到最矮
    setState(() {
      _ratio = _ratio <= _min + 0.02 ? 0.42 : _min;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 扣掉顶部 header 和分隔条本身
        const handleHeight = 34.0;
        final bodyHeight =
            (constraints.maxHeight - handleHeight).clamp(0.0, double.infinity);
        final heroHeight = bodyHeight * _ratio;

        return Column(
          children: [
            widget.header,
            SizedBox(
              height: heroHeight,
              child: ClipRect(child: widget.hero),
            ),
            _handle(context),
            Expanded(child: widget.list),
          ],
        );
      },
    );
  }

  Widget _handle(BuildContext context) {
    const paper = FanqiePaper.yellow;
    final collapsed = _ratio <= _min + 0.02;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) {
        _dragging = true;
        _dragStart = _ratio;
      },
      onVerticalDragUpdate: (details) {
        final h = MediaQuery.sizeOf(context).height;
        setState(() {
          _ratio = (_ratio + details.delta.dy / (h * 0.7)).clamp(_min, _max);
        });
      },
      onVerticalDragEnd: (_) {
        _dragging = false;
        setState(() => _ratio = _snapTo(_ratio));
      },
      onTap: _toggle,
      child: SizedBox(
        height: 34,
        child: Center(
          child: AnimatedContainer(
            duration: Duration(milliseconds: _dragging ? 0 : 180),
            curve: Curves.easeOut,
            width: collapsed ? 56 : 44,
            height: 5,
            decoration: BoxDecoration(
              color: paper.raised(collapsed ? 0.32 : 0.2),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }
}
