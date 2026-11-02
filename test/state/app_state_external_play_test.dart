import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/video_launcher.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 外链播放推给系统的那份播放列表里装什么：按作品/卷的库归属选类型。
///
/// 图片与视频合并成多媒体栏之后，多媒体作品推的是视频；音频作品推的是音频。
class _FakeProcess implements Process {
  @override
  Future<int> get exitCode => Future<int>.value(0);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory dir;
  late WorkDao workDao;
  late FolderDao folderDao;
  late MediaDao mediaDao;
  late List<List<String>> calls;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_external');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    dir = await Directory(p.join(tmp.path, 'media')).create(recursive: true);
    final db = DatabaseManager.instance.db;
    workDao = WorkDao(db);
    folderDao = FolderDao(db);
    mediaDao = MediaDao(db);
    calls = [];
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  AppState buildApp() => AppState(
        player: PlayerController(),
        videoLauncher: VideoLauncher(
          os: 'linux',
          start: (String exe, List<String> args) async {
            calls.add(<String>[exe, ...args]);
            return _FakeProcess();
          },
        ),
      );

  Future<void> addRow(String name, MediaType type, {int? durationMs}) async {
    await mediaDao.insertRow(MediaItem(
      path: p.join(dir.path, name),
      filename: name,
      mediaType: type,
      addedAt: 0,
      durationMs: durationMs,
    ).toMap());
  }

  Future<String> writtenList() =>
      File(calls.single[1]).readAsString();

  test('多媒体作品的外链只推视频，图片与音频不进去', () async {
    final work = await workDao.create('剧集', library: 'media');
    final folder =
        await folderDao.create('剧集', workId: work.id, library: 'media');
    await folderDao.addPath(folder.id!, dir.path);
    await addRow('01.mp4', MediaType.video, durationMs: 1454999);
    await addRow('封面.jpg', MediaType.image);
    await addRow('插曲.mp3', MediaType.audio, durationMs: 200000);

    final app = buildApp();
    await app.init();

    expect(await app.playWorkExternal(work.id!), LaunchResult.ok);
    expect(calls.single.first, 'xdg-open');
    final list = await writtenList();
    expect(list, contains('01.mp4'));
    expect(list, isNot(contains('封面.jpg')), reason: '图片不进播放列表');
    expect(list, isNot(contains('插曲.mp3')), reason: '音频不进播放列表');
  });

  test('音频作品的外链只推音频', () async {
    final work = await workDao.create('专辑', library: 'audio');
    final folder = await folderDao.create('专辑', workId: work.id);
    await folderDao.addPath(folder.id!, dir.path);
    await addRow('01.mp3', MediaType.audio, durationMs: 83000);
    await addRow('02.mp3', MediaType.audio);

    final app = buildApp();
    await app.init();

    expect(await app.playWorkExternal(work.id!), LaunchResult.ok);
    final list = await writtenList();
    expect(list, contains('01.mp3'));
    expect(list, contains('02.mp3'));
  });

  test('作品里一行该类型的媒体都没有时直接算失败，不拉播放器', () async {
    final work = await workDao.create('空多媒体', library: 'media');
    final folder = await folderDao.create('空多媒体',
        workId: work.id, library: 'media');
    await folderDao.addPath(folder.id!, dir.path);
    await addRow('只有图.jpg', MediaType.image);

    final app = buildApp();
    await app.init();

    expect(await app.playWorkExternal(work.id!), LaunchResult.failed);
    expect(calls, isEmpty, reason: '没有视频就不该拉播放器，也不该退回图片');
  });
}
