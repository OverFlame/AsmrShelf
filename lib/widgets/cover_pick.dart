import 'dart:io';

import 'package:flutter/material.dart';

import '../services/thumbnail_cache.dart';
import '../theme/app_theme.dart';
import '../utils/log_util.dart';
import 'dialogs.dart';

/// 一张候选图的缩略图（供封面选择用）。
///
/// 走 300px 缩略图缓存：这里列的是整个作品/文件夹的图，直接解码原图在手机
/// 上会卡住；缩略图不在就先让 [ThumbnailService] 生成一张。
class CoverImageThumb extends StatefulWidget {
  const CoverImageThumb({super.key, required this.path, this.size = 64});

  final String path;
  final double size;

  @override
  State<CoverImageThumb> createState() => _CoverImageThumbState();
}

class _CoverImageThumbState extends State<CoverImageThumb> {
  File? _file;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverImageThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _file = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final file = File(ThumbnailService.instance.thumbPath(widget.path));
      if (!await file.exists()) {
        await ThumbnailService.instance.ensureThumbnail(widget.path);
      }
      if (!mounted) return;
      setState(() => _file = file);
    } catch (e) {
      logDebug('CoverPick', '缩略图生成失败 "${widget.path}": $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file == null || _failed) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: Icon(
          Icons.image_outlined,
          size: widget.size / 2,
          color: AppColors.mutedLight,
        ),
      );
    }
    return Image.file(
      file,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: Icon(
          Icons.broken_image_outlined,
          size: widget.size / 2,
          color: AppColors.mutedLight,
        ),
      ),
    );
  }
}

/// 从一批图片里挑一张（缩略图墙）。返回选中的路径，取消返回 null。
///
/// 手机上没有「浏览文件夹选图」的便利，原生选图框又要一层层点进去；所以凡是
/// 需要指定封面的地方都先给这里的图墙，[allowFilePick] 只在必要时留一个
/// 「从文件选择…」的出口。
Future<String?> showCoverImagePicker(
  BuildContext context, {
  required String title,
  required List<String> paths,
  String? current,
  bool allowFilePick = true,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _CoverImagePickerDialog(
      title: title,
      paths: paths,
      current: current,
      allowFilePick: allowFilePick,
    ),
  );
}

class _CoverImagePickerDialog extends StatefulWidget {
  const _CoverImagePickerDialog({
    required this.title,
    required this.paths,
    this.current,
    this.allowFilePick = true,
  });

  final String title;
  final List<String> paths;
  final String? current;
  final bool allowFilePick;

  @override
  State<_CoverImagePickerDialog> createState() =>
      _CoverImagePickerDialogState();
}

class _CoverImagePickerDialogState extends State<_CoverImagePickerDialog> {
  late final List<String> _paths = List<String>.of(widget.paths);
  bool _picking = false;

  Future<void> _pickFromSystem() async {
    if (_picking) return;
    _picking = true;
    try {
      final picked = await pickImagePath();
      if (picked == null || picked.isEmpty) return;
      if (!mounted) return;
      Navigator.of(context).pop(picked);
    } finally {
      _picking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: Text(
        widget.title,
        style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 520,
        height: 380,
        child: _paths.isEmpty
            ? Center(
                child: Text(
                  '这个范围里还没有图片，用「从文件选择」挑一张',
                  key: const ValueKey('cover-pick-empty'),
                  style: TextStyle(fontSize: 12, color: AppColors.mutedLight),
                ),
              )
            : GridView.builder(
                key: const ValueKey('cover-pick-grid'),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 96,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  childAspectRatio: 1,
                ),
                itemCount: _paths.length,
                itemBuilder: (ctx, i) {
                  final path = _paths[i];
                  final selected = path == widget.current;
                  return InkWell(
                    key: ValueKey('cover-pick-$i'),
                    onTap: () => Navigator.of(context).pop(path),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: selected
                              ? AppColors.accent
                              : Colors.white.withValues(alpha: 0.08),
                          width: selected ? 2 : 1,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: CoverImageThumb(path: path, size: 92),
                    ),
                  );
                },
              ),
      ),
      actions: [
        if (widget.allowFilePick)
          TextButton(
            key: const ValueKey('cover-pick-file'),
            onPressed: _pickFromSystem,
            child: const Text('从文件选择...'),
          ),
        TextButton(
          key: const ValueKey('cover-pick-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
