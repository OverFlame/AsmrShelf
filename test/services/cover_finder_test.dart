import 'dart:io';

import 'package:asmrshelf/services/cover_finder.dart';
import 'package:asmrshelf/services/image_size.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 写一张只有 PNG 头的假图：尺寸探测够了，不需要真能解码。
Future<File> fakePng(Directory dir, String name,
    {int width = 400, int height = 560}) async {
  final file = File(p.join(dir.path, name));
  await file.parent.create(recursive: true);
  final b = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0, 0, 0, 13,
    ...'IHDR'.codeUnits,
    (width >> 24) & 0xFF, (width >> 16) & 0xFF, (width >> 8) & 0xFF, width & 0xFF,
    (height >> 24) & 0xFF, (height >> 16) & 0xFF, (height >> 8) & 0xFF, height & 0xFF,
    ...List<int>.filled(5, 0),
  ];
  await file.writeAsBytes(b);
  return file;
}

void main() {
  late Directory work;
  setUp(() async {
    work = await Directory.systemTemp.createTemp('asmrshelf_cover_');
  });
  tearDown(() async {
    if (await work.exists()) await work.delete(recursive: true);
  });

  test('根目录白名单排在第一级，哪怕子树里有更漂亮的图', () async {
    final cover = await fakePng(work, 'cover.jpg', width: 300, height: 300);
    await fakePng(Directory(p.join(work.path, 'sample')), '大图.jpg',
        width: 1600, height: 1200);
    final hit = await CoverFinder().find(work.path, code: 'RJ294126');
    expect(hit.level, 1);
    expect(hit.path, cover.path);
  });

  test('编号形态的白名单优先于通用名', () async {
    final good = await fakePng(work, 'RJ294126_cover.jpg');
    await fakePng(work, 'cover.png');
    final hit = await CoverFinder().find(work.path, code: 'RJ294126');
    expect(hit.path, good.path);
  });

  test('根目录没有白名单时，先看信号目录再退回任意图', () async {
    final signal = await fakePng(Directory(p.join(work.path, '封面')), 'x.jpg');
    await fakePng(work, 'sample1.jpg', width: 100, height: 100);
    final hit = await CoverFinder().find(work.path, code: 'RJ294126');
    expect(hit.level, 2);
    expect(hit.path, signal.path);
  });

  test('只在深处有图时走第四级，取靠近根的那张', () async {
    final shallow = await fakePng(Directory(p.join(work.path, 'a')), 'one.jpg');
    await fakePng(Directory(p.join(work.path, 'a', 'b', 'c')), 'two.jpg');
    final hit = await CoverFinder().find(work.path);
    expect(hit.level, 4);
    expect(hit.path, shallow.path);
  });

  test('一张图都没有时返回 none', () async {
    await Directory(p.join(work.path, 'audio')).create(recursive: true);
    final hit = await CoverFinder().find(work.path);
    expect(hit.found, isFalse);
    expect(hit.level, 6);
  });

  test('找到后写盘用编号名，已在场的文件不覆盖', () async {
    final src = await fakePng(Directory(p.join(work.path, '特典')), 'x.jpg');
    final finder = CoverFinder();
    final written = await finder.fetchAndWrite(work.path, code: 'RJ294126');
    expect(written, p.join(work.path, 'RJ294126_cover.jpg'));
    expect(await File(written!).length(), await src.length());

    // 用户换了内容再跑一次：文件还在，内容不变。
    await File(written).writeAsBytes([1, 2, 3]);
    final again = await finder.fetchAndWrite(work.path, code: 'RJ294126');
    expect(again, written);
    expect(await File(written).readAsBytes(), [1, 2, 3]);
  });

  test('没有编号时写 cover.<ext>', () async {
    await fakePng(work, 'cover.png');
    final written = await CoverFinder().fetchAndWrite(work.path);
    expect(written, p.join(work.path, 'cover.png'));
  });

  test('源文件不存在时写盘返回 null', () async {
    final written = await CoverFinder().writeCoverFile(
      rootPath: work.path,
      sourcePath: p.join(work.path, 'nope.jpg'),
      code: 'RJ294126',
    );
    expect(written, isNull);
  });

  test('尺寸探测失败不挡挑选', () async {
    await fakePng(work, 'cover.jpg');
    final finder = CoverFinder(sizeOf: (_) async => null);
    final hit = await finder.find(work.path);
    expect(hit.found, isTrue);
    expect(hit.path, p.join(work.path, 'cover.jpg'));
  });

  test('ImageSize 值相等按宽高比较', () {
    expect(const ImageSize(1, 2), const ImageSize(1, 2));
  });
}
