import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/volume_cover_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/crop_math.dart';
import '../utils/log_util.dart';
import 'cover_crop_editor.dart';
import 'dialogs.dart';
import 'cover_pick.dart';

/// 卷封面选择与裁剪（BUILD_GUIDE 第 19.2、21.4 节）。
///
/// 候选顺序由 [VolumeCoverService] 定：白名单图 → 卷内第一张图 →
/// 曲目内嵌封面 → 系列封面。这里只做三件事：让人看见候选项、
/// 手动指定与恢复自动、进入裁剪。
class VolumeCoverDialog extends StatefulWidget {
  const VolumeCoverDialog({
    super.key,
    required this.state,
    required this.folderId,
    required this.folderName,
    this.pickImage,
    this.readSize,
  });

  final AppState state;
  final int folderId;
  final String folderName;

  /// 「从文件选择」的实现。默认调系统文件选择框，用例里注入假实现。
  final Future<String?> Function()? pickImage;

  /// 读原图尺寸的实现。默认解码真实文件，用例里注入固定尺寸（解码要真事件
  /// 循环，假时钟下走不完）。
  final Future<Size?> Function(String path)? readSize;

  /// 打开对话框。AppState 在打开时就取好，避免对话框里再依赖 Provider。
  static Future<void> show(
    BuildContext context, {
    required int folderId,
    required String folderName,
    Future<Size?> Function(String path)? readSize,
  }) {
    final state = context.read<AppState>();
    return showDialog<void>(
      context: context,
      builder: (_) => VolumeCoverDialog(
        state: state,
        folderId: folderId,
        folderName: folderName,
        readSize: readSize,
      ),
    );
  }

  @override
  State<VolumeCoverDialog> createState() => _VolumeCoverDialogState();
}

class _VolumeCoverDialogState extends State<VolumeCoverDialog> {
  List<VolumeCoverCandidate> _candidates = const [];

  /// 本文件夹（含子文件夹）里的图片：候选之外想手动指定时直接从这里挑，
  /// 不用走系统文件选择框。
  List<String> _folderImages = const [];
  String? _cover;
  Rect? _crop;
  Size? _imageSize;
  String? _autoCover;
  bool _loading = true;

