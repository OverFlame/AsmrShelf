import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:asmrshelf/services/playlist_writer.dart';

void main() {
  test('m3u8 行序正确，时长取整，缺时长写 -1', () {
    final text = PlaylistWriter.buildM3u8([
      PlaylistEntry(
          path: '/m/剧集/第1话.mp4', title: '第1话', durationMs: 1454999),
      PlaylistEntry(path: '/m/剧集/第2话.mp4', title: '第2话'),
    ]);
    final lines = text.trimRight().split('\n');

    expect(lines.length, 5);
    expect(lines[0], '#EXTM3U');
    expect(lines[1], '#EXTINF:1455,第1话');
    expect(lines[2], '/m/剧集/第1话.mp4');
    expect(lines[3], '#EXTINF:-1,第2话');
    expect(lines[4], '/m/剧集/第2话.mp4');
  });

  test('标题为空或只有空白时回落到文件名', () {
    final text = PlaylistWriter.buildM3u8([
      PlaylistEntry(path: '/m/第3话.mp4', title: '   '),
      PlaylistEntry(path: '/m/第4话.mp4'),
    ]);
    final lines = text.trimRight().split('\n');

    expect(lines[1], '#EXTINF:-1,第3话.mp4');
    expect(lines[3], '#EXTINF:-1,第4话.mp4');
  });

  test('写文件时建目录，名字里的非法字符换掉', () async {
    final tmp = await Directory.systemTemp.createTemp('asmrshelf_playlist');
    addTearDown(() => tmp.delete(recursive: true));
    final writer = PlaylistWriter(outputDir: p.join(tmp.path, 'playlist'));

    final file = await writer.write(
      name: '剧集:第1季?',
      entries: [PlaylistEntry(path: '/m/a.mp4', title: 'a')],
    );

    expect(file, contains(p.join('playlist', '剧集_第1季_')));
    expect(file, endsWith('.m3u8'));
    final written = File(file);
    expect(written.existsSync(), isTrue);
    expect(await written.readAsString(), contains('/m/a.mp4'));
  });

  test('非法字符归一后不同名字不能落到同一个文件', () async {
    final tmp = await Directory.systemTemp.createTemp('asmrshelf_playlist');
    addTearDown(() => tmp.delete(recursive: true));
    final writer = PlaylistWriter(outputDir: p.join(tmp.path, 'playlist'));

    // 两个标题只差一个非法字符：_safeName 会把它们都换成下划线，
    // 名字重了就会互相覆盖，用户以为导出了两份，实际只剩一份。
    final a = await writer.write(
      name: '第1话/上',
      entries: [PlaylistEntry(path: '/m/a.mp4')],
    );
    final b = await writer.write(
      name: '第1话:上',
      entries: [PlaylistEntry(path: '/m/b.mp4')],
    );

    expect(a, isNot(b));
    expect(await File(a).readAsString(), contains('/m/a.mp4'));
    expect(await File(b).readAsString(), contains('/m/b.mp4'));
  });

  test('同一个名字重复导出还是同一个文件', () async {
    final tmp = await Directory.systemTemp.createTemp('asmrshelf_playlist');
    addTearDown(() => tmp.delete(recursive: true));
    final writer = PlaylistWriter(outputDir: p.join(tmp.path, 'playlist'));

    final first = await writer.write(
      name: '第1话/上',
      entries: [PlaylistEntry(path: '/m/a.mp4')],
    );
    final second = await writer.write(
      name: '第1话/上',
      entries: [PlaylistEntry(path: '/m/c.mp4')],
    );

    expect(second, first);
    final text = await File(second).readAsString();
    expect(text, contains('/m/c.mp4'));
    expect(text, isNot(contains('/m/a.mp4')));
  });

  test('写完不留临时文件', () async {
    final tmp = await Directory.systemTemp.createTemp('asmrshelf_playlist');
    addTearDown(() => tmp.delete(recursive: true));
    final dir = p.join(tmp.path, 'playlist');
    final writer = PlaylistWriter(outputDir: dir);

    await writer.write(
      name: '归档',
      entries: [PlaylistEntry(path: '/m/a.mp4')],
    );

    final names =
        Directory(dir).listSync().map((e) => p.basename(e.path)).toList();
    expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
    expect(names.single, '归档.m3u8');
  });

  test('名字为空时用 playlist 兜底', () async {
    final tmp = await Directory.systemTemp.createTemp('asmrshelf_playlist');
    addTearDown(() => tmp.delete(recursive: true));
    final writer = PlaylistWriter(outputDir: tmp.path);

    final file = await writer.write(name: '  ', entries: []);

    expect(file, endsWith('playlist.m3u8'));
    expect(await File(file).readAsString(), '#EXTM3U\n');
  });
}
