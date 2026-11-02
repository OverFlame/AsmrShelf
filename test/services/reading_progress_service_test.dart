import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/reading_progress_service.dart';
import '../support/test_env.dart';


/// 可控时钟：测试推进时间，不真的等
class _FakeClock {
  _FakeClock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration delta) {
    now = now.add(delta);
  }
}

class _Task {
  _Task(this.delay, this.action);

  final Duration delay;
  final void Function() action;
}

/// 假节流定时器：只记录到点任务，由测试显式触发
class _FakeScheduler implements ThrottleScheduler {
  final List<_Task> tasks = <_Task>[];

  int get pending => tasks.length;

  @override
  Object schedule(Duration delay, void Function() action) {
    final task = _Task(delay, action);
    tasks.add(task);
    return task;
  }

  @override
  void cancel(Object handle) {
    tasks.removeWhere((task) => identical(task, handle));
  }

  /// 触发全部到点任务（模拟定时器真的响了）
  Future<void> fire() async {
    final due = List<_Task>.of(tasks);
    tasks.clear();
    for (final task in due) {
      task.action();
    }
    await pumpEventQueue();
  }
}

/// 等待后台补写落盘。`pumpEventQueue` 的轮数固定，全量并发跑或覆盖率
/// 插桩下事务回调可能晚到，这里按条件等，超时才失败。
Future<void> _waitForWrite(ReadingProgressService service, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (service.writeCount < count) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待落盘超时：writeCount=${service.writeCount}，期望 $count');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late int volumeA;
  late int volumeB;
  late int mediaId;

  Future<int> insertFolder(String name) => db.insert('folders', <String, Object?>{
        'name': name,
        'library': 'media',
      });

  Future<int> insertImage(String path) => db.insert('media', <String, Object?>{
        'path': path,
        'media_type': 'image',
        'filename': p.basename(path),
        'added_at': 1,
      });

  Future<Map<String, Object?>?> rowOf(int volumeId) async {
    final rows = await db.query(
      'reading_progress',
      where: 'volume_id = ?',
      whereArgs: <Object?>[volumeId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_reading');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;

    volumeA = await insertFolder('vol-a');
    volumeB = await insertFolder('vol-b');
    mediaId = await insertImage(p.join(tmp.path, 'a.jpg'));
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  ReadingProgressService build({
    _FakeClock? clock,
    _FakeScheduler? scheduler,
    Duration throttle = const Duration(seconds: 1),
    void Function(int, ReadingProgress)? onPersist,
  }) {
    return ReadingProgressService(
      db,
      throttle: throttle,
      clock: (clock ?? _FakeClock(DateTime.utc(2026, 1, 1, 0, 0, 0))).call,
      scheduler: scheduler ?? _FakeScheduler(),
      persistListener: onPersist,
    );
  }

  group('读取', () {
    test('没有记录时返回 null', () async {
      final service = build();
      expect(await service.get(volumeA), isNull);
      expect(await service.isFinished(volumeA), isFalse);
      expect(await service.getMany(<int>[volumeA, volumeB]), isEmpty);
    });

    test('多卷一次读只返回有记录的卷', () async {
      final service = build();
      await service.record(volumeA, mediaId: mediaId, pageIndex: 2);
      await service.flush();

      final many = await service.getMany(<int>[volumeA, volumeB]);
      expect(many.keys, <int>[volumeA]);
      expect(many[volumeA]!.pageIndex, 2);
      expect(many[volumeA]!.mediaId, mediaId);
    });

    test('getMany 会反映还没落盘的 pending', () async {
      final clock = _FakeClock(DateTime.utc(2026, 1, 1));
      final service = build(clock: clock);
      await service.record(volumeA, pageIndex: 1);
      clock.advance(const Duration(milliseconds: 100));
      await service.record(volumeA, pageIndex: 7);

      final many = await service.getMany(<int>[volumeA]);
      expect(many[volumeA]!.pageIndex, 7);
      expect(await rowOf(volumeA).then((r) => r!['page_index']), 1);
    });
  });

  group('节流写入', () {
    test('窗口内多次写入只落一次盘，窗口末尾补一次', () async {
      final clock = _FakeClock(DateTime.utc(2026, 1, 1, 0, 0, 0));
      final scheduler = _FakeScheduler();
      final service = build(clock: clock, scheduler: scheduler);

      await service.record(volumeA, mediaId: mediaId, pageIndex: 1);
      expect(service.writeCount, 1, reason: '第一次写入没有上次落盘时间，应立刻写');
      expect((await rowOf(volumeA))!['page_index'], 1);

      clock.advance(const Duration(milliseconds: 200));
      await service.record(volumeA, pageIndex: 2);
      clock.advance(const Duration(milliseconds: 200));
      await service.record(volumeA, pageIndex: 3);
      clock.advance(const Duration(milliseconds: 200));
      await service.record(volumeA, pageIndex: 4);

      expect(service.writeCount, 1, reason: '窗口内不应再落盘');
      expect((await rowOf(volumeA))!['page_index'], 1);
      expect(service.hasPending, isTrue);
      expect(scheduler.pending, 1, reason: '窗口内只挂一个补写定时器');
      expect(scheduler.tasks.single.delay, const Duration(milliseconds: 800));

      clock.advance(const Duration(milliseconds: 200)); // 到 t0 + 1s
      await scheduler.fire();
      await _waitForWrite(service, 2);

      expect(service.writeCount, 2);
      expect((await rowOf(volumeA))!['page_index'], 4);
      expect(service.hasPending, isFalse);
      expect(scheduler.pending, 0);
    });

    test('跨过窗口后再次写入立刻落盘', () async {
      final clock = _FakeClock(DateTime.utc(2026, 1, 1, 0, 0, 0));
      final scheduler = _FakeScheduler();
      final service = build(clock: clock, scheduler: scheduler);

      await service.record(volumeA, pageIndex: 1);
      expect(service.writeCount, 1);

      clock.advance(const Duration(seconds: 2));
      await service.record(volumeA, pageIndex: 2);

      expect(service.writeCount, 2);
      expect((await rowOf(volumeA))!['page_index'], 2);
      expect(service.hasPending, isFalse);
      expect(scheduler.pending, 0);
    });

    test('窗口内的写入按卷分别攒着', () async {
      final clock = _FakeClock(DateTime.utc(2026, 1, 1));
      final scheduler = _FakeScheduler();
      final service = build(clock: clock, scheduler: scheduler);

      await service.record(volumeA, pageIndex: 1);
      clock.advance(const Duration(milliseconds: 100));
      await service.record(volumeA, pageIndex: 2);
      await service.record(volumeB, pageIndex: 9);

      expect(service.writeCount, 1);
      expect(service.pendingVolumeIds.toSet(), <int>{volumeA, volumeB});

      clock.advance(const Duration(seconds: 1));
      await scheduler.fire();
      await _waitForWrite(service, 2);

      expect(service.writeCount, 2, reason: '两个卷在一次补写里一起落盘');
      expect((await rowOf(volumeA))!['page_index'], 2);
      expect((await rowOf(volumeB))!['page_index'], 9);
    });

    test('flush 立即落盘并撤销补写定时器', () async {
      final clock = _FakeClock(DateTime.utc(2026, 1, 1));
      final scheduler = _FakeScheduler();
      final service = build(clock: clock, scheduler: scheduler);

      await service.record(volumeA, pageIndex: 1);
      clock.advance(const Duration(milliseconds: 100));
      await service.record(volumeA, pageIndex: 5);
      expect(scheduler.pending, 1);

      await service.flush();

      expect(service.writeCount, 2);
      expect((await rowOf(volumeA))!['page_index'], 5);
      expect(service.hasPending, isFalse);
      expect(scheduler.pending, 0);
    });

    test('没有待写内容时 flush 不算一次写入', () async {
      final service = build();
      await service.flush();
      await service.flush();
      expect(service.writeCount, 0);
    });

    test('flush 之后时钟继续走，窗口重新计时', () async {
      final clock = _FakeClock(DateTime.utc(2026, 1, 1));
      final scheduler = _FakeScheduler();
      final service = build(clock: clock, scheduler: scheduler);

      await service.record(volumeA, pageIndex: 1);
      clock.advance(const Duration(milliseconds: 100));
      await service.record(volumeA, pageIndex: 2);
      await service.flush(); // t0 + 100ms 落盘
      expect(service.writeCount, 2);

      clock.advance(const Duration(milliseconds: 100));
      await service.record(volumeA, pageIndex: 3);
      expect(service.writeCount, 2, reason: '距上次落盘只有 100ms，仍在窗口内');
      expect(scheduler.pending, 1);
      expect(scheduler.tasks.single.delay, const Duration(milliseconds: 900));
    });
  });

  group('updated_at 与完成标记', () {
    test('updated_at 用注入时钟的毫秒值', () async {
      final clock = _FakeClock(DateTime.utc(2026, 3, 4, 5, 6, 7, 890));
      final service = build(clock: clock);
      await service.record(volumeA, pageIndex: 1);
      expect((await rowOf(volumeA))!['updated_at'],
          clock.now.millisecondsSinceEpoch);

      clock.advance(const Duration(seconds: 2));
      await service.markFinished(volumeA);
      expect((await rowOf(volumeA))!['updated_at'],
          DateTime.utc(2026, 3, 4, 5, 6, 9, 890).millisecondsSinceEpoch);
      expect((await rowOf(volumeA))!['finished'], 1);
    });

    test('markFinished 与取消完成', () async {
      final service = build();
      await service.record(volumeA, pageIndex: 3);
      await service.markFinished(volumeA, pageIndex: 3, mediaId: mediaId);
      await service.flush();

      var saved = await rowOf(volumeA);
      expect(saved!['finished'], 1);
      expect(saved['page_index'], 3);
      expect(saved['media_id'], mediaId);
      expect(await service.isFinished(volumeA), isTrue);

      await service.setFinished(volumeA, false);
      await service.flush();
      saved = await rowOf(volumeA);
      expect(saved!['finished'], 0);
      expect(await service.isFinished(volumeA), isFalse);
    });

    test('翻页不会把完成标记抹掉', () async {
      final service = build();
      await service.markFinished(volumeA);
      await service.flush();
      await service.record(volumeA, pageIndex: 1);
      await service.flush();
      expect((await rowOf(volumeA))!['finished'], 1);
    });

    test('负数页码归零', () async {
      final service = build();
      await service.record(volumeA, pageIndex: -5);
      await service.flush();
      expect((await rowOf(volumeA))!['page_index'], 0);
    });
  });

  group('清理与生命周期', () {
    test('clear 删行并丢弃未落盘的 pending', () async {
      final clock = _FakeClock(DateTime.utc(2026, 1, 1));
      final scheduler = _FakeScheduler();
      final service = build(clock: clock, scheduler: scheduler);

      await service.record(volumeA, pageIndex: 1);
      clock.advance(const Duration(milliseconds: 100));
      await service.record(volumeA, pageIndex: 5);
      expect(scheduler.pending, 1);

      await service.clear(volumeA);

      expect(await rowOf(volumeA), isNull);
      expect(service.hasPending, isFalse);
      expect(scheduler.pending, 0);
      final before = service.writeCount;
      await service.flush();
      expect(service.writeCount, before, reason: 'pending 已清掉，flush 不该再写');
    });

    test('clearAll 清掉所有卷', () async {
      final service = build();
      await service.record(volumeA, pageIndex: 1);
      await service.flush();
      await service.record(volumeB, pageIndex: 2);
      await service.flush();

      await service.clearAll();

      expect(await rowOf(volumeA), isNull);
      expect(await rowOf(volumeB), isNull);
    });

    test('dispose 会先把攒着的进度落盘', () async {
      final clock = _FakeClock(DateTime.utc(2026, 1, 1));
      final service = build(clock: clock);
      await service.record(volumeA, pageIndex: 1);
      clock.advance(const Duration(milliseconds: 100));
      await service.record(volumeA, pageIndex: 8);

      await service.dispose();

      expect((await rowOf(volumeA))!['page_index'], 8);
      expect(service.isDisposed, isTrue);
      expect(() => service.record(volumeA, pageIndex: 9), throwsStateError);
    });

    test('onPersist 回调在落盘后触发', () async {
      final persisted = <String>[];
      final clock = _FakeClock(DateTime.utc(2026, 1, 1));
      final service = build(
        clock: clock,
        onPersist: (volumeId, progress) =>
            persisted.add('$volumeId:${progress.pageIndex}'),
      );
      await service.record(volumeA, pageIndex: 1);
      clock.advance(const Duration(milliseconds: 100));
      await service.record(volumeA, pageIndex: 2);
      await service.flush();

      expect(persisted, <String>['$volumeA:1', '$volumeA:2']);
    });
  });
}
