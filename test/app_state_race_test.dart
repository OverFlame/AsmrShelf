import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'support/test_env.dart';


/// 状态竞态的回归测试：标签连点、封面来源、最近播放重载、选中集合收窄。
///
/// 这些用例都按「旧实现必须失败」设计，改动前请确认能复现失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory media;
  late Database db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_race');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    media = await Directory(p.join(tmp.path, 'media')).create(recursive: true);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<void> settle([int ms = 600]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<int> addTrack({String path = '/m/1.mp3', String? coverPath}) async {
    return TrackDao(db).insert(TrackItem(
      path: path,
      filename: p.basename(path),
      coverPath: coverPath,
      addedAt: 0,
    ));
  }

  TrackItem item(int id, String path, {String? coverPath}) => TrackItem(
        id: id,
        path: path,
        filename: p.basename(path),
        coverPath: coverPath,
        addedAt: 0,
      );

  group('曲目标签切换（第 9 项）', () {
    test('连点两次同一标签：串行执行，内存与库都不留重复', () async {
      final trackId = await addTrack();
      final tagDao = TagDao(db);
      final tag = await tagDao.insert(const Tag(name: '纯音乐'));

      final state = AppState(player: PlayerController());
      // 先预热缓存：旧实现下缓存命中时两次点击会共享同一个 List 对象。
      expect(await state.getTrackTags(trackId), isEmpty);

      final first = state.toggleTagOnTrack(trackId, tag);
      final second = state.toggleTagOnTrack(trackId, tag);
      await Future.wait([first, second]);

      expect(await state.getTrackTags(trackId), isEmpty,
          reason: '两次切换应回到无标签，内存里不能留下重复项');
      expect(await tagDao.getTagsForTrack(trackId), isEmpty,
          reason: '数据库也应回到无标签');
    });

    test('单次切换：打开再关闭，内存与库始终一致', () async {
      final trackId = await addTrack();
      final tagDao = TagDao(db);
      final tag = await tagDao.insert(const Tag(name: '纯音乐'));

      final state = AppState(player: PlayerController());

      await state.toggleTagOnTrack(trackId, tag);
      expect((await state.getTrackTags(trackId)).map((t) => t.name), ['纯音乐']);
      expect((await tagDao.getTagsForTrack(trackId)).length, 1);

      await state.toggleTagOnTrack(trackId, tag);
      expect(await state.getTrackTags(trackId), isEmpty);
      expect(await tagDao.getTagsForTrack(trackId), isEmpty);
    });

    test('getTrackTags 返回不可变副本，调用方改不动缓存', () async {
      final trackId = await addTrack();
      final tag = await TagDao(db).insert(const Tag(name: '纯音乐'));
      final state = AppState(player: PlayerController());

      final miss = await state.getTrackTags(trackId);
      expect(() => miss.add(tag), throwsUnsupportedError,
          reason: '未命中缓存时拿到的也不能是可变列表');

      final hit = await state.getTrackTags(trackId); // 这次命中缓存
      expect(() => hit.add(tag), throwsUnsupportedError,
          reason: '命中缓存时不能把内部 List 交出去');
      expect(await state.getTrackTags(trackId), isEmpty,
          reason: '缓存不能被外部改动污染');
    });
  });

  group('播放封面来源（第 10、11 项）', () {
    late String coverA;
    late String coverB;
    late String coverTrack;
    late int workA;
    late int workB;
    late int trackId;

    Future<void> seed() async {
      coverA = p.join(tmp.path, 'coverA.png');
      coverB = p.join(tmp.path, 'coverB.png');
      coverTrack = p.join(tmp.path, 'coverTrack.png');
      for (final f in [coverA, coverB, coverTrack]) {
        await File(f).writeAsBytes(const [1, 2, 3]);
      }
      final workDao = WorkDao(db);
      workA = (await workDao.create('作品A', coverPath: coverA)).id!;
      workB = (await workDao.create('作品B', coverPath: coverB)).id!;
      trackId = await addTrack(coverPath: coverTrack);
    }

    test('播放中切去浏览别的作品，封面仍来自队列来源作品', () async {
      await seed();
      final state = AppState(player: PlayerController());
      final track = item(trackId, '/m/1.mp3', coverPath: coverTrack);

      await state.enterWork(workA);
      state.rememberQueueSource(); // 队列从作品 A 建立
      expect(state.playingWorkCover, coverA);

      await state.enterWork(workB); // 播放中用户去浏览作品 B
      expect(state.coverForTrack(track), coverA,
          reason: '封面应来自队列来源作品 A，不该被当前浏览的作品带跑');
    });

    test('没有队列来源封面时回退到曲目自己的封面', () async {
      await seed();
      final state = AppState(player: PlayerController());
      final track = item(trackId, '/m/1.mp3', coverPath: coverTrack);

      await state.enterWork(workB);
      expect(state.coverForTrack(track), coverTrack,
          reason: '没有队列来源时应回退到曲目自身封面');
    });
  });

  group('最近播放重载（第 12 项）', () {
    test('快速切歌：只有最后一次重载写回并通知', () async {
      final t1 = await addTrack(path: '/m/a1.mp3');
      final t2 = await addTrack(path: '/m/a2.mp3');
      final t3 = await addTrack(path: '/m/a3.mp3');

      final state = AppState(player: PlayerController());
      await state.init();
      await settle(300);

      var notifications = 0;
      state.addListener(() => notifications++);

      state.player.onTrackStarted!(item(t1, '/m/a1.mp3'));
      state.player.onTrackStarted!(item(t2, '/m/a2.mp3'));
      state.player.onTrackStarted!(item(t3, '/m/a3.mp3'));
      await settle();

      expect(state.recentTracks.length, 3, reason: '三次切歌都应记进播放历史');
      expect(notifications, lessThan(3),
          reason: '三次快速切歌只应有最后一次重载写回，实际通知 $notifications 次');
    });
  });

  group('选中集合随上下文收窄（第 13 项）', () {
    test('切到别的作品后，选中集合不再保留看不见的曲目', () async {
      final workDao = WorkDao(db);
      final folderDao = FolderDao(db);
      final workA = (await workDao.create('作品A')).id!;
      final workB = (await workDao.create('作品B')).id!;

      final dirA = await Directory(p.join(media.path, 'A')).create();
      final dirB = await Directory(p.join(media.path, 'B')).create();
      final fA = await folderDao.create('文件夹A', workId: workA);
      final fB = await folderDao.create('文件夹B', workId: workB);
      await folderDao.addPath(fA.id!, dirA.path);
      await folderDao.addPath(fB.id!, dirB.path);
      final a1 = await addTrack(path: p.join(dirA.path, '1.mp3'));

      final state = AppState(player: PlayerController());
      await state.enterWork(workA);
      await state.enterFolder(fA.id!);
      expect(state.tracks.map((t) => t.id), contains(a1),
          reason: '进入文件夹 A 应看到里面的曲目');

      state.toggleTrackSelect(a1);
      expect(state.selectedTrackIds, contains(a1));

      await state.enterWork(workB);
      await state.enterFolder(fB.id!);
      expect(state.selectedTrackIds, isEmpty,
          reason: '切到作品 B 后不能还留着作品 A 的选中曲目');
    });
  });
}
