import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/tag_dao.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/color_util.dart';

/// 打开多选标签对话框；返回选中的标签列表（null 表示取消）。
///
/// [filterTagIds] 非空时，仅显示这些 id 对应的标签（用于「移除标签」时只列
/// 出已存在的标签）。
///
/// [selectedTagIds] 非空时，这些标签在打开时就是勾选状态（用于编辑单个媒体
/// 已有标签的情形）。
Future<List<Tag>?> showTagPickerDialog(
  BuildContext context, {
  String title = '选择标签',
  Set<int>? filterTagIds,
  Set<int>? selectedTagIds,
}) {
  return showDialog<List<Tag>>(
    context: context,
    builder: (_) => _TagPickerDialog(
      title: title,
      filterTagIds: filterTagIds,
      selectedTagIds: selectedTagIds,
    ),
  );
}

class _TagPickerDialog extends StatefulWidget {
  final String title;
  final Set<int>? filterTagIds;
  final Set<int>? selectedTagIds;
  const _TagPickerDialog({
    required this.title,
    this.filterTagIds,
    this.selectedTagIds,
  });

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  final _searchCtrl = TextEditingController();
  String _search = '';
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    if (widget.selectedTagIds != null) _selected.addAll(widget.selectedTagIds!);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 命名空间折叠状态的键：空命名空间用空串（与 AppState 一致）。
  String _nsKey(String ns) => ns == '(无命名空间)' ? '' : ns;

  String _nsLabel(String ns) {
    if (ns == TagDao.kindNamespace) return '类型';
    if (ns == TagDao.extNamespace) return '扩展名';
    return ns;
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final q = _search.toLowerCase();
    final searching = _search.trim().isNotEmpty;
    // 联想搜索时忽略折叠状态，命中的标签一定看得见。
    final tags = appState.allTags
        .where((t) => !t.isRule)
        .where((t) =>
            q.isEmpty ||
            t.name.toLowerCase().contains(q) ||
            t.namespace.toLowerCase().contains(q))
        .where((t) =>
            widget.filterTagIds == null || widget.filterTagIds!.contains(t.id))
        .toList();

    // 按命名空间分组，标题可收起，与左侧标签栏一致。
    final namespaces = <String, List<Tag>>{};
    for (final t in tags) {
      final ns = t.namespace.isEmpty ? '(无命名空间)' : t.namespace;
      namespaces.putIfAbsent(ns, () => []).add(t);
    }
    final sortedNs = namespaces.keys.toList()
      ..sort((a, b) {
        if (a == '(无命名空间)') return 1;
        if (b == '(无命名空间)') return -1;
        return a.compareTo(b);
      });

    return AlertDialog(
      backgroundColor: AppColors.panelOf(context),
      title: Text(widget.title,
          style: TextStyle(
              color: AppColors.textPrimaryOf(context), fontSize: 16)),
      content: SizedBox(
        width: 320,
        height: 400,
        child: Column(
          children: [
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: (v) => setState(() => _search = v),
              style: TextStyle(
                  fontSize: 13, color: AppColors.textPrimaryOf(context)),
              decoration: const InputDecoration(
                hintText: '搜索标签...',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: tags.isEmpty
                  ? Center(
                      child: Text('没有匹配的标签',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.mutedLightOf(context))))
                  : ListView(
                      children: [
                        for (final ns in sortedNs) ...[
                          _nsHeader(appState, ns, namespaces[ns]!, searching),
                          if (searching ||
                              !appState.isNamespaceCollapsed(_nsKey(ns)))
                            for (final t in namespaces[ns]!) _tagRow(t),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('已选 ${_selected.length}',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.mutedLightOf(context))),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消',
              style: TextStyle(color: AppColors.mutedLightOf(context))),
        ),
        FilledButton(
          onPressed: () {
            final selected =
                appState.allTags.where((t) => _selected.contains(t.id)).toList();
            Navigator.pop(context, selected);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }

  /// 命名空间标题：点一下收起 / 展开这一组。
  Widget _nsHeader(
      AppState appState, String ns, List<Tag> group, bool searching) {
    final key = _nsKey(ns);
    final collapsed = !searching && appState.isNamespaceCollapsed(key);
    final selectedHere =
        group.where((t) => _selected.contains(t.id)).length;
    return InkWell(
      key: ValueKey('picker-ns-header-$key'),
      onTap: searching
          ? null
          : () => setState(() => appState.toggleNamespaceCollapsed(key)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Row(
          children: [
            Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 16,
              color: AppColors.mutedLighterOf(context),
            ),
            const SizedBox(width: 2),
            Text(_nsLabel(ns),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondaryOf(context))),
            const SizedBox(width: 6),
            Text('${group.length}',
                style: TextStyle(
                    fontSize: 11, color: AppColors.mutedLighterOf(context))),
            if (selectedHere > 0) ...[
              const SizedBox(width: 6),
              Icon(Icons.check_circle,
                  size: 12, color: AppColors.accent),
              const SizedBox(width: 2),
              Text('$selectedHere',
                  style:
                      const TextStyle(fontSize: 11, color: AppColors.accent)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tagRow(Tag t) {
    return CheckboxListTile(
      key: ValueKey('picker-tag-${t.id}'),
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: _selected.contains(t.id),
      onChanged: (v) => setState(() {
        if (v == true) {
          _selected.add(t.id!);
        } else {
          _selected.remove(t.id);
        }
      }),
      title: Text(t.name, style: const TextStyle(fontSize: 12)),
      secondary: _dot(t.color),
    );
  }

  Widget _dot(String hex) {
    final color = _parseColor(hex);
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Color _parseColor(String hex) =>
      parseHexColor(hex, fallback: AppColors.accent);
}
