import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/folder_dao.dart';
import '../db/media_dao.dart';
import '../state/app_state.dart';
import '../services/reading_progress_service.dart';
import '../theme/app_theme.dart';
import '../utils/crop_math.dart';
import 'cover_crop_editor.dart';
import 'volume_cover_dialog.dart';

/// 卷面板（BUILD_GUIDE 第 19.2、19.4、22.6、22.7 节）。
///
/// 卷是阅读与封面的归属单位，所以这里集中放四件事：
/// 封面（含换封面与裁剪入口）、卷内图片区、阅读入口、已读完标记。
class VolumePanel extends StatefulWidget {
  const VolumePanel({
    super.key,
    required this.state,
    required this.folder,
    this.readSize,
  });

  final AppState state;
  final VirtualFolder folder;

  /// 读原图尺寸的实现。默认解码真实文件；用例注入固定尺寸，因为解码要真
  /// 事件循环，假时钟下走不完。
  final Future<Size?> Function(String path)? readSize;

  static Future<void> show(BuildContext context,
      {required VirtualFolder folder,
      Future<Size?> Function(String path)? readSize}) {
    final state = context.read<AppState>();
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panelOf(context),
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: VolumePanel(state: state, folder: folder, readSize: readSize),
      ),
    );
  }

  @override
  State<VolumePanel> createState() => _VolumePanelState();
}

class _VolumePanelState extends State<VolumePanel> {
  List<MediaItem> _images = const [];
  String? _cover;
  Rect? _crop;
  Size? _coverSize;
  ReadingProgress? _progress;
  bool _loading = true;

  int get _folderId => widget.folder.id ?? -1;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    _load();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final images = await widget.state.imagesInFolder(_folderId);
    final cover = await widget.state.volumeCover(_folderId);
    final crop = await widget.state.volumeCoverCrop(_folderId);
    final progress = await widget.state.readingProgressOf(_folderId);
    Size? size;
    if (cover != null) size = await (widget.readSize ?? readImageSize)(cover);
    if (!mounted) return;
    setState(() {
      _images = images;
      _cover = cover;
      _crop = crop;
      _coverSize = size;
      _progress = progress;
      _loading = false;
    });
  }

  Future<void> _changeCover() async {
    await VolumeCoverDialog.show(
      context,
      folderId: _folderId,
      folderName: widget.folder.name,
    );
    await _load();
  }

  Future<void> _startReading() async {
    final ok = await widget.state.openVolumeReader(_folderId);
    if (!ok) {
      _toast('这个卷里没有可阅读的图片');
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _markFinished() async {
    await widget.state.markReadFinished();
    await widget.state.flushReadingProgress();
    await _load();
    _toast('已标记读完');
  }

  void _openImage(int index) {
    widget.state.openViewer(_images, index);
    Navigator.of(context).maybePop();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('volume-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 220, child: _coverColumn()),
                const VerticalDivider(width: 1, color: AppColors.surface),
                Expanded(child: _imageArea()),
              ],
            ),
          ),
      ],
    );
  }

  Widget _header() {
    final finished = _progress?.finished ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      child: Row(
        children: [
          const Icon(Icons.auto_stories_outlined,
              size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Flexible(
            child: Text(widget.folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
          const SizedBox(width: 8),
          if (finished)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('已读完',
                  style: TextStyle(fontSize: 10, color: AppColors.success)),
            ),
          const Spacer(),
          TextButton(
            key: const ValueKey('volume-cover-change'),
            onPressed: _changeCover,
            child: const Text('换封面'),
          ),
          TextButton(
            key: const ValueKey('volume-read'),
            onPressed: _startReading,
            child: const Text('阅读'),
          ),
          TextButton(
            key: const ValueKey('volume-mark-finished'),
            onPressed: finished ? null : _markFinished,
            child: const Text('标记已读完'),
          ),
          IconButton(
            key: const ValueKey('volume-close'),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _coverColumn() {
    final cover = _cover;
    final size = _coverSize;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('卷封面',
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.deep,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(4),
              child: cover == null
                  ? Center(
                      child: Text('还没有封面',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.mutedLight)))
                  : size == null
                      ? Center(
                          child: Text('封面尺寸未知',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.mutedLight)))
                      : CroppedCoverImage(
                          path: cover,
                          crop: _crop ?? CropMath.full,
                          imageSize: size,
                        ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _progress == null
                ? '没有阅读记录'
                : '看到第 ${_progress!.pageIndex + 1} 页',
            key: const ValueKey('volume-read-progress'),
            style: TextStyle(fontSize: 11, color: AppColors.mutedLighter),
          ),
        ],
      ),
    );
  }

  Widget _imageArea() {
    if (_images.isEmpty) {
      return Center(
        child: Text('这个卷里没有图片',
            style: TextStyle(fontSize: 12, color: AppColors.mutedLight)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('卷内图片 ${_images.length} 张',
              key: const ValueKey('volume-image-count'),
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
          const SizedBox(height: 6),
          Expanded(
            child: GridView.builder(
              key: const ValueKey('volume-image-grid'),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 132,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: _images.length,
              itemBuilder: (context, index) {
                final item = _images[index];
                return InkWell(
                  key: ValueKey('volume-image-${item.id}'),
                  onTap: () => _openImage(index),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.deep,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Expanded(
                          child: item.path.isEmpty
                              ? const SizedBox.shrink()
                              : Image.file(File(item.path),
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  errorBuilder: (_, _, _) => const Center(
                                        child: Icon(Icons.broken_image_outlined,
                                            size: 16,
                                            color: AppColors.mutedLight),
                                      )),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Text(item.filename,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.mutedLighter)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
