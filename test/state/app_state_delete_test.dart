import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';


/// 深度删除（deleteFolderDeep / deleteWorkDeep）的行为测试。
///
/// 用户口径：删除是「从软件数据里移除」，磁盘文件不动；同名目录如果也登记在
/// 别的库（专辑目录里的图片），那边的记录一起移除；删除前能问到条数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState state;
  late FolderDao folders;
  late MediaDao media;
  late WorkDao works;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_delete');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    final db = DatabaseManager.instance.db;
    folders = FolderDao(db);
    media = MediaDao(db);
    works = WorkDao(db);
    state = AppState(player: PlayerController());
    await state.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<void> addMedia(String path, MediaType type) async {
    final item = MediaItem(
      path: path,
      mediaType: type,
      ext: p.extension(path),
      nameLower: p.basename(path).toLowerCase(),
      filename: p.basename(path),
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await media.insertRow(item.toMap());
  }

  List<String> pathsOf(List<MediaItem> items) =>
      items.map((m) => m.path).toList()..sort();

  test('深度删除文件夹：子文件夹与其它库的记录一起移除，磁盘文件不动', () async {
    final albumDir = p.join(tmp.path, 'album');
    final subDir = p.join(albumDir, 'sub');
    await Directory(subDir).create(recursive: true);
    final mp3 = File(p.join(albumDir, '1.mp3'))..writeAsStringSync('a');
    final subMp3 = File(p.join(subDir, '2.mp3'))..writeAsStringSync('b');
    final cover = File(p.join(albumDir, 'cover.png'))..writeAsStringSync('c');

    final work = await works.create('专辑');
    final album = await folders.create('专辑', workId: work.id);
    await folders.addPath(album.id!, albumDir);
    final sub = await folders.create('子目录', parentId: album.id, workId: work.id);
    await folders.addPath(sub.id!, subDir);
    // 同一条物理目录也挂在图片库里
    final imageFolder =
        await folders.create('专辑图片', workId: null, library: 'media');
    await folders.addPath(imageFolder.id!, albumDir);

    await addMedia(mp3.path, MediaType.audio);
    await addMedia(subMp3.path, MediaType.audio);
    await addMedia(cover.path, MediaType.image);

    expect(await state.countMediaUnderFolder(album.id!), 3,
        reason: '曲目 2 条加图片 1 条，都要算进提醒的条数');

    // 查看器正看着这张封面，删除后要自动收起来
    final coverRow = (await media.queryByDirs([albumDir]))
        .firstWhere((m) => m.mediaType == MediaType.image);
    state.openViewer([coverRow], 0);

    final deleted = await state.deleteFolderDeep(album.id!);

    expect(deleted, 3);
    expect(await folders.getById(album.id!), isNull);
    expect(await folders.getById(sub.id!), isNull);
    expect(await folders.getById(imageFolder.id!), isNull,
        reason: '同目录的图片库文件夹记录一起移除，不能留下指向空目录的树节点');
    expect(await media.queryByDirs([tmp.path]), isEmpty);
    expect(state.showViewer, isFalse, reason: '查看器里的图已被删，不能继续显示');
    expect(
        mp3.existsSync() && subMp3.existsSync() && cover.existsSync(), isTrue,
        reason: '只动数据库，磁盘文件必须原样留着');
  });

  test('还有更外层的文件夹覆盖时，记录不算失联', () async {
    final root = p.join(tmp.path, 'lib');
    final albumDir = p.join(root, 'album');
    await Directory(albumDir).create(recursive: true);
    final keep = File(p.join(root, 'keep.mp3'))..writeAsStringSync('x');
    final inside = File(p.join(albumDir, '1.mp3'))..writeAsStringSync('y');

    final wide = await folders.create('曲库');
    await folders.addPath(wide.id!, root);
    final album = await folders.create('专辑');
    await folders.addPath(album.id!, albumDir);

    await addMedia(keep.path, MediaType.audio);
    await addMedia(inside.path, MediaType.audio);

    expect(await state.countMediaUnderFolder(album.id!), 0,
        reason: '曲库覆盖着整个目录，删专辑不会让任何记录失联');

    await state.deleteFolderDeep(album.id!);

    expect(pathsOf(await media.queryByDirs([root])), [inside.path, keep.path]);
    expect(await folders.getById(wide.id!), isNotNull,
        reason: '外层文件夹的路径不落在被删目录里，不能被吸收');

    // 再删掉唯一的覆盖者，两条记录才真的失联。
    expect(await state.countMediaUnderFolder(wide.id!), 2);
    expect(await state.deleteFolderDeep(wide.id!), 2);
    expect(await media.queryByDirs([root]), isEmpty);
  });

  test('深度删除作品：作品、文件夹与其中媒体一起走，不留未归类', () async {
    final w1Dir = p.join(tmp.path, 'w1');
    final w2Dir = p.join(tmp.path, 'w2');
    await Directory(w1Dir).create(recursive: true);
    await Directory(w2Dir).create(recursive: true);

    final w1 = await works.create('作品一');
    final w2 = await works.create('作品二');
    final f1 = await folders.create('一', workId: w1.id);
    await folders.addPath(f1.id!, w1Dir);
    final f2 = await folders.create('二', workId: w2.id);
    await folders.addPath(f2.id!, w2Dir);

    await addMedia(p.join(w1Dir, 'a.mp3'), MediaType.audio);
    await addMedia(p.join(w2Dir, 'b.mp3'), MediaType.audio);

    expect(await state.countMediaUnderWork(w1.id!), 1);

    final deleted = await state.deleteWorkDeep(w1.id!);

    expect(deleted, 1);
    final left = await works.listAll();
    expect(left.map((w) => w.id).toList(), [w2.id]);
    expect(await folders.getById(f1.id!), isNull);
    expect(await folders.listUnassignedRoots(library: 'audio'), isEmpty,
        reason: '旧 deleteWork 会把文件夹留成未归类，深度删除不该再有这种残留');
    expect(pathsOf(await media.queryByDirs([tmp.path])),
        [p.join(w2Dir, 'b.mp3')]);
  });

  test('深度删除文件夹后 mediaRevision 自增：作品层磁贴要靠它重查', () async {
    final dir = p.join(tmp.path, 'album');
    await Directory(dir).create(recursive: true);
    final work = await works.create('作品');
    final album = await folders.create('专辑', workId: work.id);
    await folders.addPath(album.id!, dir);
    await addMedia(p.join(dir, '1.jpg'), MediaType.image);

    final before = state.mediaRevision;
    final deleted = await state.deleteFolderDeep(album.id!);

    expect(deleted, 1);
    expect(state.mediaRevision, greaterThan(before),
        reason: '媒体行删了却不动代数，ImageGrid 的 _workItems 缓存不会失效，'
            '作品层已经查过的那些磁贴会留在界面上');
  });

  test('深度删除作品后 mediaRevision 自增', () async {
    final dir = p.join(tmp.path, 'w1');
    await Directory(dir).create(recursive: true);
    final w1 = await works.create('作品一');
    final f1 = await folders.create('一', workId: w1.id);
    await folders.addPath(f1.id!, dir);
    await addMedia(p.join(dir, 'a.jpg'), MediaType.image);

    final before = state.mediaRevision;
    final deleted = await state.deleteWorkDeep(w1.id!);

    expect(deleted, 1);
    expect(state.mediaRevision, greaterThan(before),
        reason: '与 deleteFolderDeep 同一个缺口，两条入口都要覆盖');
  });
}
