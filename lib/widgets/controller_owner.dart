import 'package:flutter/widgets.dart';

/// 对话框里临时建的 [TextEditingController] 交给它管。
///
/// 写成 `showDialog(...).whenComplete(controller.dispose)` 会早一步：
/// `Navigator.pop` 的瞬间对话框还在跑退场动画，`TextField` 仍挂在树上，
/// 退场重建会撞上「A TextEditingController was used after being disposed」。
/// 挂在对话框内容的上一层，它就跟路由的子树一起销毁，时机正好。
class ControllerOwner extends StatefulWidget {
  const ControllerOwner({
    super.key,
    required this.controllers,
    required this.child,
  });

  final List<TextEditingController> controllers;
  final Widget child;

  @override
  State<ControllerOwner> createState() => _ControllerOwnerState();
}

class _ControllerOwnerState extends State<ControllerOwner> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