  /// 真正读图尺寸：注入了用注入的，否则解码真文件。
  Future<Size?> _readSize(String path) =>
      (widget.readSize ?? readImageSize)(path);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final candidates = await widget.state.volumeCoverCandidates(widget.folderId);
    final cover = await widget.state.volumeCover(widget.folderId);
    final crop = await widget.state.volumeCoverCrop(widget.folderId);
    final folderImages = await _loadFolderImages();
    Size? size;
    if (cover != null) size = await _readSize(cover);
    if (!mounted) return;
    setState(() {
      _candidates = candidates;
      // 候选按优先级排好，第一条就是「自动」会选中的那张。
      _autoCover = candidates.isEmpty ? null : candidates.first.path;
      _cover = cover;
      _crop = crop;
      _folderImages = folderImages;
      _imageSize = size;
      _loading = false;
    });
  }

  /// 本文件夹里的图片路径（自然序）。库里查不到时退回空表——候选那条路仍在。
  Future<List<String>> _loadFolderImages() async {
    try {
      final items = await widget.state.imagesInFolder(widget.folderId);
      return items.map((m) => m.path).toList(growable: false);
    } catch (e) {
      logDebug('CoverDialog', '列文件夹图片失败: $e');
      return const [];
    }
  }

  Future<void> _pickCandidate(String path) async {
    await widget.state.setVolumeCover(widget.folderId, path);
    await _load();
  }

  Future<void> _resetToAuto() async {
    await widget.state.setVolumeCover(widget.folderId, null);
    await _load();
  }

  Future<void> _pickFromFile() async {
    final path = widget.pickImage != null
        ? await widget.pickImage!()
        : await _pickWithSystem();
    if (path == null || path.isEmpty) return;
    await widget.state.setVolumeCover(widget.folderId, path);
    await _load();
  }

  Future<void> _openCrop() async {
    final cover = _cover;
    if (cover == null) {
      _toast('请先选一张封面');
      return;
    }
    final size = _imageSize ?? await _readSize(cover);
    if (size == null) {
      logWarn('CoverDialog', '读不到图片尺寸：$cover');
      _toast('这张图读不出尺寸，无法裁剪');
      return;
    }
    if (!mounted) return;
    final result = await CoverCropEditor.show(
      context,
      imagePath: cover,
      imageSize: size,
      initialCrop: _crop,
    );
    if (result == null) return;
    await widget.state
        .setVolumeCoverCrop(widget.folderId, CropMath.isFull(result) ? null : result);
    await _load();
  }

  Future<void> _clearCrop() async {
    await widget.state.setVolumeCoverCrop(widget.folderId, null);
    await _load();
  }

  Future<String?> _pickWithSystem() async {
    return pickImagePath(title: '选择封面图片');
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: Text('卷封面 · ${widget.folderName}',
          style: const TextStyle(fontSize: 16, color: AppColors.textPrimary)),
      content: SizedBox(
        width: 560,
        height: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: 180, child: _preview()),
                  const SizedBox(height: 8),
                  Text(_coverSummary(),
                      key: const ValueKey('cover-summary'),
                      style: TextStyle(
                          fontSize: 11, color: AppColors.mutedLighter)),
                  const SizedBox(height: 8),
                  Text('自动候选（第 19.2 节的四级顺序）',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textTertiary)),
                  const SizedBox(height: 4),
                  Expanded(child: _candidateList()),
                ],
              ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('cover-auto'),
          onPressed: _resetToAuto,
          child: const Text('恢复自动'),
        ),
        TextButton(
          key: const ValueKey('cover-crop'),
          onPressed: _openCrop,
          child: const Text('自定义裁剪范围'),
        ),
        TextButton(
          key: const ValueKey('cover-clear-crop'),
          onPressed: _crop == null ? null : _clearCrop,
          child: const Text('恢复默认裁剪'),
        ),
        TextButton(
          key: const ValueKey('cover-pick'),
          onPressed: _pickFromFile,
          child: const Text('从文件选择'),
        ),
        TextButton(
          key: const ValueKey('cover-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  String _coverSummary() {
    if (_cover == null) return '当前没有可用封面';
    final crop = _crop;
    final cropText = crop == null ? '未裁剪' : '已裁剪 ${CropMath.encode(crop)}';
    final manual = _manualPath;
    final source = manual == null ? '自动' : '手动指定';
    return '$source · $cropText · ${_basename(_cover!)}';
  }

  /// 手动指定与否看「存下来的封面」和「自动会选中的那张」是否同一张。
  ///
  /// 手动挑中的恰好是自动那张时，库里仍会写路径（免得后续扫描改主意），
  /// 但界面上按「自动」显示，跟用户看到的来源一致。
  String? get _manualPath {
    final cover = _cover;
    if (cover == null) return null;
    return cover == _autoCover ? null : cover;
  }

  Widget _preview() {
    final cover = _cover;
    if (cover == null) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.deep,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('这个卷还没有封面',
            style: TextStyle(fontSize: 12, color: AppColors.mutedLight)),
      );
    }
    final crop = _crop ?? CropMath.full;
    final size = _imageSize;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.deep,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(6),
      child: size == null
          ? Center(
              child: Text('图片尺寸未知：${_basename(cover)}',
                  style: TextStyle(fontSize: 12, color: AppColors.mutedLight)))
          : CroppedCoverImage(path: cover, crop: crop, imageSize: size),
    );
  }

  Widget _candidateList() {
    final rows = <Widget>[];
    final manual = _manualPath;
    if (manual != null) {
      rows.add(_candidateTile(
        index: -1,
        label: '手动指定',
        sublabel: _basename(manual),
        path: manual,
      ));
    }
    for (var i = 0; i < _candidates.length; i++) {
      final c = _candidates[i];
      rows.add(_candidateTile(
        index: i,
        label: c.source.label,
        sublabel: _basename(c.path),
        path: c.path,
      ));
    }
    if (rows.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '没有找到候选图片，可以从下面的文件夹图片或「从文件选择」指定',
            style: TextStyle(fontSize: 12, color: AppColors.mutedLight),
          ),
        ),
      );
    }
    rows.addAll(_folderImageRows(manual));
    return ListView(children: rows);
  }

  /// 「本文件夹的图片」一节：候选之外的全部图片，点一下就设为封面。
  ///
  /// 手机上没有系统文件浏览器的便利（要一层层点进去找 DCIM），这里直接把
  /// 这个文件夹里的图铺出来，省掉原生选图那一步。
  List<Widget> _folderImageRows(String? manual) {
    final listed = <String>{?manual, for (final c in _candidates) c.path};
    final extra = _folderImages
        .where((p) => !listed.contains(p))
        .toList(growable: false);
    if (extra.isEmpty) return const [];
    return [
      const Divider(height: 18),
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          '本文件夹的图片（${extra.length} 张，点一下设为封面）',
          key: const ValueKey('cover-folder-images-header'),
          style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
        ),
      ),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < extra.length; i++)
            InkWell(
              key: ValueKey('cover-folder-image-$i'),
              onTap: () => _pickCandidate(extra[i]),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _cover == extra[i]
                        ? AppColors.accent
                        : Colors.white.withValues(alpha: 0.08),
                    width: _cover == extra[i] ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: CoverImageThumb(path: extra[i], size: 56),
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
    ];
  }

  Widget _candidateTile({
    required int index,
    required String label,
    required String sublabel,
    required String path,
  }) {
    final selected = _cover == path;
    return ListTile(
      key: ValueKey('cover-candidate-$index'),
      dense: true,
      selected: selected,
      selectedTileColor: AppColors.accent.withValues(alpha: 0.12),
      leading: Icon(
        selected ? Icons.check_circle : Icons.image_outlined,
        size: 18,
        color: selected ? AppColors.accent : AppColors.mutedLight,
      ),
      title: Text(label,
          style: TextStyle(fontSize: 12, color: AppColors.textPrimary)),
      subtitle: Text(sublabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: AppColors.mutedLighter)),
      onTap: () => _pickCandidate(path),
    );
  }
}

/// 按归一化裁剪框显示图片的一角，铺满给定区域。
///
/// 卷面板也用这一个组件画封面，保证列表与预览的取景一致。
class CroppedCoverImage extends StatelessWidget {
  const CroppedCoverImage({
    super.key,
    required this.path,
    required this.crop,
    required this.imageSize,
  });

  final String path;
  final Rect crop;
  final Size imageSize;

  @override
  Widget build(BuildContext context) {
    final c = CropMath.clampUnit(crop);
    final aspect =
        (c.width * imageSize.width) / (c.height * imageSize.height);
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fullW = constraints.maxWidth / c.width;
              final fullH = constraints.maxHeight / c.height;
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned(
                    left: -c.left * fullW,
                    top: -c.top * fullH,
                    width: fullW,
                    height: fullH,
                    child: Image.file(File(path),
                        fit: BoxFit.fill,
                        errorBuilder: (_, _, _) => Container(
                              color: AppColors.deep,
                              alignment: Alignment.center,
                              child: const Text('图片读不出来',
                                  style: TextStyle(
                                      fontSize: 12, color: AppColors.danger)),
                            )),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}
