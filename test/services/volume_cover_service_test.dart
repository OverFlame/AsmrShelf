import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/volume_cover_service.dart';
import 'package:asmrshelf/utils/crop_math.dart';
import '../support/test_env.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late Set<String> existing;
  late VolumeCoverService service;

  Future<int> insertWork(String name, {String? coverPath}) => db.insert(
        'works',
        <String, Object?>{
          'name': name,
          'library': 'media',
          'cover_path': coverPath,
          'created_at': 1,
        },
      );

  Future<int> insertFolder(
    String name, {
    int? parent,
    int? workId,
  }) =>
      db.insert('folders', <String, Object?>{
        'name': name,
        'library': 'media',
        'parent': parent,
        'work_id': workId,
      });

  Future<void> mountPath(int folderId, String dir) => db.insert(
        'folder_paths',
        <String, Object?>{'folder_id': folderId, 'path': dir},
      );

  Future<int> insertImage(String path) => db.insert('media', <String, Object?>{
        'path': path,
        'media_type': 'image',
        'filename': p.basename(path),
        'added_at': 1,
      });

  Future<int> insertAudio(
    String path, {
    String? coverPath,
    String? sortKey,
  }) =>
      db.insert('media', <String, Object?>{
        'path': path,
        'media_type': 'audio',
        'filename': p.basename(path),
        'added_at': 1,
        'cover_path': coverPath,
        'sort_key': sortKey,
      });

  /// 登记一个「磁盘上存在」的路径，并返回它
  String img(String name) {
    final path = p.join(tmp.path, name);
    existing.add(path);
    return path;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_volume_cover');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    existing = <String>{};
    service = VolumeCoverService(db, fileExists: existing.contains);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('白名单判定', () {
    test('认七个名字的图片', () {
      for (final name in VolumeCoverService.coverFileNames) {
        expect(VolumeCoverService.isWhitelistCoverPath('/x/$name.jpg'), isTrue,
            reason: name);
        expect(VolumeCoverService.isWhitelistCoverPath('/x/${name.toUpperCase()}.PNG'),
            isTrue);
      }
    });

    test('名字或扩展名不在白名单就不算', () {
      expect(VolumeCoverService.isWhitelistCoverPath('/x/a.jpg'), isFalse);
      expect(VolumeCoverService.isWhitelistCoverPath('/x/cover.gif'), isFalse);
      expect(VolumeCoverService.isWhitelistCoverPath('/x/cover.jpg.txt'), isFalse);
      expect(VolumeCoverService.isWhitelistCoverPath('/x/cover'), isFalse);
    });

    test('认另一种分隔符的路径', () {
      // 目录名与分隔符不该影响白名单判定：Windows 上建的库搬到 Linux 后，
      // 路径里是反斜杠，p.basenameWithoutExtension 会把整条路径当成文件名。
      expect(VolumeCoverService.isWhitelistCoverPath(r'D:\Music\cover.jpg'),
          isTrue);
      expect(VolumeCoverService.isWhitelistCoverPath(r'D:\Music\COVER.PNG'),
          isTrue);
      expect(VolumeCoverService.isWhitelistCoverPath(r'D:\Music\a.jpg'),
          isFalse);
    });
  });

  group('候选四级优先级', () {
    late int volume;

    setUp(() async {
      final work = await insertWork('series', coverPath: img('series.jpg'));
      volume = await insertFolder('vol', workId: work);
      await mountPath(volume, p.join(tmp.path, 'vol'));
      // 子树里的图片
      await insertImage(img('vol/a.png'));
      await insertImage(img('vol/b.jpg'));
      await insertImage(img('vol/cover.png'));
      // 卷外图片：不该被收进来
      await insertImage(img('outside.png'));
      await insertImage(img('vol2/c.png'));
      // 曲目内嵌封面：按 sort_key 排序
      await insertAudio(p.join(tmp.path, 'vol/track2.mp3'),
          coverPath: img('cache/c2.jpg'), sortKey: '2');
      await insertAudio(p.join(tmp.path, 'vol/track1.mp3'),
          coverPath: img('cache/c1.jpg'), sortKey: '1');
      existing.add(p.join(tmp.path, 'vol2/c.png'));
      existing.add(p.join(tmp.path, 'outside.png'));
    });

    test('四级顺序：白名单 → 字典序第一张 → 曲目内嵌 → 系列', () async {
      final candidates = await service.listCandidates(volume);

      expect(candidates.map((c) => c.source).toList(), <VolumeCoverSource>[
        VolumeCoverSource.whitelistImage,
        VolumeCoverSource.lexicalImage,
        VolumeCoverSource.trackEmbedded,
        VolumeCoverSource.seriesCover,
      ]);
      expect(candidates.map((c) => p.basename(c.path)).toList(),
          <String>['cover.png', 'a.png', 'c1.jpg', 'series.jpg']);
      expect(candidates.map((c) => c.priority).toList(), <int>[1, 2, 3, 4]);
    });

    test('resolve 取最优先的一条，effectiveCover 没手动指定时取同一条', () async {
      expect(p.basename((await service.resolve(volume))!.path), 'cover.png');
      expect(await service.currentCover(volume), isNull);
      expect(p.basename((await service.effectiveCover(volume))!), 'cover.png');
    });

    test('卷外图片不进候选（LIKE 前缀不外溢）', () async {
      final paths = (await service.listCandidates(volume)).map((c) => c.path);
      expect(paths.any((path) => path.contains('outside')), isFalse);
      expect(paths.any((path) => path.contains('vol2')), isFalse);
    });

    test('白名单图与字典序第一张重合时只出现一次，且标为白名单', () async {
      final dir = p.join(tmp.path, 'solo');
      final solo = await insertFolder('solo');
      await mountPath(solo, dir);
      await insertImage(img('solo/cover.jpg'));

      final candidates = await service.listCandidates(solo);

      expect(candidates.length, 1);
      expect(candidates.single.source, VolumeCoverSource.whitelistImage);
    });

    test('曲目顺序按 sort_key，缺封面时顺延到下一首', () async {
      final dir = p.join(tmp.path, 'tracks');
      final folder = await insertFolder('tracks');
      await mountPath(folder, dir);
      await insertAudio(p.join(dir, 'b.mp3'),
          coverPath: img('cache/bb.jpg'), sortKey: '2');
      await insertAudio(p.join(dir, 'a.mp3'),
          coverPath: img('cache/aa.jpg'), sortKey: '1');

      var candidates = await service.listCandidates(folder);
      expect(p.basename(candidates.single.path), 'aa.jpg');

      // 第一首的封面文件丢了 → 顺延到第二首
      existing.remove(p.join(tmp.path, 'cache/aa.jpg'));
      candidates = await service.listCandidates(folder);
      expect(p.basename(candidates.single.path), 'bb.jpg');
    });

    test('子树（子孙文件夹挂的目录）里的图片也算卷内', () async {
      final child = await insertFolder('child', parent: volume);
      // 故意挂到卷目录之外：只有走 folders.parent 的子树收集才会被看到
      final deepDir = p.join(tmp.path, 'elsewhere/deep');
      await mountPath(child, deepDir);
      await insertImage(img('elsewhere/deep/z.png'));

      final paths =
          (await service.listCandidates(volume)).map((c) => c.path).toList();
      expect(paths.any((path) => path.endsWith('z.png')), isTrue);
    });
  });

  group('缺图回退', () {
    test('白名单图文件丢了就跳过它，找下一张存在的白名单图', () async {
      final dir = p.join(tmp.path, 'fallback');
      final folder = await insertFolder('fallback');
      await mountPath(folder, dir);
      await insertImage(p.join(dir, 'cover.jpg')); // 不登记存在
      final front = img('fallback/front.png');
      await insertImage(front);

      final candidates = await service.listCandidates(folder);

      expect(candidates.single.source, VolumeCoverSource.whitelistImage);
      expect(candidates.single.path, front);
    });

    test('所有图片都丢了 → 用曲目内嵌；曲目也丢 → 用系列封面', () async {
      final work = await insertWork('w', coverPath: img('s.jpg'));
      final dir = p.join(tmp.path, 'fb2');
      final folder = await insertFolder('fb2', workId: work);
      await mountPath(folder, dir);
      await insertImage(p.join(dir, 'a.png')); // 文件不存在
      await insertAudio(p.join(dir, 'a.mp3'), coverPath: img('cache/aa.jpg'));

      final candidates = await service.listCandidates(folder);
      expect(candidates.first.source, VolumeCoverSource.trackEmbedded);
      expect(p.basename(candidates.first.path), 'aa.jpg');
      expect(candidates.map((c) => c.source),
          contains(VolumeCoverSource.seriesCover));

      // 曲目封面文件也丢了 → 只剩系列封面兜底
      existing.remove(p.join(tmp.path, 'cache/aa.jpg'));
      final fallback = await service.listCandidates(folder);
      expect(fallback.single.source, VolumeCoverSource.seriesCover);
      expect(fallback.single.path, p.join(tmp.path, 's.jpg'));
    });

    test('一个候选都没有时 resolve 返回 null', () async {
      final folder = await insertFolder('empty');
      await mountPath(folder, p.join(tmp.path, 'empty'));

      final candidates = await service.listCandidates(folder);

      expect(candidates, isEmpty);
      expect(await service.resolve(folder), isNull);
      expect(await service.effectiveCover(folder), isNull);
    });

    test('卷没挂任何目录时返回空候选（不报错）', () async {
      final folder = await insertFolder('no-path');
      expect(await service.listCandidates(folder), isEmpty);
    });

    test('目录名里的通配符字符不会被当成 LIKE 模式', () async {
      final weird = p.join(tmp.path, 'vo_l');
      final folder = await insertFolder('weird');
      await mountPath(folder, weird);
      await insertImage(img('vo_l/in.png'));
      await insertImage(img('voXl/out.png'));

      final paths =
          (await service.listCandidates(folder)).map((c) => c.path).toList();

      expect(paths.single, p.join(tmp.path, 'vo_l/in.png'));
    });
  });

  group('手动指定与裁剪', () {
    late int volume;

    setUp(() async {
      volume = await insertFolder('vol');
      await mountPath(volume, p.join(tmp.path, 'vol'));
      await insertImage(img('vol/cover.jpg'));
    });

    test('手动指定优先于自动候选，清掉后回到自动候选', () async {
      final manual = img('picked.jpg');
      await service.setCover(volume, manual);

      expect(await service.currentCover(volume), manual);
      expect(await service.effectiveCover(volume), manual);

      await service.clearCover(volume);

      expect(await service.currentCover(volume), isNull);
      expect(p.basename((await service.effectiveCover(volume))!), 'cover.jpg');
    });

    test('空串与 null 一样算清空', () async {
      await service.setCover(volume, '');
      expect(await service.currentCover(volume), isNull);
    });

    test('手动封面的文件没了就退回自动候选', () async {
      final manual = img('picked.jpg');
      await service.setCover(volume, manual);
      expect(await service.effectiveCover(volume), manual);

      // 用户把文件删了或搬走了，库里的路径还在
      existing.remove(manual);

      expect(await service.currentCover(volume), manual);
      expect(p.basename((await service.effectiveCover(volume))!), 'cover.jpg');
    });

    test('effectiveCover 不写库', () async {
      await service.effectiveCover(volume);
      expect(await service.currentCover(volume), isNull);
      final rows = await db.query('folders',
          columns: <String>['cover_path'],
          where: 'id = ?',
          whereArgs: <Object?>[volume]);
      expect(rows.first['cover_path'], isNull);
    });

    test('setCrop / cropOf 往返', () async {
      expect(await service.cropOf(volume), isNull);

      await service.setCrop(volume, const Rect.fromLTRB(0.05, 0.1, 0.95, 0.6));

      final crop = await service.cropOf(volume);
      expect(crop!.left, closeTo(0.05, 1e-9));
      expect(crop.top, closeTo(0.1, 1e-9));
      expect(crop.right, closeTo(0.95, 1e-9));
      expect(crop.bottom, closeTo(0.6, 1e-9));

      final rows = await db.query('folders',
          columns: <String>['cover_crop'],
          where: 'id = ?',
          whereArgs: <Object?>[volume]);
      expect(rows.first['cover_crop'], '0.05,0.1,0.95,0.6');
    });

    test('整幅图与 null 都写成 NULL', () async {
      await service.setCrop(volume, CropMath.full);
      var rows = await db.query('folders',
          columns: <String>['cover_crop'],
          where: 'id = ?',
          whereArgs: <Object?>[volume]);
      expect(rows.first['cover_crop'], isNull);

      await service.setCrop(volume, const Rect.fromLTRB(0, 0, 0.5, 0.5));
      await service.setCrop(volume, null);
      rows = await db.query('folders',
          columns: <String>['cover_crop'],
          where: 'id = ?',
          whereArgs: <Object?>[volume]);
      expect(rows.first['cover_crop'], isNull);
      expect(await service.cropOf(volume), isNull);
    });

    test('库里存了坏格式的 crop 时当没设过', () async {
      await db.update('folders', <String, Object?>{'cover_crop': 'nonsense'},
          where: 'id = ?', whereArgs: <Object?>[volume]);
      expect(await service.cropOf(volume), isNull);
    });

    test('setCoverWithCrop 一次写两列', () async {
      final manual = img('picked.jpg');
      await service.setCoverWithCrop(
          volume, manual, const Rect.fromLTRB(0.1, 0.2, 0.8, 0.9));

      expect(await service.currentCover(volume), manual);
      final crop = await service.cropOf(volume);
      expect(crop!.left, closeTo(0.1, 1e-9));
      expect(crop.bottom, closeTo(0.9, 1e-9));

      // 两个参数都为空 = 全部退回自动
      await service.setCoverWithCrop(volume, null, null);
      expect(await service.currentCover(volume), isNull);
      expect(await service.cropOf(volume), isNull);
    });
  });

  group('系列封面', () {
    test('没有 series 时返回 null', () async {
      final folder = await insertFolder('lonely');
      expect(await service.seriesCoverPath(folder), isNull);
    });

    test('空串算没设', () async {
      final work = await insertWork('w', coverPath: '');
      final folder = await insertFolder('vol', workId: work);
      expect(await service.seriesCoverPath(folder), isNull);
      expect(await service.listCandidates(folder), isEmpty);
    });

    test('有 series 时返回 works.cover_path', () async {
      final work = await insertWork('w', coverPath: '/cache/s.jpg');
      final folder = await insertFolder('vol', workId: work);
      expect(await service.seriesCoverPath(folder), '/cache/s.jpg');
    });
  });
}
