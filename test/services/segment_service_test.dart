import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/segment_service.dart';
import '../support/test_env.dart';


/// 收藏选段的服务层测试（BUILD_GUIDE 第 24.3 节）。
///
/// 覆盖起止换算、越界收口、循环优先级、落库读取与级联删除。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late SegmentService svc;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_segment');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    svc = SegmentService(db);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<int> addMedia(String path) => db.insert('media', {
        'path': path,
        'media_type': 'audio',
        'filename': p.basename(path),
        'added_at': 1,
      });

  group('起止换算', () {
    test('区间合法时原样返回', () {
      expect(SegmentService.normalizeRange(1000, 5000, 10000),
          (startMs: 1000, endMs: 5000));
    });

    test('两端越界时收口到曲目时长内', () {
      expect(SegmentService.normalizeRange(-100, 99999, 10000),
          (startMs: 0, endMs: 10000));
    });

    test('长度不足最小段时往后扩', () {
      expect(SegmentService.normalizeRange(3000, 3100, 10000),
          (startMs: 3000, endMs: 3200));
    });

    test('末尾不够就往前缩', () {
      expect(SegmentService.normalizeRange(9900, 10000, 10000),
          (startMs: 9800, endMs: 10000));
    });

    test('时长未知时给出空区间', () {
      expect(SegmentService.normalizeRange(0, 0, 0), (startMs: 0, endMs: 0));
      expect(SegmentService.normalizeRange(500, 900, -1),
          (startMs: 0, endMs: 0));
    });

    test('曲目比最小段还短时整曲成段', () {
      expect(SegmentService.normalizeRange(0, 0, 100),
          (startMs: 0, endMs: 100));
    });

    test('合法性只看长度是否为正', () {
      expect(SegmentService.isValidRange(0, 1), isTrue);
      expect(SegmentService.isValidRange(5, 5), isFalse);
      expect(SegmentService.isValidRange(900, 100), isFalse);
    });
  });

  group('循环优先级', () {
    test('选段循环压过整曲循环', () {
      expect(
          SegmentService.policyOf(
              segmentLoop: true, repeatOne: true, repeatAll: true),
          PlaybackPolicy.repeatSegment);
    });

    test('单曲循环排在顺序循环之前', () {
      expect(
          SegmentService.policyOf(
              segmentLoop: false, repeatOne: true, repeatAll: true),
          PlaybackPolicy.repeatTrack);
    });

    test('只开顺序循环时推进下一首', () {
      expect(
          SegmentService.policyOf(
              segmentLoop: false, repeatOne: false, repeatAll: true),
          PlaybackPolicy.advance);
    });

    test('都不开时播完停止', () {
      expect(
          SegmentService.policyOf(
              segmentLoop: false, repeatOne: false, repeatAll: false),
          PlaybackPolicy.finish);
    });
  });

  group('落库与读取', () {
    test('新增时按曲目时长收口，读取按起点升序', () async {
      final mediaId = await addMedia('/m/a.mp3');
      await svc.add(
          mediaId: mediaId,
          startMs: 8000,
          endMs: 9000,
          durationMs: 10000,
          name: '后半段');
      await svc.add(
          mediaId: mediaId,
          startMs: -50,
          endMs: 100,
          durationMs: 10000,
          name: '开头');

      final list = await svc.listByMedia(mediaId);
      expect(list.length, 2);
      expect(list.first.name, '开头');
      expect(list.first.startMs, 0);
      expect(list.first.endMs, 200);
      expect(list.last.startMs, 8000);
      expect(list.last.endMs, 9000);
    });

    test('不传时长时按传入值落库，空白名字收成 null', () async {
      final mediaId = await addMedia('/m/b.mp3');
      final seg = await svc.add(
          mediaId: mediaId, startMs: 1000, endMs: 2000, name: '   ');
      expect(seg.name, isNull);
      expect(seg.label, '未命名选段');
      expect(seg.length, const Duration(milliseconds: 1000));

      final again = await svc.getById(seg.id!);
      expect(again, isNotNull);
      expect(again!.name, isNull);
      expect(again, seg);
    });

    test('重命名只在名字上动手', () async {
      final mediaId = await addMedia('/m/c.mp3');
      final seg =
          await svc.add(mediaId: mediaId, startMs: 0, endMs: 500, name: '旧名');
      await svc.rename(seg.id!, '新名');
      final got = await svc.getById(seg.id!);
      expect(got!.name, '新名');
      expect(got.startMs, 0);
      expect(got.endMs, 500);
    });

    test('删除一段不影响同轨其它段', () async {
      final mediaId = await addMedia('/m/d.mp3');
      final a =
          await svc.add(mediaId: mediaId, startMs: 0, endMs: 500, name: '甲');
      await svc.add(mediaId: mediaId, startMs: 600, endMs: 900, name: '乙');
      await svc.remove(a.id!);
      final list = await svc.listByMedia(mediaId);
      expect(list.length, 1);
      expect(list.single.name, '乙');
    });

    test('removeForMedia 只清这一轨', () async {
      final one = await addMedia('/m/e.mp3');
      final two = await addMedia('/m/f.mp3');
      await svc.add(mediaId: one, startMs: 0, endMs: 500);
      await svc.add(mediaId: two, startMs: 0, endMs: 500);
      await svc.removeForMedia(one);
      expect(await svc.listByMedia(one), isEmpty);
      expect((await svc.listByMedia(two)).length, 1);
    });

    test('删除曲目时选段跟着级联删除', () async {
      final mediaId = await addMedia('/m/g.mp3');
      await svc.add(mediaId: mediaId, startMs: 0, endMs: 500);
      await db.delete('media', where: 'id = ?', whereArgs: [mediaId]);
      expect(await svc.listByMedia(mediaId), isEmpty);
    });

    test('查不到的 id 返回 null', () async {
      expect(await svc.getById(4321), isNull);
    });
  });

  group('MediaSegment 值语义', () {
    const seg = MediaSegment(
        id: 1, mediaId: 2, startMs: 100, endMs: 600, name: '甲', createdAt: 9);

    test('长度与默认名', () {
      expect(seg.length, const Duration(milliseconds: 500));
      expect(seg.start, const Duration(milliseconds: 100));
      expect(seg.end, const Duration(milliseconds: 600));
      expect(seg.label, '甲');
      expect(
          const MediaSegment(
                  mediaId: 2, startMs: 0, endMs: 1, createdAt: 0)
              .label,
          '未命名选段');
    });

    test('copyWith 只改指定字段', () {
      final next = seg.copyWith(name: '乙', endMs: 900);
      expect(next.name, '乙');
      expect(next.endMs, 900);
      expect(next.id, 1);
      expect(next.mediaId, 2);
      expect(next.startMs, 100);
      expect(next.createdAt, 9);
    });

    test('字段相同则相等且哈希一致', () {
      const same = MediaSegment(
          id: 1, mediaId: 2, startMs: 100, endMs: 600, name: '甲', createdAt: 9);
      expect(seg, same);
      expect(seg.hashCode, same.hashCode);
      expect(seg == seg.copyWith(endMs: 700), isFalse);
    });
  });
}
