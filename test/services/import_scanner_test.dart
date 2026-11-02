import 'dart:io';

import 'package:asmrshelf/services/import_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Future<File> touch(Directory root, String relative, {int bytes = 16}) async {
  final file = File(p.join(root.path, relative));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(List<int>.filled(bytes, 0));
  return file;
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('asmrshelf_import_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('每个子目录是一部作品，目录名里的编号进 code', () async {
    await touch(root, 'RJ294126 作品A/01. 導入.mp3');
    await touch(root, 'RJ294126 作品A/02. 本編.mp3');
    await touch(root, '只有一个标题/01 - 夜.mp3');

    final plan = await scanImportTree(root.path, writeCover: false);
    expect(plan.works.length, 2);

    final first = plan.works.firstWhere((w) => w.code == 'RJ294126');
    expect(first.title, '作品A');
    expect(first.trackCount, 2);
    expect(first.tracks.first.title, '導入');
    expect(first.tracks.last.title, '本編');

    final plain = plan.works.firstWhere((w) => w.code == null);
    expect(plain.title, '只有一个标题');
    expect(plain.tracks.single.title, '夜');
  });

  test('作品目录里的子目录也会被扫到，但特典不进曲目表', () async {
    await touch(root, 'RJ111111 作品/01.mp3');
    await touch(root, 'RJ111111 作品/本編/02.mp3');
    await touch(root, 'RJ111111 作品/特典/おまけ.mp3');

    final plan = await scanImportTree(root.path, writeCover: false);
    final work = plan.works.single;
    expect(work.trackCount, 2);
    expect(work.tracks.map((t) => t.fileName), ['01.mp3', '02.mp3']);
  });

  test('编号作品即使音频全在 01_mp3 子目录也能识别', () async {
    await touch(root, 'RJ777777 作品/01_mp3/01.mp3');
    await touch(root, 'RJ777777 作品/02_wav/02.wav');

    final plan = await scanImportTree(root.path, writeCover: false);
    final work = plan.works.single;
    expect(work.code, 'RJ777777');
    expect(work.title, '作品');
    expect(work.trackCount, 2);
  });

  test('一次性扫描会匹配同目录字幕', () async {
    final audio = await touch(root, 'RJ777777 作品/01_mp3/01.mp3');
    final subtitle = await touch(root, 'RJ777777 作品/01_mp3/01.lrc');

    final plan = await scanImportTree(root.path, writeCover: false);
    final work = plan.works.single;
    expect(work.subtitleByTrack[audio.path], subtitle.path);
  });

  test('没有音频的目录记进 skipped，不当成作品', () async {
    await touch(root, '空目录/readme.txt');
    await touch(root, 'RJ222222 真作品/01.mp3');
    final plan = await scanImportTree(root.path, writeCover: false);
    expect(plan.works.length, 1);
    expect(plan.skipped, [p.join(root.path, '空目录')]);
  });

  test('nested 打开后能认「社团/作品」两层', () async {
    await touch(root, '某社团/RJ333333 作品/01.mp3');
    await touch(root, '某社团/RJ333333 作品/02.mp3');

    final flat = await scanImportTree(root.path, writeCover: false);
    expect(flat.works, isEmpty);

    final nested = await scanImportTree(root.path, nested: true, writeCover: false);
    expect(nested.works.single.code, 'RJ333333');
    expect(nested.trackCount, 2);
  });

  test('曲目按自然序排，不按字典序', () async {
    await touch(root, 'RJ444444 作品/1.mp3');
    await touch(root, 'RJ444444 作品/10.mp3');
    await touch(root, 'RJ444444 作品/2.mp3');
    final plan = await scanImportTree(root.path, writeCover: false);
    expect(plan.works.single.tracks.map((t) => t.fileName), ['1.mp3', '2.mp3', '10.mp3']);
  });

  test('找封面并写进作品根目录', () async {
    await touch(root, 'RJ555555 作品/01.mp3');
    await touch(root, 'RJ555555 作品/封面/main.jpg');
    final plan = await scanImportTree(root.path);
    final work = plan.works.single;
    expect(work.coverLevel, 2);
    expect(work.coverPath, p.join(root.path, 'RJ555555 作品', 'RJ555555_cover.jpg'));
    expect(await File(work.coverPath!).exists(), isTrue);
  });

  test('writeCover 为 false 时只报路径不落盘', () async {
    await touch(root, 'RJ666666 作品/01.mp3');
    await touch(root, 'RJ666666 作品/封面.jpg');
    final plan = await scanImportTree(root.path, writeCover: false);
    final work = plan.works.single;
    // 「封面」是强词不是白名单，所以走第三级（根目录任意图）。
    expect(work.coverLevel, 3);
    expect(work.coverPath, p.join(root.path, 'RJ666666 作品', '封面.jpg'));
    expect(
      await File(p.join(root.path, 'RJ666666 作品', 'RJ666666_cover.jpg')).exists(),
      isFalse,
    );
  });

  test('根目录不存在时返回空计划', () async {
    final plan = await scanImportTree(p.join(root.path, 'nope'));
    expect(plan.works, isEmpty);
    expect(plan.trackCount, 0);
  });

  test('文件名里的序号与分隔符都能剥掉', () {
    expect(trackTitle('01. 名前.mp3'), '名前');
    expect(trackTitle('03 - 夜.flac'), '夜');
    expect(trackTitle('7、雨.m4a'), '雨');
    expect(trackTitle('トラック.wav'), 'トラック');
    expect(trackTitle('001.mp3'), '001');
  });
}
