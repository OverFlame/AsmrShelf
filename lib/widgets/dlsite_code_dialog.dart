import 'package:flutter/material.dart';

import '../services/dlsite/work_code.dart';

/// 目录名里没有 RJ 号时，让用户手动填一个。
///
/// 返回规范化后的编号（大写、纯数字会补 `RJ`）；取消或关闭返回 null。
Future<String?> showDlsiteCodeDialog(
  BuildContext context, {
  String? initial,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _DlsiteCodeDialog(initial: initial),
  );
}

class _DlsiteCodeDialog extends StatefulWidget {
  const _DlsiteCodeDialog({this.initial});

  final String? initial;

  @override
  State<_DlsiteCodeDialog> createState() => _DlsiteCodeDialogState();
}

class _DlsiteCodeDialogState extends State<_DlsiteCodeDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    var text = _controller.text.trim().toUpperCase();
    if (RegExp(r'^\d{6,8}$').hasMatch(text)) text = 'RJ$text';
    if (!isValidWorkCode(text)) {
      setState(() => _error = '编号形如 RJ378488，6 到 8 位数字');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('填写作品编号'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '目录名里没有认出 RJ 号。填一次会记进作品元数据，之后抓取都用它。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('dlsite-code-input'),
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'RJ378488',
                errorText: _error,
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('dlsite-code-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('dlsite-code-save'),
          onPressed: _submit,
          child: const Text('保存并抓取'),
        ),
      ],
    );
  }
}
