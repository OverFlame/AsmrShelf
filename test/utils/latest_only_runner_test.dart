import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:asmrshelf/utils/latest_only_runner.dart';

/// [LatestOnlyRunner] 的行为：跑的过程中来的请求不能丢，但也不必每个都跑。
void main() {
  test('空闲时直接跑一次', () async {
    final runner = LatestOnlyRunner();
    var runs = 0;

    await runner.run(() async => runs++);

    expect(runs, 1);
    expect(runner.isRunning, isFalse);
  });

  test('跑的过程中来的请求：结束后补跑一次，用的是最新状态', () async {
    final runner = LatestOnlyRunner();
    final first = Completer<void>();
    final seen = <int>[];
    var current = 1;

    // 第一轮：跑起来后卡在 first 上，模拟「生成缩略图要等 IO」。
    final running = runner.run(() async {
      seen.add(current);
      if (seen.length == 1) await first.future;
    });
    expect(runner.isRunning, isTrue);

    // 卡片被复用给另一张图：参数变了，请求落在一个已经在跑的任务上。
    current = 2;
    await runner.run(() async {
      seen.add(current);
    });
    expect(seen, [1], reason: '第一次调用还在等 IO，重跑排在它后面');

    first.complete();
    await running;

    expect(seen, [1, 2], reason: '重跑要用最新的参数，不能拿旧参数再跑一次');
    expect(runner.isRunning, isFalse);
  });

  test('跑的过程中连着来多次请求，只补跑一次', () async {
    final runner = LatestOnlyRunner();
    final gate = Completer<void>();
    var runs = 0;

    final running = runner.run(() async {
      runs++;
      await gate.future;
    });

    for (var i = 0; i < 5; i++) {
      await runner.run(() async => runs++);
    }
    expect(runs, 1);

    gate.complete();
    await running;

    expect(runs, 2, reason: '五次请求合并成一次重跑，不用跑五遍');
    expect(runner.isRunning, isFalse);
  });

  test('补跑期间再来的请求会再排一轮', () async {
    final runner = LatestOnlyRunner();
    final first = Completer<void>();
    final second = Completer<void>();
    var runs = 0;

    final running = runner.run(() async {
      runs++;
      await first.future;
    });
    await runner.run(() async {
      runs++;
      await second.future;
    });

    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(runs, 2, reason: '第一轮结束就补跑第二轮');

    // 第二轮还在跑的时候又来一个请求。
    await runner.run(() async => runs++);
    second.complete();
    await running;

    expect(runs, 3);
    expect(runner.isRunning, isFalse);
  });

  test('任务抛异常也要复位，后续调用照常', () async {
    final runner = LatestOnlyRunner();
    var runs = 0;

    await expectLater(
        runner.run(() async => throw StateError('boom')), throwsStateError);
    expect(runner.isRunning, isFalse);

    await runner.run(() async => runs++);
    expect(runs, 1, reason: '一次失败不能把这个 runner 永久卡在「在跑」状态');
  });
}
