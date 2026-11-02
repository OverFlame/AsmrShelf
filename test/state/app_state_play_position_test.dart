import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 续播与落盘：库里记着位置，播放中每前进 5 秒写一次，一首听完清零。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_playpos');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    state = AppState(player: PlayerController());
    await state.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// 建作品 + 卷（卷挂在这个临时目录上），放进一首音频并让 AppState 选中它。
  Future<TrackItem> seedTrack({
    int durationMs = 200000,
    int playPositionMs = 0,
  }) async {
    final workId = (await WorkDao(db).create('作品A')).id!;
    final folderId = (await FolderDao(db).create('专辑', workId: workId)).id!;
    await FolderDao(db).addPath(folderId, tmp.path);
    await TrackDao(db).insert(TrackItem(
      path: p.join(tmp.path, 'a.mp3'),
      filename: 'a.mp3',
      addedAt: 1,
      durationMs: durationMs,
      playPositionMs: playPositionMs,
    ));
    await state.enterFolder(folderId);
    return state.tracks.single;
  }

  Future<int> positionOf(int mediaId) async {
    final rows = await db.query('media',
        columns: ['play_position_ms'], where: 'id = ?', whereArgs: [mediaId]);
    return rows.single['play_position_ms'] as int;
  }

  /// 等落盘那条异步链跑完（库里写 + 内存刷新都在 then 里面）。
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

  test('续播问的是库里记的位置：太靠前、快听完、超出总时长都从头', () async {
    final track = await seedTrack(durationMs: 200000, playPositionMs: 83000);
    final resume = state.player.resumeFrom!;

    expect(resume(track), const Duration(seconds: 83));
    // 3 秒的进度等于没听过
    expect(resume(track.copyWith(playPositionMs: 3000)), Duration.zero);
    // 离结尾只剩 2 秒：一按播放就跳下一首，不如从头
    expect(resume(track.copyWith(playPositionMs: 198000)), Duration.zero);
    // 换了文件，老位置比新文件还长
    expect(resume(track.copyWith(playPositionMs: 300000)), Duration.zero);
    // 没播过
    expect(resume(track.copyWith(playPositionMs: 0)), Duration.zero);
  });

  test('播放位置每前进 5 秒落一次盘，磁贴上的已播时间跟着刷新', () async {
    final track = await seedTrack();
    expect(state.tracks.single.playPositionMs, 0);

    // 4 秒：还没到一个步长
    state.player.onPositionChanged!(track, const Duration(seconds: 4));
    await settle();
    expect(await positionOf(track.id!), 0);

    // 6 秒：写
    state.player.onPositionChanged!(track, const Duration(seconds: 6));
    await settle();
    expect(await positionOf(track.id!), 6000);
    expect(state.tracks.single.playPositionMs, 6000,
        reason: '磁贴右侧的已播时间要跟着位置走');

    // 8 秒：只前进 2 秒，不写
    state.player.onPositionChanged!(track, const Duration(seconds: 8));
    await settle();
    expect(await positionOf(track.id!), 6000);

    // 11 秒：又够一个步长
    state.player.onPositionChanged!(track, const Duration(seconds: 11));
    await settle();
    expect(await positionOf(track.id!), 11000);
    expect(state.tracks.single.playPositionMs, 11000);
  });

  test('往回拖之后库里很快追平，不会一直停在旧位置', () async {
    final track = await seedTrack(playPositionMs: 120000);

    // 拖回 3 秒：这一步不写，但基准要回退
    state.player.onPositionChanged!(track, const Duration(seconds: 3));
    await settle();
    expect(await positionOf(track.id!), 120000);

    state.player.onPositionChanged!(track, const Duration(seconds: 9));
    await settle();
    expect(await positionOf(track.id!), 9000);
  });

  test('一首播到结尾位置清零，下次从头播', () async {
    final track = await seedTrack(playPositionMs: 83000);

    state.player.onTrackCompleted!(track);
    await settle();

    expect(await positionOf(track.id!), 0);
    expect(state.tracks.single.playPositionMs, 0);
    expect(state.player.resumeFrom!(state.tracks.single), Duration.zero);
  });
}
