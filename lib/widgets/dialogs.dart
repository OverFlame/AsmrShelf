import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/cover_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/image_cache_util.dart';
import 'cover_pick.dart';

/// 未归类作品哨兵值
const int kUnassignedWork = -1;

/// 文本输入对话框
Future<String?> promptText(BuildContext context,
    {required String title, String initial = '', String hint = ''}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PromptDialog(title: title, initial: initial, hint: hint),
  );
}

Future<bool?> confirmDialog(BuildContext context,
    {required String title, required String content, String okLabel = '确定'}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content,
          style: TextStyle(color: AppColors.textSecondaryOf(ctx), fontSize: 13)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(okLabel)),
      ],
    ),
  );
}

/// 选择封面图片文件，返回路径
Future<String?> pickImagePath({String? title}) async {
  final f = await FilePicker.pickFile(
      type: FileType.image, dialogTitle: title ?? '选择封面图片');
  return f?.path;
}

/// 选择多个文件，返回非空路径列表；取消时为空列表。
Future<List<String>> pickFilePaths({
  required FileType type,
  List<String>? allowedExtensions,
  String? title,
}) async {
  final files = await FilePicker.pickFiles(
    type: type,
    allowedExtensions: allowedExtensions,
    dialogTitle: title,
  );
  return [
    for (final f in files)
      if (f.path != null && f.path!.isNotEmpty) f.path!,
  ];
}

/// 选择字幕文件，返回路径
Future<String?> pickSubtitlePath() async {
  final f = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['vtt', 'srt', 'lrc'],
      dialogTitle: '选择字幕文件');
  return f?.path;
}

/// 选择文件夹，返回路径
Future<String?> pickDirectory({String? title}) async {
  return FilePicker.getDirectoryPath(dialogTitle: title ?? '选择文件夹');
}

/// 设置作品封面：先把作品里的图片列出来让用户直接挑（手机上比系统选图省事
/// 得多），作品里没有图或都不合适时再退回系统选图。
Future<void> showImportCoverDialog(BuildContext context, int workId) async {
  final appState = context.read<AppState>();
  final paths = await appState.coverCandidatesUnderWork(workId);
  if (!context.mounted) return;
  String? current;
  for (final w in appState.works) {
    if (w.id == workId) {
      current = w.coverPath;
      break;
    }
  }
  final src = await showCoverImagePicker(
    context,
    title: paths.isEmpty ? '选择作品封面' : '选择作品封面（${paths.length} 张候选）',
    paths: paths,
    current: current,
  );
  if (src == null || src.isEmpty) return;
  final dest = await CoverService.importCover(src, workId);
  if (dest != null) {
    // 作品封面固定写在 work_<id>.<ext>，换图不换路径。Flutter 的 FileImage
    // 只按路径缓存，必须先驱逐旧解码结果，否则卡片继续显示老封面。
    ImageCacheGuard.invalidate(dest);
    if (current != null && current != dest) {
      ImageCacheGuard.invalidate(current);
    }
    await appState.setWorkCover(workId, dest);
  }
}

/// 替换当前曲目字幕
Future<void> showReplaceSubtitleDialog(BuildContext context, int trackId) async {
  final appState = context.read<AppState>();
  final path = await pickSubtitlePath();
  if (path == null) return;
  await appState.replaceSubtitle(trackId, path);
}

/// 选择目标作品（返回 work id，kUnassignedWork 表示未归类）
Future<int?> showWorkPicker(BuildContext context, {String title = '移动到作品'}) {
  return showDialog<int>(
    context: context,
    builder: (ctx) {
      final works = ctx.read<AppState>().works;
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 320,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('未归类'),
                onTap: () => Navigator.pop(ctx, kUnassignedWork),
              ),
              for (final w in works)
                ListTile(
                  leading: const Icon(Icons.album_outlined),
                  title: Text(w.name),
                  onTap: () => Navigator.pop(ctx, w.id),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _PromptDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String hint;
  const _PromptDialog(
      {required this.title, this.initial = '', this.hint = ''});

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
            child: const Text('确定')),
      ],
    );
  }
}
