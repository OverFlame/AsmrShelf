import 'dart:convert';
import 'dart:io';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:path/path.dart' as p;

import '../utils/log_util.dart';
import 'media_rules.dart';

/// 单行歌词/字幕
class LyricLine {
  final int startMs;
  final int endMs;
  final String text;

  const LyricLine({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  bool contains(int ms) => ms >= startMs && ms < endMs;
}

/// 一次字幕解析的结果（BUILD_GUIDE 第 23.3 节）
///
/// | 字段 | 含义 |
/// | --- | --- |
/// | `lines` | 解析出的行，占位格式为空 |
/// | `hasTiming` | 有没有时间轴。LRC 只有纯文本时为 false |
/// | `parsed` | 有没有解析器。占位格式与读失败为 false |
/// | `note` | 给界面看的说明文案 |
class SubtitleDocument {
  final List<LyricLine> lines;
  final bool hasTiming;
  final bool parsed;
  final String? note;

  const SubtitleDocument({
    this.lines = const [],
    this.hasTiming = false,
    this.parsed = true,
    this.note,
  });

  static const SubtitleDocument empty = SubtitleDocument();

  bool get isEmpty => lines.isEmpty;
}

/// 一个格式的解码函数：整篇文本进，结构化结果出
typedef SubtitleDecoder = SubtitleDocument Function(String content);

/// 字幕解析器：VTT / SRT / LRC → [SubtitleDocument]
///
/// 格式扩展只需往 [decoders] 里补一个解码函数。
class SubtitleParser {
  SubtitleParser._();

  /// 已实现的解码器
  static final Map<String, SubtitleDecoder> decoders = {
    '.vtt': parseVtt,
    '.srt': parseSrt,
    '.lrc': parseLrc,
  };

  /// 认得但还没有解析器的格式
  static List<String> get placeholderExtensions =>
      placeholderSubtitleExtensions.toList()..sort();

  /// 有解析器的格式
  static List<String> get supportedExtensions =>
      subtitleExtensions.toList()..sort();

  /// 占位格式的提示文案
  static String placeholderNote(String ext) => '该格式暂不支持解析（$ext）';

  /// 根据路径读取并解析字幕文件
  static SubtitleDocument parseFile(String path) {
    final ext = p.extension(path).toLowerCase();
    final decoder = decoders[ext];
    if (decoder == null) return _unsupported(ext);

    try {
      final file = File(path);
      if (!file.existsSync()) {
        return SubtitleDocument(parsed: false, note: '字幕文件不存在：$path');
      }
      return decoder(decodeBytes(file.readAsBytesSync()));
    } catch (e) {
      logWarn('Subtitle', '解析字幕失败 "$path": $e');
      return const SubtitleDocument(parsed: false, note: '字幕读取失败');
    }
  }

  /// 解析已经读进内存的文本
  static SubtitleDocument parse(String content, String ext) {
    final decoder = decoders[ext.toLowerCase()];
    if (decoder == null) return _unsupported(ext.toLowerCase());
    return decoder(content);
  }

  /// 编码探测链：UTF-8 → GBK → latin1（BUILD_GUIDE 第 23.2 节）
  ///
  /// GBK 字节按 UTF-8 解会抛 [FormatException]，所以先严格试 UTF-8；
  /// GBK 用 `allowMalformed: true`，认不出的字出替换符但不抛异常。
  static String decodeBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // 不是合法 UTF-8，按 GBK 再试一次
    }
    try {
      return const GbkCodec(allowMalformed: true).decode(bytes);
    } catch (_) {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  static SubtitleDocument _unsupported(String ext) {
    if (knownSubtitleExtensions.contains(ext)) {
      return SubtitleDocument(parsed: false, note: placeholderNote(ext));
    }
    return SubtitleDocument(parsed: false, note: '未识别的字幕格式（$ext）');
  }

  // ── VTT ──
  static SubtitleDocument parseVtt(String content) {
    final lines = _parseVttLines(content);
    return SubtitleDocument(
        lines: lines, hasTiming: lines.isNotEmpty, parsed: true);
  }

  static List<LyricLine> _parseVttLines(String content) {
    final lines = content.split(RegExp(r'\r?\n'));
    final result = <LyricLine>[];
    int? startMs;
    int? endMs;
    final buf = <String>[];
    bool inNote = false;

    void flush() {
      if (startMs != null && endMs != null && buf.isNotEmpty) {
        result.add(LyricLine(
            startMs: startMs!, endMs: endMs!, text: _clean(buf.join(' '))));
      }
      startMs = null;
      endMs = null;
      buf.clear();
    }

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) {
        inNote = false;
        flush();
        continue;
      }
      if (line.startsWith('WEBVTT') ||
          line.startsWith('STYLE') ||
          line.startsWith('REGION')) {
        continue;
      }
      if (line.startsWith('NOTE')) {
        inNote = true;
        continue;
      }
      if (inNote) continue;

      final arrow = line.indexOf('-->');
      if (arrow > 0) {
        flush();
        final before = line.substring(0, arrow).trim();
        final afterRaw = line.substring(arrow + 3).trim();
        // 时间戳后可能跟随 cue settings（position / align 等）
        final after = afterRaw.split(RegExp(r'\s+')).first;
        startMs = _parseTimestamp(before);
        endMs = _parseTimestamp(after);
      } else {
        buf.add(raw);
      }
    }
    flush();
    return result;
  }

