import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/auto_import_scanner.dart';
import 'package:asmrshelf/widgets/auto_import_dialog.dart';

/// 「扫描并确认」对话框：默认勾选可导入项，可取消勾选、标记忽略。
void main() {
  const root = '/music';
  final candidates = [
    const AutoImportCandidate(
      rootPath: root,
      dirPath: '$root/RJ000001 作品A',
      name: '作品A',
      state: AutoImportState.newWork,
      audioCount: 3,
      newCount: 3,
    ),
    const AutoImportCandidate(
      rootPath: root,
      dirPath: '$root/作品B',
      name: '作品B',
      state: AutoImportState.newTracks,
      audioCount: 5,
      newCount: 2,
      workId: 1,
    ),
    const AutoImportCandidate(
      rootPath: root,
      dirPath: '$root/作品C',
      name: '作品C',
      state: AutoImportState.unchanged,
      audioCount: 4,
      newCount: 0,
      workId: 2,
    ),
  ];

  Future<AutoImportDecision?> open(WidgetTester tester) async {
    AutoImportDecision? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('open'),
                onPressed: () async {
                  result = await showAutoImportDialog(
                    context,
                    candidates: candidates,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('默认勾选新建与有新增，确认返回这两个', (tester) async {
    await open(tester);
    expect(find.text('导入 2 部'), findsOneWidget);
    expect(find.text('作品A'), findsOneWidget);
    expect(find.text('作品C'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auto-import-confirm')));
    await tester.pumpAndSettle();
    // 对话框已关。
    expect(find.byKey(const ValueKey('auto-import-confirm')), findsNothing);
  });

  testWidgets('取消勾选后确认数量跟着变', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('auto-import-candidate-0')));
    await tester.pump();
    expect(find.text('导入 1 部'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('auto-import-confirm')));
    await tester.pumpAndSettle();
  });

  testWidgets('点忽略图标把该行从可导入里拿掉', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('auto-import-ignore-1')));
    await tester.pump();
    expect(find.text('导入 1 部'), findsOneWidget);
    expect(find.text('导入 2 部'), findsNothing);
  });

  testWidgets('取消按钮关闭对话框，不返回决定', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('auto-import-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('auto-import-cancel')), findsNothing);
  });
}
