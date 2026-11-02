import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/crop_math.dart';

/// 封面裁剪编辑器（BUILD_GUIDE 第 21.3、21.4 节）。
///
/// 归一化坐标 `(0,0)..(1,1)` 是唯一口径，所有拖动换算都走 [CropMath]，
/// 这里只负责画出来和接手势：
///
/// - 框内拖动 = 平移整框，框贴边即停；
/// - 八个手柄 = 改变尺寸，最小边 24 屏幕像素；
/// - 越界一律贴边，不缩放，所以拖不出原图。
///
/// 返回值约定（[show]）：
/// - `null` 表示用户取消；
/// - 非空 `Rect` 表示选定的裁剪框，整幅图就是 [CropMath.full]，
///   调用方交给 [CropMath.encode] 时会自然写成「不裁」。
class CoverCropEditor extends StatefulWidget {
  const CoverCropEditor({
    super.key,
    required this.imagePath,
    required this.imageSize,
    this.initialCrop,
    this.title = '裁剪封面',
  });

  /// 原图路径。只为显示用，不写回。
  final String imagePath;

  /// 原图像素尺寸。调用方通常已经知道（缩略图链路里有），
  /// 传进来就不必在编辑器里再解码一次。
  final Size imageSize;

  /// 打开时的裁剪框，null 表示整幅。
  final Rect? initialCrop;

  final String title;

  /// 以对话框形式打开。取消返回 null。
  static Future<Rect?> show(
    BuildContext context, {
    required String imagePath,
    required Size imageSize,
    Rect? initialCrop,
    String title = '裁剪封面',
  }) {
    return showDialog<Rect>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: AppColors.panel,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: CoverCropEditor(
            imagePath: imagePath,
            imageSize: imageSize,
            initialCrop: initialCrop,
            title: title,
          ),
        ),
      ),
    );
  }

  @override
  State<CoverCropEditor> createState() => _CoverCropEditorState();
}

class _CoverCropEditorState extends State<CoverCropEditor> {
  late Rect _crop;
  CropHandle? _dragging;

  /// 手柄命中半径，比手柄本身大一圈，手指才好按。
  static const double _hitRadius = 26;

  @override
  void initState() {
    super.initState();
    _crop = CropMath.clampUnit(widget.initialCrop ?? CropMath.full);
  }

  /// 图片在面板里的显示矩形。四周留 12 像素，免得贴边的角手柄被裁掉一半
  /// 连点都点不到。
  Rect _displayed(Size viewSize) {
    const inset = 12.0;
    final box = Size(
      (viewSize.width - inset * 2).clamp(1.0, double.infinity),
      (viewSize.height - inset * 2).clamp(1.0, double.infinity),
    );
    return CropMath.fitRect(widget.imageSize, box).shift(const Offset(inset, inset));
  }

  /// 裁剪框在屏幕上的矩形。
  Rect _cropOnScreen(Rect displayed) => Rect.fromLTRB(
        displayed.left + _crop.left * displayed.width,
        displayed.top + _crop.top * displayed.height,
        displayed.left + _crop.right * displayed.width,
        displayed.top + _crop.bottom * displayed.height,
      );

  /// 手柄在图上的锚点（屏幕坐标）。
  Offset _handleAnchor(Rect box, CropHandle handle) {
    final cx = box.center.dx;
    final cy = box.center.dy;
    switch (handle) {
      case CropHandle.topLeft:
        return box.topLeft;
      case CropHandle.top:
        return Offset(cx, box.top);
      case CropHandle.topRight:
        return box.topRight;
      case CropHandle.right:
        return Offset(box.right, cy);
      case CropHandle.bottomRight:
        return box.bottomRight;
      case CropHandle.bottom:
        return Offset(cx, box.bottom);
      case CropHandle.bottomLeft:
        return box.bottomLeft;
      case CropHandle.left:
        return Offset(box.left, cy);
      case CropHandle.move:
        return box.center;
    }
  }

  /// 按下位置决定抓哪个手柄：先看手柄，再看框内平移，都不中就不要这一手。
  CropHandle? _hitHandle(Offset local, Rect box) {
    for (final handle in CropHandle.values) {
      if (handle == CropHandle.move) continue;
      if ((_handleAnchor(box, handle) - local).distance <= _hitRadius) {
        return handle;
      }
    }
    if (box.contains(local)) return CropHandle.move;
    return null;
  }

  void _onPanStart(Offset local, Rect displayed) {
    final handle = _hitHandle(local, _cropOnScreen(displayed));
    setState(() => _dragging = handle);
  }

  void _onPanUpdate(Offset delta, Rect displayed, Size viewSize) {
    final handle = _dragging;
    if (handle == null) return;
    setState(() {
      _crop = CropMath.applyDrag(
        imageSize: widget.imageSize,
        viewSize: viewSize,
        crop: _crop,
        handle: handle,
        delta: delta,
        displayedRect: displayed,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(),
        Flexible(child: _surface()),
        _numbers(),
        _actions(context),
      ],
    );
  }

  Widget _title() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          const Icon(Icons.crop, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Text(widget.title,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          const Spacer(),
          Text('拖动框内移动，拖手柄改大小',
              style: TextStyle(fontSize: 11, color: AppColors.mutedLight)),
        ],
      ),
    );
  }

  Widget _surface() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        final displayed = _displayed(viewSize);
        final box = _cropOnScreen(displayed);
        return GestureDetector(
          key: const ValueKey('crop-surface'),
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _onPanStart(d.localPosition, displayed),
          onPanUpdate: (d) =>
              _onPanUpdate(d.delta, displayed, viewSize),
          onPanEnd: (_) => setState(() => _dragging = null),
          child: Stack(
            children: [
              Positioned.fromRect(
                rect: displayed,
                child: Image.file(File(widget.imagePath),
                    fit: BoxFit.fill,
                    errorBuilder: (_, _, _) => Container(
                          color: AppColors.deep,
                          alignment: Alignment.center,
                          child: const Text('图片读不出来',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.danger)),
                        )),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _ScrimPainter(box)),
                ),
              ),
              for (final handle in CropHandle.values)
                if (handle != CropHandle.move)
                  Positioned(
                    left: _handleAnchor(box, handle).dx - 9,
                    top: _handleAnchor(box, handle).dy - 9,
                    child: Container(
                      key: ValueKey('crop-handle-${handle.name}'),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        border: Border.all(color: AppColors.deep, width: 2),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }

  Widget _numbers() {
    final text = CropMath.encode(_crop) ?? '整幅（不裁）';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Text('左,上,右,下 = $text',
          key: const ValueKey('crop-numbers'),
          style: TextStyle(fontSize: 11, color: AppColors.mutedLighter)),
    );
  }

  Widget _actions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        children: [
          TextButton(
            key: const ValueKey('crop-reset'),
            onPressed: () => setState(() => _crop = CropMath.full),
            child: const Text('恢复默认'),
          ),
          const Spacer(),
          TextButton(
            key: const ValueKey('crop-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const ValueKey('crop-confirm'),
            onPressed: () => Navigator.of(context).pop(_crop),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// 框外压暗，框内透出原图。
class _ScrimPainter extends CustomPainter {
  _ScrimPainter(this.box);

  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(box),
    );
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = AppColors.accent,
    );
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => old.box != box;
}

/// 从图片文件读原图像素尺寸。
///
/// 只解一帧拿宽高，不保留 [ui.Image]，避免编辑器长时间占着整张位图。
Future<Size?> readImageSize(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    codec.dispose();
    return size;
  } catch (_) {
    return null;
  }
}
