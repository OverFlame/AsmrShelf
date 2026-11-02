import 'dart:io';

import 'package:flutter/material.dart';

import 'dialogs.dart';
import 'package:path/path.dart' as p;

import '../db/media_dao.dart';
import '../theme/app_theme.dart';
import '../utils/file_io.dart';
import '../utils/log_util.dart';

/// 导出 / 分享操作按钮组
class ExportActions extends StatelessWidget {
  final MediaItem? image;
  final VoidCallback? onDone;

  const ExportActions({super.key, this.image, this.onDone});

  @override
  Widget build(BuildContext context) {
    if (image == null) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _actionButton(
          icon: Icons.file_copy,
          tooltip: '另存为...',
          onTap: () => _saveAs(context),
        ),
        const SizedBox(width: 2),
        _actionButton(
          icon: Icons.folder_open,
          tooltip: '打开文件位置',
          onTap: () => _openLocation(context),
        ),
      ],
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 16, color: AppColors.mutedLight),
        ),
      ),
    );
  }

  // ── 另存为 ──
  Future<void> _saveAs(BuildContext context) async {
    final img = image;
    if (img == null) return;

    final messenger = ScaffoldMessenger.of(context);
    final String? destDir = await pickDirectory(title: '选择保存目录');

    if (destDir == null || !context.mounted) return;

    final String destPath;
    try {
      if (!await File(img.path).exists()) {
        messenger.showSnackBar(const SnackBar(content: Text('源文件不存在，无法另存')));
        return;
      }
      destPath = await _copyToDirectory(img.path, destDir);
    } catch (e) {
      logError(
        'Export',
        'Save as failed: ${img.path} -> $destDir',
        e.toString(),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
      return;
    }

    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text('已保存到 ${p.relative(destPath)}'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: '打开',
          textColor: AppColors.lavender,
          onPressed: () => _openFileLocation(destPath),
        ),
      ),
    );
    onDone?.call();
    logInfo('Export', 'Saved as: $destPath');
  }

  /// 复制到目标目录，重名时自动加 ` (1)`、` (2)` 后缀。
  ///
  /// 原实现走 `AppState.copySelectedImageTo`；AsmrShelf 的 AppState 没有
  /// 这个成员，而且会覆盖同名文件，所以在这里直接落盘。
  Future<String> _copyToDirectory(String src, String destDir) async {
    final dest = _uniqueDestination(destDir, p.basename(src));
    await safeCopyFile(src, dest);
    return dest;
  }

  String _uniqueDestination(String dir, String fileName) {
    final ext = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    var candidate = p.join(dir, fileName);
    var i = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(dir, '$stem ($i)$ext');
      i++;
    }
    return candidate;
  }

  // ── 打开文件位置 ──
  Future<void> _openLocation(BuildContext context) async {
    final img = image;
    if (img == null) return;
    await _openFileLocation(img.path);
  }

  /// 在系统文件管理器中定位并显示文件。
  ///
  /// 各平台实现：
  /// - Windows: `explorer /select,<path>` 在资源管理器中选中该文件
  /// - macOS:   `open -R <path>` 在 Finder 中显示该文件
  /// - Linux:   `xdg-open <目录>`（xdg-open 无法选中单个文件，退而打开其所在目录）
  Future<void> _openFileLocation(String path) async {
    try {
      ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run('explorer', ['/select,$path']);
      } else if (Platform.isMacOS) {
        result = await Process.run('open', ['-R', path]);
      } else {
        result = await Process.run('xdg-open', [p.dirname(path)]);
      }
      if (result.exitCode != 0 && result.stderr.toString().isNotEmpty) {
        logWarn(
          'Export',
          'Open file location exited ${result.exitCode}: ${result.stderr}',
        );
      }
    } catch (e) {
      logError('Export', 'Failed to open file location', e.toString());
    }
  }
}
