import 'package:flutter/material.dart';

import '../services/auto_import_scanner.dart';
import '../theme/app_theme.dart';

/// 用户在扫描对话框里的决定。
class AutoImportDecision {
  const AutoImportDecision({required this.selected, required this.ignored});

  /// 要落库的候选。
  final List<AutoImportCandidate> selected;

  /// 本次新标记为忽略的目录。
  final List<String> ignored;
}

/// 展示自动导入的扫描结果：先看清单，勾选后再落库。
///
/// 没有候选时返回 null。取消也返回 null。
Future<AutoImportDecision?> showAutoImportDialog(
  BuildContext context, {
  required List<AutoImportCandidate> candidates,
}) {
  if (candidates.isEmpty) return Future.value(null);
  return showDialog<AutoImportDecision>(
    context: context,
    builder: (_) => _AutoImportDialog(candidates: candidates),
  );
}

class _AutoImportDialog extends StatefulWidget {
  const _AutoImportDialog({required this.candidates});

  final List<AutoImportCandidate> candidates;

  @override
  State<_AutoImportDialog> createState() => _AutoImportDialogState();
}

class _AutoImportDialogState extends State<_AutoImportDialog> {
  late final Set<String> _selected;
  final Set<String> _ignoredNow = {};

  @override
  void initState() {
    super.initState();
    _selected = {
      for (final c in widget.candidates)
        if (c.selectable) c.dirPath,
    };
  }

  int _count(AutoImportState state) =>
      widget.candidates.where((c) => c.state == state).length;

  @override
  Widget build(BuildContext context) {
    final counts = [
      '新建 ${_count(AutoImportState.newWork)}',
      '有新增 ${_count(AutoImportState.newTracks)}',
      '无变化 ${_count(AutoImportState.unchanged)}',
      '已忽略 ${_count(AutoImportState.ignored) + _ignoredNow.length}',
      '读不了 ${_count(AutoImportState.unreadable)}',
    ].join(' · ');

    final roots = <String>[];
    for (final c in widget.candidates) {
      if (!roots.contains(c.rootPath)) roots.add(c.rootPath);
    }

    return AlertDialog(
      title: const Text('自动导入扫描结果'),
      content: SizedBox(
        width: 680,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              counts,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondaryOf(context),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final root in roots) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
                      child: Text(
                        root,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.mutedOf(context),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (final c in widget.candidates.where(
                      (c) => c.rootPath == root,
                    ))
                      _row(c),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('auto-import-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('auto-import-confirm'),
          onPressed: _selected.isEmpty
              ? null
              : () {
                  final chosen = widget.candidates
                      .where((c) => _selected.contains(c.dirPath))
                      .toList();
                  Navigator.pop(
                    context,
                    AutoImportDecision(
                      selected: chosen,
                      ignored: _ignoredNow.toList(),
                    ),
                  );
                },
          child: Text('导入 ${_selected.length} 部'),
        ),
      ],
    );
  }

  Widget _row(AutoImportCandidate c) {
    final idx = widget.candidates.indexOf(c);
    final ignored = c.state == AutoImportState.ignored ||
        _ignoredNow.contains(c.dirPath);
    final selectable = c.selectable && !ignored;
    final detail = StringBuffer(c.state.label);
    if (c.audioCount > 0) detail.write(' · 音频 ${c.audioCount} 首');
    if (c.state == AutoImportState.newTracks) {
      detail.write(' · 新增 ${c.newCount}');
    }
    if (c.reason != null) detail.write(' · ${c.reason}');

    return Row(
      children: [
        Expanded(
          child: CheckboxListTile(
            key: ValueKey('auto-import-candidate-$idx'),
            dense: true,
            value: selectable && _selected.contains(c.dirPath),
            onChanged: selectable
                ? (v) {
                    setState(() {
                      if (v == true) {
                        _selected.add(c.dirPath);
                      } else {
                        _selected.remove(c.dirPath);
                      }
                    });
                  }
                : null,
            secondary: Icon(_iconFor(c.state), size: 18),
            title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              detail.toString(),
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondaryOf(context),
              ),
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ),
        if (!ignored)
          IconButton(
            key: ValueKey('auto-import-ignore-$idx'),
            tooltip: '忽略这个目录',
            icon: const Icon(Icons.visibility_off_outlined, size: 16),
            onPressed: () {
              setState(() {
                _ignoredNow.add(c.dirPath);
                _selected.remove(c.dirPath);
              });
            },
          ),
      ],
    );
  }

  IconData _iconFor(AutoImportState state) => switch (state) {
        AutoImportState.newWork => Icons.add_circle_outline,
        AutoImportState.newTracks => Icons.library_add_outlined,
        AutoImportState.unchanged => Icons.check_circle_outline,
        AutoImportState.ignored => Icons.visibility_off_outlined,
        AutoImportState.unreadable => Icons.error_outline,
      };
}
