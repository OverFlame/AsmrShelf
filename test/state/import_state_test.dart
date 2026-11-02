import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/state/import_state.dart';

void main() {
  test('begin 置位并清掉上一次的错误', () {
    final state = ImportState();
    state.begin('first');
    state.fail('磁盘满了');
    state.end();

    expect(state.error, '磁盘满了');
    expect(state.begin('second'), isTrue);
    expect(state.importing, isTrue);
    expect(state.error, isNull);
    expect(state.progress, 0);
  });

  test('导入进行中再 begin 被拒绝，且不影响当前进度', () {
    final state = ImportState();
    expect(state.begin('first'), isTrue);
    state.reportProgress(0.4);

    expect(state.begin('second'), isFalse);
    expect(state.progress, 0.4);
    expect(state.importing, isTrue);
  });

  test('进度只收 0 到 1 之间，重复值不重复通知', () {
    final state = ImportState();
    state.begin('x');

    var notified = 0;
    state.addListener(() => notified++);

    state.reportProgress(0.5);
    state.reportProgress(0.5);
    expect(notified, 1);
    expect(state.progress, 0.5);

    state.reportProgress(2.5);
    expect(state.progress, 1.0);
    state.reportProgress(-1);
    expect(state.progress, 0.0);
    state.reportProgress(double.nan);
    expect(state.progress, 0.0);
  });

  test('end 清进度与进行中标志，但保留错误', () {
    final state = ImportState();
    state.begin('x');
    state.reportProgress(0.8);
    state.fail(StateError('读目录失败'));
    state.end();

    expect(state.importing, isFalse);
    expect(state.progress, 0);
    expect(state.error, contains('读目录失败'));
  });
}
