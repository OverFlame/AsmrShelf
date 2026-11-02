import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 多媒体栏与音频栏各自装填什么：两个栏目共用同一批 media 行，靠媒体类型分流。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory dir;
  late WorkDao workDao;
  late FolderDao folderDao;
  late MediaDao mediaDao;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_media_tab');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    dir = await Directory(p.join(tmp.path, 'mixed')).create(recursive: true);
    final db = DatabaseManager.instance.db;
    workDao = WorkDao(db);
    folderDao = FolderDao(db);
    mediaDao = MediaDao(db);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<void> addRow(String name, MediaType type) async {
    await mediaDao.insertRow(MediaItem(
      path: p.join(dir.path, name),
      filename: name,
      mediaType: type,
      addedAt: 0,
    ).toMap());
  }

  Future<(Work, VirtualFolder)> makeWork(String name, String library) async {
    final work = await workDao.create(name, library: library);
    final folder =
        await folderDao.create(name, workId: work.id, library: library);
    await folderDao.addPath(folder.id!, dir.path);
    return (work, folder);
  }

  test('多媒体栏装填本目录的全部类型，默认用 tag 反选掉字幕', () async {
    final (work, folder) = await makeWork('混合', 'media');
    await addRow('song.mp3', MediaType.audio);
    await addRow('shot.jpg', MediaType.image);
    await addRow('clip.mp4', MediaType.video);
    await addRow('song.srt', MediaType.subtitle);

    final app = AppState(player: PlayerController());
    await app.init();
    await app.enterWork(work.id!);
    await app.enterFolder(folder.id!);

    final names = app.images.map((i) => i.filename).toSet();
    expect(names, containsAll(<String>['song.mp3', 'shot.jpg', 'clip.mp4']),
        reason: '多媒体栏一次列出音频、图片、视频');
    expect(names, isNot(contains('song.srt')), reason: '字幕默认不进列表');
    expect(app.tracks, isEmpty, reason: '多媒体栏连音频也走 _images，不用 _tracks');
  });

  test('音频栏只看到音频行，同目录的图片与视频不进来', () async {
    final (work, folder) = await makeWork('曲库', 'audio');
    await addRow('song.mp3', MediaType.audio);
    await addRow('shot.jpg', MediaType.image);
    await addRow('clip.mp4', MediaType.video);

    final app = AppState(player: PlayerController());
    await app.init();
    await app.enterWork(work.id!);
    await app.enterFolder(folder.id!);

    expect(app.tracks.map((t) => t.filename).toList(), ['song.mp3']);
    expect(app.images, isEmpty);
  });

  test('多媒体栏里进音频作品的文件夹层，也能列出音频行', () async {
    final (work, folder) = await makeWork('曲库', 'audio');
    await addRow('song.mp3', MediaType.audio);
    await addRow('cover.jpg', MediaType.image);

    final app = AppState(player: PlayerController());
    await app.init();
    // 页签在多媒体栏：作品的库归属是 audio，中心区仍要按「所有类型」装填
    app.setBrowsingLibrary('media');
    await app.enterWork(work.id!);
    await app.enterFolder(folder.id!);

    expect(app.images.map((i) => i.filename).toSet(), {'song.mp3', 'cover.jpg'});
    expect(app.tracks, isEmpty);
  });

  test('音频栏里进音频作品的文件夹层，还是走曲目列表', () async {
    final (work, folder) = await makeWork('曲库', 'audio');
    await addRow('song.mp3', MediaType.audio);
    await addRow('cover.jpg', MediaType.image);

    final app = AppState(player: PlayerController());
    await app.init();
    app.setBrowsingLibrary('audio');
    await app.enterWork(work.id!);
    await app.enterFolder(folder.id!);

    expect(app.tracks.map((t) => t.filename).toList(), ['song.mp3']);
    expect(app.images, isEmpty);
  });

  test('用户改过排除集就不再套用默认的字幕排除', () async {
    final (work, folder) = await makeWork('混合', 'media');
    await addRow('song.mp3', MediaType.audio);
    await addRow('song.srt', MediaType.subtitle);
    await SettingsService.instance.setExcludedTagIds(const <int>[]);

    final app = AppState(player: PlayerController());
    await app.init();
    await app.enterWork(work.id!);
    await app.enterFolder(folder.id!);

    expect(app.images.map((i) => i.filename).toSet(),
        {'song.mp3', 'song.srt'},
        reason: '排除集空着就是「全都要」');
  });
}
