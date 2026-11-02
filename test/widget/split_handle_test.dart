import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/widgets/split_handle.dart';

void main() {
  testWidgets('横向拖动把增量交给回调，松手回调一次', (tester) async {
    var total = 0.0;
    var dragEnds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 300, child: Text('左')),
              SplitHandle(
                axis: Axis.horizontal,
                onDragDelta: (d) => total += d,
                onDragEnd: () => dragEnds++,
              ),
              const Expanded(child: Text('右')),
            ],
          ),
        ),
      ),
    );

    // 先用一次移动越过手势 slop，再量真正的增量：这一例只验证透传。
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(SplitHandle)));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    total = 0;
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(total, closeTo(60, 0.01));
    expect(dragEnds, 1);
  });

  testWidgets('纵向拖动改的是高度', (tester) async {
    var total = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 200, child: Text('上')),
              SplitHandle(
                axis: Axis.vertical,
                onDragDelta: (d) => total += d,
              ),
              const Expanded(child: Text('下')),
            ],
          ),
        ),
      ),
    );

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(SplitHandle)));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    total = 0;
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(total, closeTo(40, 0.01));
  });

  testWidgets('命中区宽 8 像素，双击触发重置', (tester) async {
    var resets = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SplitHandle(
                axis: Axis.horizontal,
                onDragDelta: (_) {},
                onReset: () => resets++,
              ),
              const Expanded(child: Text('右')),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(SplitHandle)).width, 8);

    await tester.tap(find.byType(SplitHandle));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(SplitHandle));
    await tester.pump(const Duration(milliseconds: 400));

    expect(resets, 1);
  });
}
