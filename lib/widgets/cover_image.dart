import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 封面图组件：本地文件优先，否则占位。
///
/// build 里不做 `existsSync`。同步 stat 会在滚动时卡主 isolate；
/// 这里直接交给 [Image.file] 的 errorBuilder 兜底，文件不在时换成占位图。
class CoverImage extends StatefulWidget {
  final String? path;
  final double width;
  final double height;
  final double borderRadius;
  final BoxFit fit;

  const CoverImage({
    super.key,
    required this.path,
    required this.width,
    required this.height,
    this.borderRadius = 8,
    this.fit = BoxFit.cover,
  });

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  /// 加载失败过的路径，避免同一路径反复触发文件读取。
  String? _failedPath;

  @override
  void didUpdateWidget(covariant CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _failedPath = null;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.path;
    final showImage = p != null && p != _failedPath;
    final child = showImage
        ? Image.file(
            File(p),
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            errorBuilder: (_, _, _) {
              // errorBuilder 在绘制阶段被调用，不能同步 setState；
              // 下一帧把这一路径标记为失败，build 直接走占位图。
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _failedPath != p) {
                  setState(() => _failedPath = p);
                }
              });
              return _placeholder(context);
            },
          )
        : _placeholder(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(
          width: widget.width, height: widget.height, child: child),
    );
  }

  Widget _placeholder(BuildContext context) {
    // 调用方可能传 double.infinity（作品卡片就是这么用的），图标尺寸要收成有限值
    final iconSize = widget.width.isFinite ? widget.width * 0.4 : 32.0;
    return Container(
      width: widget.width,
      height: widget.height,
      color: AppColors.surfaceOf(context),
      child: Icon(
        Icons.music_note,
        size: iconSize,
        color: AppColors.mutedOf(context),
      ),
    );
  }
}
