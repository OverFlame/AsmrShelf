import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/cover_service.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';

import 'support/id3.dart';
import 'support/test_env.dart';


/// 封面缓存回归测试（报告第 21 项）。
///
/// 旧实现三个问题：清理缓存时不区分「正在使用的封面」，谁最旧删谁；
/// 写内嵌封面与导入封面直接覆盖目标文件，写一半被读到就是半个图片；
/// 作品封面直接指向 track_ 缓存文件，缓存一清作品封面就消失。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_cover');
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

  Future<Directory> covers() async => Directory(await CoverService.coversDir());

  Future<List<String>> coversNames() async =>
      (await covers()).listSync().map((e) => p.basename(e.path)).toList()
        ..sort();

  test('清理封面缓存时不删正在使用的封面', () async {
    final dir = (await covers()).path;
    final playing = File(p.join(dir, 'track_1.jpg'))
      ..writeAsBytesSync(List.filled(100, 1));
    final second = File(p.join(dir, 'track_2.jpg'))
      ..writeAsBytesSync(List.filled(100, 2));
    final third = File(p.join(dir, 'track_3.jpg'))
      ..writeAsBytesSync(List.filled(100, 3));
    // 让 1 最旧：没有 keep 的话它是最先被删的那个
    playing.setLastModifiedSync(DateTime(2020));
    second.setLastModifiedSync(DateTime(2021));
    third.setLastModifiedSync(DateTime(2022));

    await CoverService.enforceLimit(150, keep: {playing.path});

    expect(playing.existsSync(), isTrue, reason: '正在播放的封面不能被清理掉');
    expect(second.existsSync(), isFalse);
    expect(third.existsSync(), isFalse);
  });

  test('写入内嵌封面没有临时文件残留，内容完整', () async {
    final bytes = Uint8List.fromList(List.generate(64, (i) => i));

    final path = await CoverService.writeEmbedded(1, bytes, 'image/png');

    expect(path, endsWith('track_1.png'));
    expect(File(path!).readAsBytesSync(), bytes);
    expect(await coversNames(), ['track_1.png']);
  });

  test('重复写同一个曲目的封面不会留下半个文件', () async {
    final first = Uint8List.fromList(List.filled(10, 1));
    final second = Uint8List.fromList(List.filled(20, 2));

    await CoverService.writeEmbedded(7, first, 'image/jpeg');
    final path = await CoverService.writeEmbedded(7, second, 'image/jpeg');

    expect(File(path!).readAsBytesSync(), second);
    expect(await coversNames(), ['track_7.jpg']);
  });

  test('作品封面走 work_ 前缀，清理内嵌缓存后还在', () async {
    final src = File(p.join(tmp.path, 'src.jpg'))
      ..writeAsBytesSync(List.filled(32, 9));

    final path = await CoverService.importCover(src.path, 7);
    await CoverService.clearEmbeddedCache();

    expect(p.basename(path!), startsWith('work_7'));
    expect(File(path).existsSync(), isTrue, reason: '作品封面不在内嵌缓存里');
  });

  test('导入内嵌封面时另存 work_ 副本，清理缓存后作品封面还在', () async {
    final work = await state.createWork('专辑');
    final album = Directory(p.join(tmp.path, 'album'))
      ..createSync(recursive: true);
    File(p.join(album.path, 'a.mp3'))
        .writeAsBytesSync(mp3WithEmbeddedCover(List.filled(8, 7)));

    await state.importDirectoryIntoWork(album.path, work.id!);

    final saved = await WorkDao(db).getById(work.id!);
    expect(saved!.coverPath, isNotNull);
    expect(p.basename(saved.coverPath!), startsWith('work_${work.id}'),
        reason: '作品封面不能指向会被清理的 track_ 缓存');

    await state.clearCoverCache();

    expect(File(saved.coverPath!).existsSync(), isTrue);
  });
}
