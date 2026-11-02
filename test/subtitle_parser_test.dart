import 'dart:convert';
import 'dart:io';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:asmrshelf/services/subtitle_parser.dart';

void main() {
  group('SubtitleParser 解析器', () {
    test('VTT', () {
      const vtt = '''WEBVTT

00:00:01.000 --> 00:00:04.000
你好世界

00:00:04.000 --> 00:00:07.000
第二句
''';
      final doc = SubtitleParser.parse(vtt, '.vtt');
      expect(doc.parsed, isTrue);
      expect(doc.hasTiming, isTrue);
      expect(doc.lines.length, 2);
      expect(doc.lines[0].startMs, 1000);
      expect(doc.lines[0].endMs, 4000);
      expect(doc.lines[0].text, '你好世界');
      expect(doc.lines[1].text, '第二句');
    });

    test('VTT 带 inline 标签', () {
      const vtt = '''WEBVTT

00:00:01.000 --> 00:00:03.000
<i>斜体</i> 普通

''';
      final doc = SubtitleParser.parse(vtt, '.vtt');
      expect(doc.lines.single.text, '斜体 普通');
    });

    test('SRT', () {
      const srt = '''1
00:00:01,000 --> 00:00:04,000
第一行

2
00:00:04,000 --> 00:00:08,000
第二行
多行文本
''';
      final doc = SubtitleParser.parse(srt, '.srt');
      expect(doc.lines.length, 2);
      expect(doc.lines[0].startMs, 1000);
      expect(doc.lines[1].text, '第二行 多行文本');
    });

    test('LRC', () {
      const lrc = '''[ti:测试]
[00:01.00]第一句
[00:03.50]第二句
''';
      final doc = SubtitleParser.parse(lrc, '.lrc');
      expect(doc.lines.length, 2);
      expect(doc.lines[0].startMs, 1000);
      expect(doc.lines[1].startMs, 3500);
      // endMs 取下一句开始
      expect(doc.lines[0].endMs, 3500);
    });

    test('LRC 多个时间戳', () {
      const lrc = '[00:01.00][00:10.00]重复句';
      final doc = SubtitleParser.parse(lrc, '.lrc');
      expect(doc.lines.length, 2);
      expect(doc.lines[0].startMs, 1000);
      expect(doc.lines[1].startMs, 10000);
    });

    test('LRC offset 为负数：整体前移', () {
      const lrc = '[offset:-500]\n[00:02.00]第一句\n[00:04.00]第二句\n';
      final doc = SubtitleParser.parse(lrc, '.lrc');
      expect(doc.lines[0].startMs, 1500);
      expect(doc.lines[1].startMs, 3500);
    });

    test('LRC offset 为正数：整体后移', () {
      const lrc = '[offset:500]\n[00:02.00]第一句\n[00:04.00]第二句\n';
      final doc = SubtitleParser.parse(lrc, '.lrc');
      expect(doc.lines[0].startMs, 2500);
      expect(doc.lines[1].startMs, 4500);
    });

    test('LRC offset 把靠前的时间戳钳到 0', () {
      const lrc = '[offset:-5000]\n[00:01.00]第一句\n[00:03.00]第二句\n';
      final doc = SubtitleParser.parse(lrc, '.lrc');
      expect(doc.lines[0].startMs, 0);
      expect(doc.lines[1].startMs, 0);
    });

    test('LRC 无时间标签：整篇保留并给提示', () {
      const lrc = '[ti:测试]\n[ar:某人]\n第一行歌词\n第二行歌词\n';
      final doc = SubtitleParser.parse(lrc, '.lrc');
      expect(doc.parsed, isTrue);
      expect(doc.hasTiming, isFalse);
      expect(doc.note, '该歌词无时间标签');
      expect(doc.lines.map((l) => l.text).toList(), ['第一行歌词', '第二行歌词']);
      expect(doc.lines.every((l) => l.startMs == 0), isTrue);
    });

    test('LRC 有标签时无标签续行并进上一行', () {
      const lrc = '[00:01.00]第一句\n第二句\n[00:05.00]第三句\n';
      final doc = SubtitleParser.parse(lrc, '.lrc');
      expect(doc.hasTiming, isTrue);
      expect(doc.lines.length, 2);
      expect(doc.lines[0].text, '第一句 第二句');
    });

    test('占位格式给未解析提示，不抛异常', () {
      for (final ext in ['.ass', '.ssa', '.ttml', '.dfxp', '.smi', '.sami']) {
        final doc = SubtitleParser.parse('[Script Info]', ext);
        expect(doc.parsed, isFalse, reason: ext);
        expect(doc.lines, isEmpty, reason: ext);
        expect(doc.note, contains(ext), reason: ext);
      }
    });

    test('未识别的扩展名也给提示', () {
      final doc = SubtitleParser.parse('随便什么', '.xyz');
      expect(doc.parsed, isFalse);
      expect(doc.note, contains('.xyz'));
    });

    test('扩展名大小写不敏感，带点的形式也认', () {
      expect(SubtitleParser.parse('WEBVTT\n', '.VTT').parsed, isTrue);
      expect(SubtitleParser.parse('WEBVTT\n', 'vtt').parsed, isFalse);
    });

    test('扩展名分组：可解析三种，占位六种', () {
      expect(SubtitleParser.supportedExtensions, ['.lrc', '.srt', '.vtt']);
      expect(SubtitleParser.placeholderExtensions,
          ['.ass', '.dfxp', '.sami', '.smi', '.ssa', '.ttml']);
    });

    test('SubtitleDocument.empty 是空文档', () {
      expect(SubtitleDocument.empty.isEmpty, isTrue);
      expect(SubtitleDocument.empty.parsed, isTrue);
      expect(SubtitleDocument.empty.hasTiming, isFalse);
    });
  });

  group('SubtitleParser 解码链与文件', () {
    test('合法 UTF-8 原样返回', () {
      final bytes = utf8.encode('第一句：你好');
      expect(SubtitleParser.decodeBytes(bytes), '第一句：你好');
    });

    test('UTF-8 优先于 GBK', () {
      // 「你好」的 UTF-8 字节也能落进 GBK 的双字节区间，顺序反了就是乱码。
      final bytes = utf8.encode('你好');
      expect(SubtitleParser.decodeBytes(bytes), '你好');
      String? asGbk;
      try {
        asGbk = const GbkCodec().decode(bytes);
      } on FormatException {
        asGbk = null;
      }
      expect(asGbk, isNot('你好'));
    });

    test('GBK 字节按 GBK 解出中文', () {
      const gbk = GbkCodec();
      for (final text in ['你好世界', '第一句', '简体中文']) {
        final bytes = gbk.encode(text);
        expect(SubtitleParser.decodeBytes(bytes), text, reason: text);
      }
    });

    test('GBK 里的畸形字节出替换符，不抛异常', () {
      final bytes = <int>[0xC4, 0xE3, 0x20, 0xFF];
      final text = SubtitleParser.decodeBytes(bytes);
      expect(text.contains('\uFFFD'), isTrue);
    });

    test('空字节返回空串', () {
      expect(SubtitleParser.decodeBytes(const []), '');
    });

    test('parseFile：GBK 编码的 LRC 文件', () async {
      final dir = await Directory.systemTemp.createTemp('audioshelf_gbk');
      final file = File(p.join(dir.path, 'a.lrc'));
      const gbk = GbkCodec();
      file.writeAsBytesSync(gbk.encode('[00:01.00]第一句\n'));

      final doc = SubtitleParser.parseFile(file.path);

      expect(doc.parsed, isTrue);
      expect(doc.lines.single.text, '第一句');
      expect(doc.lines.single.startMs, 1000);

      await dir.delete(recursive: true);
    });

    test('parseFile：文件不存在时给提示', () {
      final doc = SubtitleParser.parseFile('/no/such/dir/a.vtt');
      expect(doc.parsed, isFalse);
      expect(doc.note, contains('不存在'));
    });

    test('parseFile：占位格式不读盘也给提示', () {
      final doc = SubtitleParser.parseFile('/no/such/dir/a.ass');
      expect(doc.parsed, isFalse);
      expect(doc.note, contains('.ass'));
    });
  });
}
