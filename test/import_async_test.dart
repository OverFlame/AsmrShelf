import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/file_scanner.dart';
import 'package:asmrshelf/services/metadata_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';

import 'support/id3.dart';
import 'support/test_env.dart';


/// 导入不占用调用方 isolate（报告第 25 项）。
///
/// 旧实现把这些都留在界面 isolate 上同步跑：目录递归遍历、每个文件的
/// `lastModifiedSync()`、整块读文件并解码内嵌封面的 `MetadataService.read`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_async');
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

  test('批量解析元数据在单独 isolate 上跑，内嵌封面能传回来', () async {
    final dir =
        await Directory(p.join(tmp.path, 'album')).create(recursive: true);
    final file = File(p.join(dir.path, 'a.mp3'))
      ..writeAsBytesSync(mp3WithEmbeddedCover(List.filled(8, 7)));

    MetadataService.debugParsedOnCallerIsolate = false;
    final metas = await MetadataService.readAll([file.path]);

    expect(MetadataService.debugParsedOnCallerIsolate, isFalse,
        reason: '解析要跑在单独 isolate 上，不能占着调用方');
    expect(metas, hasLength(1));
    expect(metas.first.pictureBytes, hasLength(8));
    expect(metas.first.pictureMimetype, 'image/jpeg');
  });

  test('空列表不进 isolate', () async {
    MetadataService.debugParsedOnCallerIsolate = false;
    expect(await MetadataService.readAll(const []), isEmpty);
    expect(MetadataService.debugParsedOnCallerIsolate, isFalse);
  });

  test('目录扫描在单独 isolate 上跑，字幕匹配照旧', () async {
    final dir =
        await Directory(p.join(tmp.path, 'album')).create(recursive: true);
    File(p.join(dir.path, 'a.mp3')).writeAsBytesSync(List.filled(4, 0));
    File(p.join(dir.path, 'a.vtt')).writeAsStringSync('WEBVTT');
    await Directory(p.join(dir.path, 'sub')).create();
    File(p.join(dir.path, 'sub', 'c.mp3')).writeAsBytesSync(List.filled(4, 0));

    FileScanner.debugScannedOnCallerIsolate = false;
    final scan = await FileScanner.scanDirectoryOffThread(dir.path);

    expect(FileScanner.debugScannedOnCallerIsolate, isFalse,
        reason: '遍历要跑在单独 isolate 上');
    expect(scan.audioPaths.map(p.basename).toList(), ['a.mp3', 'c.mp3']);
    final subtitles = scan.subtitleByAudio[p.join(dir.path, 'a.mp3')];
    expect(subtitles?.map(p.basename).toList(), ['a.vtt']);
  });

  test('导入整条路径都不占用调用方 isolate，封面照样落库', () async {
    final dir =
        await Directory(p.join(tmp.path, 'album')).create(recursive: true);
    File(p.join(dir.path, 'a.mp3'))
        .writeAsBytesSync(mp3WithEmbeddedCover(List.filled(8, 7)));

    MetadataService.debugParsedOnCallerIsolate = false;
    FileScanner.debugScannedOnCallerIsolate = false;

    final work = await state.importDirectory(dir.path);

    expect(work, isNotNull);
    expect(FileScanner.debugScannedOnCallerIsolate, isFalse);
    expect(MetadataService.debugParsedOnCallerIsolate, isFalse);
    final rows = await db.query('tracks');
    expect(rows, hasLength(1));
    expect(rows.first['cover_path'], isNotNull,
        reason: '内嵌封面要能跨 isolate 传回来并落库');
  });
}
