import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:asmrshelf/services/file_scanner.dart';

void main() {
  test('扫描目录：识别音频并匹配字幕 + 封面', () async {
    final dir = await Directory.systemTemp.createTemp('audioshelf_scan');

    File(p.join(dir.path, 'a.mp3')).writeAsStringSync('fake');
    File(p.join(dir.path, 'b.wav')).writeAsStringSync('fake');
    File(p.join(dir.path, 'a.mp3.vtt')).writeAsStringSync('WEBVTT\n');
    File(p.join(dir.path, 'b.vtt')).writeAsStringSync('...\n');
    File(p.join(dir.path, 'c.srt')).writeAsStringSync('...\n'); // 无对应音频
    File(p.join(dir.path, 'cover.jpg')).writeAsStringSync('fake-image');
    File(p.join(dir.path, 'readme.txt')).writeAsStringSync('not audio');

    final scan = await FileScanner.scanDirectory(dir.path);

    expect(scan.audioPaths.length, 2);
    // 完整文件名优先
    expect(scan.subtitleByAudio[p.join(dir.path, 'a.mp3')],
        [p.join(dir.path, 'a.mp3.vtt')]);
    // 去扩展名匹配
    expect(scan.subtitleByAudio[p.join(dir.path, 'b.wav')],
        [p.join(dir.path, 'b.vtt')]);
    // c.srt 无对应音频，不应出现在映射里
    final matched = scan.subtitleByAudio.values.expand((e) => e).toList();
    expect(matched.contains(p.join(dir.path, 'c.srt')), isFalse);
    expect(scan.coverFiles.length, 1);

    await dir.delete(recursive: true);
  });

  test('优先完整文件名而非去扩展名', () async {
    final dir = await Directory.systemTemp.createTemp('audioshelf_scan2');
    File(p.join(dir.path, 'a.mp3')).writeAsStringSync('fake');
    File(p.join(dir.path, 'a.mp3.vtt')).writeAsStringSync('full');
    File(p.join(dir.path, 'a.vtt')).writeAsStringSync('base');

    final scan = await FileScanner.scanDirectory(dir.path);

    expect(scan.subtitleByAudio[p.join(dir.path, 'a.mp3')],
        [p.join(dir.path, 'a.mp3.vtt'), p.join(dir.path, 'a.vtt')]);

    await dir.delete(recursive: true);
  });

  test('多字幕按优先级排队，同档按路径字典序', () async {
    final dir = await Directory.systemTemp.createTemp('audioshelf_scan3');
    File(p.join(dir.path, 'a.mp3')).writeAsStringSync('fake');
    File(p.join(dir.path, 'a.mp3.eng.vtt')).writeAsStringSync('完整名 + 语言');
    File(p.join(dir.path, 'a.vtt')).writeAsStringSync('去扩展名');
    File(p.join(dir.path, 'a.CHS&JPN.srt')).writeAsStringSync('组合');
    File(p.join(dir.path, 'a.jp.srt')).writeAsStringSync('语言');
    File(p.join(dir.path, 'a.zh-CN.vtt')).writeAsStringSync('语言 + 地区');
    File(p.join(dir.path, 'a.zh.srt')).writeAsStringSync('语言');
    File(p.join(dir.path, 'a.简日.lrc')).writeAsStringSync('连写汉字');
    // 下面两条不该被匹配
    File(p.join(dir.path, 'a.cht.ass')).writeAsStringSync('占位格式');
    File(p.join(dir.path, 'a.xx.vtt')).writeAsStringSync('不是语言标记');

    final scan = await FileScanner.scanDirectory(dir.path);
    final names = scan.subtitleByAudio[p.join(dir.path, 'a.mp3')]!
        .map(p.basename)
        .toList();

    expect(names, [
      'a.mp3.eng.vtt', // 档位 1：完整文件名 + 语言
      'a.vtt', // 档位 2：去扩展名
      'a.CHS&JPN.srt', // 档位 3：去扩展名 + 语言，同档按路径
      'a.jp.srt',
      'a.zh-CN.vtt',
      'a.zh.srt',
      'a.简日.lrc',
    ]);
    expect(names.contains('a.cht.ass'), isFalse,
        reason: '占位格式只入库，不参与匹配');
    expect(names.contains('a.xx.vtt'), isFalse, reason: 'xx 不是语言标记');

    await dir.delete(recursive: true);
  });

  test('语言标记大小写不敏感', () async {
    final dir = await Directory.systemTemp.createTemp('audioshelf_scan4');
    File(p.join(dir.path, 'a.mp3')).writeAsStringSync('fake');
    File(p.join(dir.path, 'a.ZH-CN.SRT')).writeAsStringSync('大写');

    final scan = await FileScanner.scanDirectory(dir.path);

    expect(scan.subtitleByAudio[p.join(dir.path, 'a.mp3')],
        [p.join(dir.path, 'a.ZH-CN.SRT')]);

    await dir.delete(recursive: true);
  });
}
