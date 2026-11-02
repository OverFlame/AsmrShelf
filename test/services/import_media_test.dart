import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/file_scanner.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';


/// 图片与视频的导入通道（阶段 4 C 批补齐的缺口）。
///
/// 改动前 `ScanResult` 只有音频/字幕/封面，`importDirectory` 遇到无音频目录
/// 直接返回 null，图片库里永远没有 `media_type='image'` 的行。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_media');
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

  Future<List<Map<String, Object?>>> mediaRows(String type) => db.query(
        'media',
        where: 'media_type = ?',
        whereArgs: [type],
        // 与 MediaDao.naturalOrderBy 同一条表达式：自然排序键优先。
        orderBy: "(CASE WHEN sort_key IS NULL OR sort_key = '' THEN filename "
            'ELSE sort_key END) COLLATE NOCASE, filename COLLATE NOCASE',
      );

  test('混合目录一次遍历分出音频、图片、视频与字幕', () async {
    final dir = await Directory(p.join(tmp.path, 'mixed')).create();
    File(p.join(dir.path, 'a.mp3')).writeAsBytesSync(List.filled(4, 0));
    File(p.join(dir.path, 'b.png')).writeAsBytesSync(List.filled(4, 0));
    File(p.join(dir.path, 'c.jpg')).writeAsBytesSync(List.filled(4, 0));
    File(p.join(dir.path, 'd.mp4')).writeAsBytesSync(List.filled(4, 0));
    File(p.join(dir.path, 'a.vtt')).writeAsStringSync('WEBVTT');

    final scan = await FileScanner.scanDirectory(dir.path);

    expect(scan.audioPaths.map(p.basename).toList(), ['a.mp3']);
    expect(scan.imagePaths.map(p.basename).toList(), ['b.png', 'c.jpg']);
    expect(scan.videoPaths.map(p.basename).toList(), ['d.mp4']);
    expect(scan.coverFiles, isEmpty);
    expect(scan.visualCount, 3);
    expect(scan.isEmpty, isFalse);
    final subtitles = scan.subtitleByAudio[p.join(dir.path, 'a.mp3')];
    expect(subtitles?.map(p.basename).toList(), ['a.vtt']);
  });

  test('封面图同时进封面列表与图片列表，空目录判为空', () async {
    final dir = await Directory(p.join(tmp.path, 'album')).create();
    File(p.join(dir.path, 'cover.png')).writeAsBytesSync(List.filled(4, 0));

    final scan = await FileScanner.scanDirectory(dir.path);

    expect(scan.coverFiles.map(p.basename).toList(), ['cover.png']);
    expect(scan.imagePaths.map(p.basename).toList(), ['cover.png']);

    final empty = await Directory(p.join(tmp.path, 'empty')).create();
    final none = await FileScanner.scanDirectory(empty.path);
    expect(none.isEmpty, isTrue);
  });

  test('纯图片目录按 library 导入：行落库、字段正确、挂上图片库文件夹', () async {
    final dir = await Directory(p.join(tmp.path, '相册')).create();
    final one = File(p.join(dir.path, '第10话.png'))
      ..writeAsBytesSync(List.filled(9, 0));
    File(p.join(dir.path, '第2话.png')).writeAsBytesSync(List.filled(5, 0));

    final work = await state.importDirectory(dir.path, library: 'media');

    expect(work, isNotNull);
    expect(work!.library, 'media');
    final rows = await mediaRows('image');
    expect(rows, hasLength(2));
    final first = rows.firstWhere((r) => r['filename'] == '第10话.png');
    expect(first['media_type'], 'image');
    expect(first['ext'], '.png');
    expect(first['name_lower'], one.path.toLowerCase());
    expect(first['file_size'], 9);
    expect(first['added_at'], isA<int>());
    expect(first['width'], isNull);
    expect(first['height'], isNull);
    // 自然排序键：第 2 话要排在第 10 话前面
    expect(rows.map((r) => r['filename']).toList(), ['第2话.png', '第10话.png']);
    expect(first['sort_key'], isNotNull);

    final folders = await db.query('folders', where: 'work_id = ?', whereArgs: [work.id]);
    expect(folders, hasLength(1));
    expect(folders.first['library'], 'media');
    final paths = await db.query('folder_paths',
        where: 'folder_id = ?', whereArgs: [folders.first['id']]);
    expect(paths.map((r) => r['path']).toList(), [dir.path]);
  });

  test('不带 library 的纯图片目录按扫描结果推断为图片库', () async {
    final dir = await Directory(p.join(tmp.path, 'pics')).create();
    File(p.join(dir.path, 'x.webp')).writeAsBytesSync(List.filled(3, 0));

    final work = await state.importDirectory(dir.path);

    expect(work, isNotNull);
    expect(work!.library, 'media');
    expect(await mediaRows('image'), hasLength(1));
  });

  test('纯视频目录落 media_type=video', () async {
    final dir = await Directory(p.join(tmp.path, '番剧')).create();
    File(p.join(dir.path, '01.mkv')).writeAsBytesSync(List.filled(3, 0));
    File(p.join(dir.path, '02.mp4')).writeAsBytesSync(List.filled(3, 0));

    final work = await state.importDirectory(dir.path);

    expect(work, isNotNull);
    expect(work!.library, 'media');
    final rows = await mediaRows('video');
    expect(rows.map((r) => r['filename']).toList(), ['01.mkv', '02.mp4']);
    expect(rows.every((r) => r['duration_ms'] == null), isTrue);
    expect(await mediaRows('image'), isEmpty);
  });

  test('重复导入同一目录不产生重复行，第二次返回 null', () async {
    final dir = await Directory(p.join(tmp.path, 'again')).create();
    File(p.join(dir.path, 'a.png')).writeAsBytesSync(List.filled(3, 0));

    final first = await state.importDirectory(dir.path);
    final second = await state.importDirectory(dir.path);

    expect(first, isNotNull);
    expect(second, isNull);
    expect(await mediaRows('image'), hasLength(1));
    expect(await db.query('works'), hasLength(1));
  });

  test('导入到已存在的图片作品：只加行，不新建作品', () async {
    final dir = await Directory(p.join(tmp.path, 'album1')).create();
    File(p.join(dir.path, 'a.png')).writeAsBytesSync(List.filled(3, 0));
    final work = await state.importDirectory(dir.path);
    expect(work, isNotNull);

    final dir2 = await Directory(p.join(tmp.path, 'album2')).create();
    File(p.join(dir2.path, 'b.png')).writeAsBytesSync(List.filled(3, 0));
    await state.importDirectoryIntoWork(dir2.path, work!.id!);

    expect(await db.query('works'), hasLength(1));
    expect(await mediaRows('image'), hasLength(2));
    final folders = await db.query('folders', where: 'work_id = ?', whereArgs: [work.id]);
    expect(folders, hasLength(2));
  });

  test('混合目录仍按音频导入，不往图片库塞行', () async {
    final dir = await Directory(p.join(tmp.path, 'mixed2')).create();
    File(p.join(dir.path, 'a.mp3')).writeAsBytesSync(List.filled(4, 0));
    File(p.join(dir.path, 'cover.png')).writeAsBytesSync(List.filled(4, 0));

    final work = await state.importDirectory(dir.path);

    expect(work, isNotNull);
    expect(work!.library, 'audio');
    expect(await db.query('tracks'), hasLength(1));
    expect(await mediaRows('image'), isEmpty);
  });

  test('目录里没有可导入的媒体时不建作品', () async {
    final dir = await Directory(p.join(tmp.path, 'nothing')).create();
    File(p.join(dir.path, 'readme.txt')).writeAsStringSync('hello');

    final work = await state.importDirectory(dir.path);

    expect(work, isNull);
    expect(await db.query('works'), isEmpty);
    expect(await db.query('media'), isEmpty);
  });
}
