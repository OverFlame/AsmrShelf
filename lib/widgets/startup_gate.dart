import 'package:flutter/material.dart';

import '../services/migration_guard.dart';

/// 还原一个备份，返回它的结构版本。由调用方注入，便于测试替换。
typedef RestoreBackup = Future<int> Function(String backupPath);

/// 结构升级前的确认页。点「重建」之前数据库一行没动，备份已经落盘。
class MigrationConfirmPage extends StatelessWidget {
  const MigrationConfirmPage({
    super.key,
    required this.backup,
    required this.backups,
    required this.onRestore,
    required this.onResult,
  });

  final MigrationBackup backup;
  final List<BackupEntry> backups;
  final RestoreBackup onRestore;
  final ValueChanged<bool> onResult;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: AlertDialog(
              title: const Text('需要重建媒体库'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('媒体库结构从 v${backup.plan.fromVersion} 升级到 '
                      'v${backup.plan.toVersion}，升级会重建全部表。'),
                  const SizedBox(height: 12),
                  const Text('媒体条目、文件夹、标签、播放记录会清空。原始文件不受影响。'),
                  const SizedBox(height: 12),
                  const Text('已备份到：'),
                  SelectableText(backup.backupPath),
                  const SizedBox(height: 12),
                  Text(
                    '要保留现有数据，请先点「取消」，关闭应用并拷走备份。',
                    style: TextStyle(color: scheme.error),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => _openRestore(context, backups, onRestore),
                  child: const Text('从备份还原'),
                ),
                TextButton(
                  onPressed: () => onResult(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => onResult(true),
                  child: const Text('重建'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 用户拒绝升级后停在这里：不启动数据库，也不碰任何文件。
class MigrationCancelledPage extends StatelessWidget {
  const MigrationCancelledPage({
    super.key,
    required this.backup,
    required this.backups,
    required this.onRestore,
    required this.onRetry,
  });

  final MigrationBackup backup;
  final List<BackupEntry> backups;
  final RestoreBackup onRestore;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('已取消重建', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text('媒体库未改动。点「重试」回到确认页，或关闭窗口稍后再启动。'),
                const SizedBox(height: 12),
                const Text('备份位置：'),
                SelectableText(backup.backupPath),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(
                      onPressed: onRetry,
                      child: const Text('重试'),
                    ),
                    TextButton(
                      onPressed: () =>
                          _openRestore(context, backups, onRestore),
                      child: const Text('从备份还原'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 备份列表。选中一份就替换当前库，替换前会先删旧库的 -wal / -shm。
class MigrationRestorePage extends StatefulWidget {
  const MigrationRestorePage({
    super.key,
    required this.backups,
    required this.onRestore,
  });

  final List<BackupEntry> backups;
  final RestoreBackup onRestore;

  @override
  State<MigrationRestorePage> createState() => _MigrationRestorePageState();
}

class _MigrationRestorePageState extends State<MigrationRestorePage> {
  String? _restoringPath;
  int? _restoredVersion;
  String? _error;

  Future<void> _restore(BackupEntry entry) async {
    setState(() {
      _restoringPath = entry.path;
      _error = null;
    });
    try {
      final version = await widget.onRestore(entry.path);
      if (!mounted) return;
      setState(() => _restoredVersion = version);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _restoringPath = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('还原备份')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _restoredVersion != null
                ? _restoredView(_restoredVersion!)
                : _listView(),
          ),
        ),
      ),
    );
  }

  Widget _restoredView(int version) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('已还原 v$version 备份',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        const Text('媒体库已替换为备份内容。'),
        const SizedBox(height: 12),
        const Text('请关闭应用，安装与备份版本一致的应用版本再打开。'),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回'),
          ),
        ),
      ],
    );
  }

  Widget _listView() {
    if (widget.backups.isEmpty) {
      return const Text('没有可用备份。');
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('选择一份备份替换当前媒体库。'),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 12),
        for (final entry in widget.backups)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(entry.name),
            subtitle: Text('v${entry.version} · ${_sizeText(entry.bytes)} · '
                '${_dateText(entry.modified)}'),
            trailing: FilledButton(
              onPressed: _restoringPath == null ? () => _restore(entry) : null,
              child: Text(_restoringPath == entry.path ? '还原中' : '还原'),
            ),
          ),
      ],
    );
  }
}

void _openRestore(
  BuildContext context,
  List<BackupEntry> backups,
  RestoreBackup onRestore,
) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => MigrationRestorePage(backups: backups, onRestore: onRestore),
  ));
}

String _sizeText(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _dateText(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
