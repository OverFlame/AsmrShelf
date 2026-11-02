import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/widgets/dlsite_code_dialog.dart';

void main() {
  Future<Future<String?>> openDialog(WidgetTester tester,
      {String? initial}) async {
    final completer = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              showDlsiteCodeDialog(context, initial: initial)
                  .then(completer.complete);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return completer.future;
  }

  testWidgets('纯数字自动补 RJ，大写保存', (tester) async {
    final result = await openDialog(tester);
    await tester.enterText(
        find.byKey(const ValueKey('dlsite-code-input')), '378488');
    await tester.tap(find.byKey(const ValueKey('dlsite-code-save')));
    await tester.pumpAndSettle();

    expect(await result, 'RJ378488');
  });

  testWidgets('格式不对时留在弹窗里显示错误', (tester) async {
    await openDialog(tester);
    await tester.enterText(
        find.byKey(const ValueKey('dlsite-code-input')), 'abc');
    await tester.tap(find.byKey(const ValueKey('dlsite-code-save')));
    await tester.pumpAndSettle();

    expect(find.text('编号形如 RJ378488，6 到 8 位数字'), findsOneWidget);
    expect(find.byKey(const ValueKey('dlsite-code-input')), findsOneWidget);
  });

  testWidgets('取消返回空值', (tester) async {
    final result = await openDialog(tester, initial: 'RJ294126');
    await tester.tap(find.byKey(const ValueKey('dlsite-code-cancel')));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });
}
