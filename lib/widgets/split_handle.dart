import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 可拖拽的分隔条。
///
/// [axis] 是分隔条自身的走向：
/// - [Axis.horizontal]：竖直细条，拖动改变左右两块的宽度
/// - [Axis.vertical]：水平细条，拖动改变上下两块的高度
///
/// 命中区 8 像素，视觉线 1 像素，两者分开：鼠标不必精确点到那条线上。
class SplitHandle extends StatefulWidget {
  const SplitHandle({
    super.key,
    required this.axis,
    required this.onDragDelta,
    this.onDragEnd,
    this.onReset,
    this.tooltip = '拖动调整大小，双击恢复默认',
  });

  final Axis axis;

  /// 拖动回调，单位是像素增量。正值表示向右或向下。
  final ValueChanged<double> onDragDelta;

  /// 松手回调。持久化放在这里，不在拖动过程中的每一帧。
  final VoidCallback? onDragEnd;

  /// 双击恢复默认尺寸。为空时双击无效果。
  final VoidCallback? onReset;

  final String tooltip;

  @override
  State<SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<SplitHandle> {
  bool _hovered = false;
  bool _dragging = false;

  static const double _hitSize = 8;

  bool get _verticalBar => widget.axis == Axis.horizontal;

  @override
  Widget build(BuildContext context) {
    final lineColor = _hovered || _dragging
        ? AppColors.accent
        : Theme.of(context).dividerColor;

    return Semantics(
      slider: true,
      label: widget.tooltip,
      child: MouseRegion(
        cursor: _verticalBar
            ? SystemMouseCursors.resizeLeftRight
            : SystemMouseCursors.resizeUpDown,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: widget.onReset,
          onHorizontalDragStart: _verticalBar ? _dragStart : null,
          onHorizontalDragUpdate: _verticalBar ? _dragUpdate : null,
          onHorizontalDragEnd: _verticalBar ? _dragEnd : null,
          onVerticalDragStart: _verticalBar ? null : _dragStart,
          onVerticalDragUpdate: _verticalBar ? null : _dragUpdate,
          onVerticalDragEnd: _verticalBar ? null : _dragEnd,
          child: Tooltip(
            message: widget.tooltip,
            waitDuration: const Duration(milliseconds: 600),
            child: SizedBox(
              width: _verticalBar ? _hitSize : double.infinity,
              height: _verticalBar ? double.infinity : _hitSize,
              child: Center(
                child: Container(
                  width: _verticalBar ? 1 : double.infinity,
                  height: _verticalBar ? double.infinity : 1,
                  color: lineColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _dragStart(DragStartDetails details) {
    setState(() => _dragging = true);
  }

  void _dragUpdate(DragUpdateDetails details) {
    widget.onDragDelta(_verticalBar ? details.delta.dx : details.delta.dy);
  }

  void _dragEnd(DragEndDetails details) {
    setState(() => _dragging = false);
    widget.onDragEnd?.call();
  }
}