  // ── SRT ──
  static SubtitleDocument parseSrt(String content) {
    final lines = _parseSrtLines(content);
    return SubtitleDocument(
        lines: lines, hasTiming: lines.isNotEmpty, parsed: true);
  }

  static List<LyricLine> _parseSrtLines(String content) {
    final blocks = content.split(RegExp(r'\r?\n\s*\r?\n'));
    final result = <LyricLine>[];
    for (final block in blocks) {
      final lines = block.split(RegExp(r'\r?\n'));
      int? timingIndex;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].contains('-->')) {
          timingIndex = i;
          break;
        }
      }
      if (timingIndex == null) continue;
      final arrow = lines[timingIndex].indexOf('-->');
      final startMs =
          _parseTimestamp(lines[timingIndex].substring(0, arrow).trim());
      final endMs =
          _parseTimestamp(lines[timingIndex].substring(arrow + 3).trim());
      final text = lines.sublist(timingIndex + 1).join(' ').trim();
      if (startMs != null && endMs != null && text.isNotEmpty) {
        result.add(
            LyricLine(startMs: startMs, endMs: endMs, text: _clean(text)));
      }
    }
    return result;
  }

  // ── LRC ──
  static SubtitleDocument parseLrc(String content) {
    final lines = content.split(RegExp(r'\r?\n'));
    final tagRe = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
    final offsetRe = RegExp(r'\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);
    // LRC 的元数据行（[ti:]、[ar:] 等）不是歌词，别混进正文
    final metaRe = RegExp(
        r'^\s*\[(ti|ar|al|au|by|offset|length|re|ve)\s*:.*\]\s*$',
        caseSensitive: false);

    // 元数据行的 [offset:±ms] 整体平移所有时间戳
    var offsetMs = 0;
    for (final line in lines) {
      final m = offsetRe.firstMatch(line);
      if (m != null) offsetMs = int.tryParse(m.group(1)!) ?? 0;
    }

    final timed = <LyricLine>[];
    final untimed = <String>[];

    for (final line in lines) {
      if (offsetRe.hasMatch(line)) continue;
      if (metaRe.hasMatch(line)) continue;
      final matches = tagRe.allMatches(line).toList();
      final text = _clean(line.replaceAll(tagRe, ''));
      if (matches.isEmpty) {
        if (text.isEmpty) continue;
        if (timed.isEmpty) {
          untimed.add(text);
        } else {
          // 有时间轴时，没标签的续行并进上一行，不丢字
          final prev = timed.removeLast();
          timed.add(LyricLine(
              startMs: prev.startMs,
              endMs: prev.endMs,
              text: '${prev.text} $text'));
        }
        continue;
      }
      if (text.isEmpty) continue;
      for (final m in matches) {
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        final fracRaw = m.group(3);
        int ms;
        if (fracRaw == null) {
          ms = (min * 60 + sec) * 1000;
        } else {
          // 2 位为厘秒，3 位为毫秒
          final frac = int.parse(fracRaw);
          final fracMs = fracRaw.length <= 2 ? frac * 10 : frac;
          ms = (min * 60 + sec) * 1000 + fracMs;
        }
        ms += offsetMs;
        if (ms < 0) ms = 0;
        timed.add(LyricLine(startMs: ms, endMs: 0, text: text));
      }
    }

    if (timed.isEmpty) {
      // 整篇没有时间标签：按静态歌词返回，界面逐行显示
      return SubtitleDocument(
        lines: [
          for (final t in untimed) LyricLine(startMs: 0, endMs: 0, text: t)
        ],
        hasTiming: false,
        parsed: true,
        note: untimed.isEmpty ? null : '该歌词无时间标签',
      );
    }

    timed.sort((a, b) => a.startMs.compareTo(b.startMs));
    final result = <LyricLine>[];
    for (int i = 0; i < timed.length; i++) {
      final end =
          (i + 1 < timed.length) ? timed[i + 1].startMs : timed[i].startMs + 5000;
      result.add(LyricLine(
          startMs: timed[i].startMs, endMs: end, text: timed[i].text));
    }
    return SubtitleDocument(lines: result, hasTiming: true, parsed: true);
  }

  /// 解析时间戳：HH:MM:SS.mmm / MM:SS.mmm / SS.mmm（. 或 , 作小数分隔）
  static int? _parseTimestamp(String s) {
    final t = s.trim().replaceAll(',', '.');
    final parts = t.split(':');
    if (parts.isEmpty || parts.length > 3) return null;
    double seconds;
    if (parts.length == 3) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final sec = double.tryParse(parts[2]);
      if (h == null || m == null || sec == null) return null;
      seconds = h * 3600 + m * 60 + sec;
    } else if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final sec = double.tryParse(parts[1]);
      if (m == null || sec == null) return null;
      seconds = m * 60 + sec;
    } else {
      final sec = double.tryParse(parts[0]);
      if (sec == null) return null;
      seconds = sec;
    }
    return (seconds * 1000).round();
  }

  /// 清理字幕文本：去除 HTML / ASS 内联标签与常见实体
  static String _clean(String s) {
    var t = s;
    t = t.replaceAll(RegExp(r'<[^>]*>'), '');
    t = t.replaceAll(RegExp(r'\{[^}]*\}'), '');
    t = t
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&quot;', '"');
    return t.trim();
  }
}
