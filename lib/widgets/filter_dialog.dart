import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/tag_dao.dart';
import '../services/settings_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/color_util.dart';
import '../utils/filter_expression.dart';

/// 高级筛选表达式对话框
class AdvancedFilterDialog extends StatefulWidget {
  const AdvancedFilterDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => const AdvancedFilterDialog(),
    );
  }

  @override
  State<AdvancedFilterDialog> createState() => _AdvancedFilterDialogState();
}

class _AdvancedFilterDialogState extends State<AdvancedFilterDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: context.read<AppState>().advancedFilter);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final appState = context.read<AppState>();
    try {
      await appState.setAdvancedFilter(_ctrl.text);
      if (mounted) Navigator.pop(context);
    } on FilterExpressionException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      // 兜底：解析器已经给递归深度设了上限，但不排除还有别的 Error。
      // 只 catch 语法异常的话，任何漏网的错误都会穿过这里逃到框架层，
      // 对话框留在屏幕上还不给提示。
      if (mounted) setState(() => _error = '表达式无法处理：$e');
    }
  }

  /// 点击标签 chip 时，把引用插入到光标处
  void _insertTag(Tag tag) {
    final ref = _tagRef(tag);
    final text = _ctrl.text;
    final sel = _ctrl.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final newText = text.replaceRange(start, end, ref);
    _ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + ref.length),
    );
    setState(() => _error = null);
  }

  /// 生成标签引用文本；名称含空白/运算符时加引号
  String _tagRef(Tag tag) {
    final hasNs = tag.namespace.isNotEmpty && tag.namespace != 'general';
    var s = hasNs ? '${tag.namespace}:${tag.name}' : tag.name;
    if (RegExp("[\\s&|!()\"']").hasMatch(s)) {
      s = '"$s"';
    }
    return s;
  }

  Widget _historyChip(String expr) {
    return GestureDetector(
      onTap: () {
        _ctrl.text = expr;
        _ctrl.selection = TextSelection.collapsed(offset: expr.length);
        setState(() => _error = null);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.surfaceAlt),
        ),
        child: Text(expr,
            style: const TextStyle(
                fontSize: 11,
                color: AppColors.textTertiary,
                fontFamily: 'monospace')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    // 用户标签排前面：规则标签有几十个，排在前面会把常用标签挤出可视区。
    final tags = [...appState.allTags]
      ..sort((a, b) {
        if (a.isRule != b.isRule) return a.isRule ? 1 : -1;
        return a.name.compareTo(b.name);
      });
    // 表达式历史由 SettingsService 持有（AsmrShelf 的 AppState 没有这一项）。
    final history = SettingsService.instance.expressionHistory;

    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: const Row(
        children: [
          Icon(Icons.filter_alt, size: 20, color: AppColors.accent),
          SizedBox(width: 8),
          Text('高级筛选',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 18)),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '输入布尔表达式筛选图片（启用后替换左侧的标签筛选）。\n'
              '运算符：!（非）、&& / &（与）、|| / |（或），括号 () 改变优先级。\n'
              '标签引用：风景  或  地点:风景  或  "带 空格 名字"。',
              style: TextStyle(
                  fontSize: 11, color: AppColors.mutedLight, height: 1.5),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              autofocus: true,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              style: const TextStyle(
                  fontSize: 13, fontFamily: 'monospace', color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: '例如：((风景||人像)&&!私密)||收藏',
                errorText: _error,
              ),
            ),
            if (history.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('历史',
                      style: TextStyle(fontSize: 11, color: AppColors.mutedLight)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () async {
                      await SettingsService.instance.clearExpressionHistory();
                      if (mounted) setState(() {});
                    },
                    child: const Text('清空',
                        style:
                            TextStyle(fontSize: 11, color: AppColors.muted)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: history.map(_historyChip).toList(),
              ),
            ],
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('可用标签（点击插入）',
                  style: TextStyle(fontSize: 11, color: AppColors.mutedLight)),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: tags.map(_tagChip).toList(),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (appState.hasAdvancedFilter)
          TextButton(
            onPressed: () async {
              await appState.clearAdvancedFilter();
              // build 作用域里的 context 是 build 的参数，不是 State.context，
              // 只能用 context.mounted 来通过 use_build_context_synchronously。
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('清除', style: TextStyle(color: AppColors.danger)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: AppColors.mutedLight)),
        ),
        FilledButton(
          onPressed: _apply,
          child: const Text('应用'),
        ),
      ],
    );
  }

  Widget _tagChip(Tag tag) {
    final color = _parseColor(tag.color);
    final label = tag.namespace.isEmpty || tag.namespace == 'general'
        ? tag.name
        : '${tag.namespace}:${tag.name}';
    return GestureDetector(
      onTap: () => _insertTag(tag),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }

  Color _parseColor(String hex) =>
      parseHexColor(hex, fallback: AppColors.accent);
}
