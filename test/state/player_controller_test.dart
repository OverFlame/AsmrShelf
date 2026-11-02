import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/services/segment_service.dart';
import 'package:asmrshelf/state/player_controller.dart';

TrackItem item(int i) => TrackItem(
      id: i,
      path: '/m/a$i.mp3',
      filename: 'a$i.mp3',
      addedAt: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('洗牌队列（第 24.1 项）', () {
    test('一轮内不重复，走完重开一轮', () async {
      final player = PlayerController();
      player.debugSeedQueue(List.generate(5, item));
      player.setRepeatMode(RepeatMode.all);
      player.setShuffle(true);

      final round1 = <int>{player.index};
      for (var i = 0; i < 4; i++) {
        await player.next();
        round1.add(player.index);
      }
      expect(round1.length, 5, reason: '一轮 5 首应互不重复');

      final round2 = <int>{};
      for (var i = 0; i < 5; i++) {
        await player.next();
        round2.add(player.index);
      }
      expect(round2.length, 5, reason: '第二轮仍是 5 首互不重复');
    });

    test('随机且不循环时，一轮走完即停止', () async {
      final player = PlayerController();
      player.debugSeedQueue(List.generate(3, item));
      player.setRepeatMode(RepeatMode.off);
      player.setShuffle(true);

      await player.next();
      expect(player.queueLength, 3);
      await player.next();
      expect(player.queueLength, 3, reason: '一轮还没走完');

      await player.next();
      expect(player.queueLength, 0, reason: '一轮走完且不循环：停止并清空');
      expect(player.hasTrack, isFalse);
    });

    test('上一首按洗牌顺序回退', () async {
      final player = PlayerController();
      player.debugSeedQueue(List.generate(4, item));
      player.setRepeatMode(RepeatMode.all);
      player.setShuffle(true);

      await player.next();
      final first = player.index;
      await player.next();
      expect(player.index, isNot(first));

      await player.previous();
      expect(player.index, first);
    });

    test('关闭随机后回到顺序推进', () async {
      final player = PlayerController();
      player.debugSeedQueue(List.generate(4, item), startIndex: 1);
      player.setRepeatMode(RepeatMode.all);
      player.setShuffle(true);
      player.setShuffle(false);
      expect(player.shuffleOrder, isEmpty);

      await player.next();
      expect(player.index, 2);
      await player.previous();
      expect(player.index, 1);
    });
  });

  group('队列编辑（第 24.1 项）', () {
    test('playNext 插到当前曲目之后', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1), item(2), item(3)], startIndex: 1);

      await player.playNext(item(9));

      expect(player.queue.map((t) => t.id).toList(), [1, 2, 9, 3]);
      expect(player.index, 1);
      expect(player.currentTrack!.id, 2);
    });

    test('jumpTo 切到指定下标', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1), item(2), item(3)], startIndex: 0);

      await player.jumpTo(2);

      expect(player.index, 2);
      expect(player.currentTrack!.id, 3);
    });

    test('删除当前项之前的项，当前曲目不变', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1), item(2), item(3)], startIndex: 2);

      await player.removeAt(0);

      expect(player.queue.map((t) => t.id).toList(), [2, 3]);
      expect(player.currentTrack!.id, 3);
      expect(player.index, 1);
    });

    test('删除当前项，下标落到下一个', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1), item(2), item(3)], startIndex: 1);

      await player.removeAt(1);

      expect(player.queue.map((t) => t.id).toList(), [1, 3]);
      expect(player.currentTrack!.id, 3);
      expect(player.index, 1);
    });

    test('删除末项且它是当前项时，落到新的末尾', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1), item(2)], startIndex: 1);

      await player.removeAt(1);

      expect(player.queue.map((t) => t.id).toList(), [1]);
      expect(player.currentTrack!.id, 1);
      expect(player.index, 0);
    });

    test('删除最后一项时停止并清空队列', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1)]);

      await player.removeAt(0);

      expect(player.queueLength, 0);
      expect(player.hasTrack, isFalse);
    });

    test('越界删除不动队列', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1)]);

      await player.removeAt(5);
      await player.removeAt(-1);

      expect(player.queueLength, 1);
    });

    test('拖动排序后当前曲目仍是同一首', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1), item(2), item(3)], startIndex: 1);

      player.reorder(2, 0); // 把第 3 首拖到最前

      expect(player.queue.map((t) => t.id).toList(), [3, 1, 2]);
      expect(player.currentTrack!.id, 2);
      expect(player.index, 2);
    });

    test('拖动到自身位置不动队列', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1), item(2), item(3)], startIndex: 0);

      player.reorder(1, 1); // 下标没变
      player.reorder(0, 0);

      expect(player.queue.map((t) => t.id).toList(), [1, 2, 3]);
      expect(player.index, 0);
    });

    test('往后拖动按移除后的下标落位，越界收到末尾', () async {
      final player = PlayerController();
      player.debugSeedQueue([item(1), item(2), item(3)], startIndex: 0);

      player.reorder(1, 2); // 第 2 首移到末尾
      expect(player.queue.map((t) => t.id).toList(), [1, 3, 2]);

      player.reorder(0, 99); // 越界收成末尾
      expect(player.queue.map((t) => t.id).toList(), [3, 2, 1]);
      expect(player.index, 2, reason: '当前曲目跟着新位置走');
      expect(player.currentTrack!.id, 1);
    });
  });

  group('播放速度（第 24.1 项）', () {
    test('钳制在 0.5 与 2.0 之间', () async {
      final player = PlayerController();

      await player.setSpeed(9);
      expect(player.speed, 2.0);

      await player.setSpeed(0.1);
      expect(player.speed, 0.5);

      await player.setSpeed(1.25);
      expect(player.speed, 1.25);
    });

    test('按 0.25 步进且不越界', () async {
      final player = PlayerController();

      await player.stepSpeed(1);
      expect(player.speed, 1.25);

      await player.stepSpeed(-2);
      expect(player.speed, 0.75);

      await player.setSpeed(2.0);
      await player.stepSpeed(1);
      expect(player.speed, 2.0);

      await player.setSpeed(0.5);
      await player.stepSpeed(-1);
      expect(player.speed, 0.5);
    });
  });

  group('模式回调（持久化钩子）', () {
    test('循环、随机、速度变化各触发一次，同值不重复触发', () async {
      final player = PlayerController();
      final modes = <RepeatMode>[];
      final shuffles = <bool>[];
      final speeds = <double>[];
      player.onRepeatModeChanged = modes.add;
      player.onShuffleChanged = shuffles.add;
      player.onSpeedChanged = speeds.add;

      player.setRepeatMode(RepeatMode.one);
      player.setRepeatMode(RepeatMode.one);
      player.setShuffle(true);
      player.setShuffle(true);
      await player.setSpeed(1.5);
      await player.setSpeed(1.5);

      expect(modes, [RepeatMode.one]);
      expect(shuffles, [true]);
      expect(speeds, [1.5]);
    });
  });

  group('收藏选段（第 24.3 节）', () {
    MediaSegment seg(int mediaId, int start, int end) => MediaSegment(
          mediaId: mediaId,
          startMs: start,
          endMs: end,
          createdAt: 0,
        );

    test('开启选区循环后记住这一段', () async {
      final player = PlayerController();
      player.debugSeedQueue(List.generate(3, item));

      expect(player.segmentLoopEnabled, isFalse);
      await player.setLoopSegment(seg(0, 1000, 3000));

      expect(player.segmentLoopEnabled, isTrue);
      expect(player.loopSegment!.startMs, 1000);
      expect(player.loopSegment!.endMs, 3000);
    });

    test('同一区间不重复通知，关闭后清空', () async {
      final player = PlayerController();
      player.debugSeedQueue(List.generate(3, item));
      var changes = 0;
      player.addListener(() => changes++);

      await player.setLoopSegment(seg(0, 1000, 3000));
      expect(changes, 1);
      await player.setLoopSegment(seg(0, 1000, 3000));
      expect(changes, 1, reason: '同一区间早退，不再通知');

      await player.setLoopSegment(null);
      expect(player.loopSegment, isNull);
      expect(changes, 2);
      await player.setLoopSegment(null);
      expect(changes, 2, reason: '本来就关着，不再通知');
    });

    test('换区间会更新选区', () async {
      final player = PlayerController();
      player.debugSeedQueue(List.generate(2, item));
      await player.setLoopSegment(seg(0, 0, 1000));
      await player.setLoopSegment(seg(0, 2000, 4000));
      expect(player.loopSegment!.startMs, 2000);
      expect(player.loopSegment!.endMs, 4000);
    });

    test('停止播放会清掉选区', () async {
      final player = PlayerController();
      player.debugSeedQueue(List.generate(2, item));
      await player.setLoopSegment(seg(0, 500, 1500));
      await player.stop();
      expect(player.loopSegment, isNull);
      expect(player.segmentLoopEnabled, isFalse);
    });

    test('未初始化时开关选区不触碰原生引擎', () async {
      final player = PlayerController();
      await player.setLoopSegment(seg(0, 0, 1000));
      await player.setLoopSegment(null);
      expect(player.initialized, isFalse);
      expect(player.loopSegment, isNull);
    });
  });
}
