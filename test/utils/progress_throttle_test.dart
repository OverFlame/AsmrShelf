import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/utils/progress_throttle.dart';

void main() {
  test('每涨 1% 才通知一次', () {
    final t = ProgressThrottle();

    expect(t.shouldNotify(0.004), isFalse, reason: '没走够一格');
    expect(t.shouldNotify(0.01), isTrue);
    expect(t.shouldNotify(0.015), isFalse);
    expect(t.shouldNotify(0.02), isTrue);
    expect(t.lastNotified, 20);
  });

  test('一万个文件的导入最多通知一百来次', () {
    final t = ProgressThrottle();
    var notifications = 0;

    for (var i = 1; i <= 10000; i++) {
      if (t.shouldNotify(i / 10000)) notifications++;
    }

    // 逐文件通知是一万次；这里必须落到同一量级的百分之一。
    expect(notifications, lessThanOrEqualTo(101));
    expect(notifications, greaterThanOrEqualTo(99),
        reason: '也不能把进度条拖成不动');
  });

  test('文件数不到一百时逐文件通知，进度条照样平滑', () {
    final t = ProgressThrottle();
    var notifications = 0;

    for (var i = 1; i <= 40; i++) {
      if (t.shouldNotify(i / 40)) notifications++;
    }

    expect(notifications, 40);
  });

  test('进度回退说明是新的一次导入，重新算起', () {
    final t = ProgressThrottle();
    expect(t.shouldNotify(0.9), isTrue);

    // 进度条要从 90% 跳回 20%，这一次必须通知，否则界面卡在上一次的进度上。
    expect(t.shouldNotify(0.2), isTrue);
    expect(t.lastNotified, 200);

    expect(t.shouldNotify(0.205), isFalse);
    expect(t.shouldNotify(0.21), isTrue);
  });

  test('step 可以调大，粒度更粗', () {
    final t = ProgressThrottle(stepPermille: 250);
    expect(t.shouldNotify(0.1), isFalse);
    expect(t.shouldNotify(0.25), isTrue);
    expect(t.shouldNotify(0.4), isFalse);
    expect(t.shouldNotify(0.5), isTrue);
  });
}
