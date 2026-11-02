import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 多媒体栏里的音频专辑式播放：队列只装音频，按当前排序，且只装本目录这一层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory dir;
  late MediaDao mediaDao;
  late AppState app;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_audio_album');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    dir = await Directory(p.join(tmp.path, 'album')).create(recursive: true);
    mediaDao = MediaDao(DatabaseManager.instance.db);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<int> addRow(String name, MediaType type) async {
    return mediaDao.insertRow(MediaItem(
      path: p.join(dir.path, name),
      filename: name,
      mediaType: type,
      addedAt: 0,
    ).toMap());
  }

  test('本目录的音频按排序拍成队列，图片与视频不进来', () async {
    await addRow('03 - 尾曲.mp3', MediaType.audio);
    await addRow('封面.jpg', MediaType.image);
    await addRow('01 - 开场.mp3', MediaType.audio);
    await addRow('花絮.mp4', MediaType.video);
    await addRow('02 - 间奏.mp3', MediaType.audio);

    app = AppState(player: PlayerController());
    await app.init();

    final queue = await app.audioQueueInDir(dir.path);
    expect(queue.map((t) => t.filename).toList(),
        ['01 - 开场.mp3', '02 - 间奏.mp3', '03 - 尾曲.mp3'],
        reason: '专辑只装音频，顺序跟网格一致（自然序）');
  });

  test('起始位置：指定的那一首在队列里就用它，否则从头开始', () async {
    await addRow('a.mp3', MediaType.audio);
    final second = await addRow('b.mp3', MediaType.audio);
    await addRow('c.mp3', MediaType.audio);

    app = AppState(player: PlayerController());
    await app.init();
    final queue = await app.audioQueueInDir(dir.path);
    expect(queue.length, 3);

    expect(AppState.queueStartIndex(queue, null), 0);
    expect(AppState.queueStartIndex(queue, second), 1);
    expect(AppState.queueStartIndex(queue, 987654), 0,
        reason: '指定的行不在队列里就从头开始');
  });

  test('目录里一首音频都没有时不动播放器', () async {
    await addRow('只有图.jpg', MediaType.image);
    app = AppState(player: PlayerController());
    await app.init();

    // 引擎在本机测试环境里起不来，所以这条同时看住「空目录直接返回、不碰引擎」
    await app.playAudioInDir(dir.path);
    expect(app.player.currentTrack, isNull);
    expect(await app.audioQueueInDir(dir.path), isEmpty);
  });
}
