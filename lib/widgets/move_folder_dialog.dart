import 'package:flutter/material.dart';

import '../db/folder_dao.dart';
import '../theme/app_theme.dart';

/// 根级目标哨兵值（区别于「取消」返回的 null）
const int kMoveToRoot = -1;

/// 打开「移动文件夹」选择器对话框。
///
/// 返回目标父级 id；[kMoveToRoot] 表示移动到根级；null 表示取消。
Future<int?> showMoveFolderDialog(
  BuildContext context, {
  required VirtualFolder source,
  required List<VirtualFolder> allFolders,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => MoveFolderDialog(source: source, allFolders: allFolders),
  );
}

/// 树形目标选择器：展示所有可用父级（排除自身及后代，避免循环），含「根级」入口。
class MoveFolderDialog extends StatefulWidget {
  final VirtualFolder source;
  final List<VirtualFolder> allFolders;

  const MoveFolderDialog({
    super.key,
    required this.source,
    required this.allFolders,
  });

  @override
  State<MoveFolderDialog> createState() => _MoveFolderDialogState();
}

class _MoveFolderDialogState extends State<MoveFolderDialog> {
  /// null 表示根级；其他值表示具体文件夹 id
  int? _selectedParentId;

  late final Map<int?, List<VirtualFolder>> _childrenMap;

  /// DFS 预拍平的节点表（含缩进深度）：递归建 Column 会把整棵树一次性
  /// 建出来，改用单层 ListView.builder 只为可见行建 widget。
  late final List<_FlatFolder> _flat;

  @override
  void initState() {
    super.initState();
    _selectedParentId = widget.source.parentId;

    final excluded = _collectExcluded();
    final available = widget.allFolders
        .where((f) => f.id != null && !excluded.contains(f.id))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _childrenMap = {};
    for (final f in available) {
      _childrenMap.putIfAbsent(f.parentId, () => []).add(f);
    }
    _childrenMap.forEach((_, list) => list
        .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())));

    _flat = _flatten();
  }

  List<_FlatFolder> _flatten() {
    final out = <_FlatFolder>[];

    void walk(VirtualFolder folder, int depth) {
      out.add(_FlatFolder(folder, depth));
      for (final child in _childrenMap[folder.id] ?? const <VirtualFolder>[]) {
        walk(child, depth + 1);
      }
    }

    for (final root in _childrenMap[null] ?? const <VirtualFolder>[]) {
      walk(root, 0);
    }
    return out;
  }

  /// 自身 + 所有后代（不能作为移动目标，避免出现循环层级）
  Set<int> _collectExcluded() {
    final excluded = <int>{widget.source.id!};
    final stack = <int>[widget.source.id!];
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      for (final f in widget.allFolders) {
        if (f.parentId == cur && f.id != null && !excluded.contains(f.id)) {
          excluded.add(f.id!);
          stack.add(f.id!);
        }
      }
    }
    return excluded;
  }

  void _confirm() {
    Navigator.pop(context, _selectedParentId ?? kMoveToRoot);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: Text(
        '移动「${widget.source.name}」到',
        style: const TextStyle(fontSize: 15, color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 320,
        height: 380,
        child: Column(
          children: [
            _targetEntry(
              name: '根级（顶层）',
              icon: Icons.home_outlined,
              depth: 0,
              selected: _selectedParentId == null,
              onTap: () => setState(() => _selectedParentId = null),
            ),
            const Divider(height: 1, color: AppColors.surface),
            Expanded(
              child: _flat.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '暂无可用目标文件夹',
                        style:
                            TextStyle(fontSize: 12, color: AppColors.mutedLight),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: _flat.length,
                      itemBuilder: (ctx, i) {
                        final node = _flat[i];
                        return _targetEntry(
                          name: node.folder.name,
                          depth: node.depth,
                          selected: _selectedParentId == node.folder.id,
                          onTap: () => setState(
                              () => _selectedParentId = node.folder.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: _confirm,
          child: const Text('移动', style: TextStyle(color: AppColors.accent)),
        ),
      ],
    );
  }

  Widget _targetEntry({
    required String name,
    required int depth,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? AppColors.surface : null,
        padding: EdgeInsets.only(
          left: 8 + depth * 16.0,
          right: 8,
          top: 6,
          bottom: 6,
        ),
        child: Row(
          children: [
            Icon(
              icon ?? Icons.folder_outlined,
              size: 15,
              color: selected ? AppColors.accent : AppColors.warning,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (selected)
              const Icon(Icons.check, size: 14, color: AppColors.accent),
          ],
        ),
      ),
    );
  }
}

/// DFS 拍平后的目标文件夹节点（[depth] 用于缩进）
class _FlatFolder {
  const _FlatFolder(this.folder, this.depth);

  final VirtualFolder folder;
  final int depth;
}
