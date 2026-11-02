import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/file_io.dart';
import '../utils/log_util.dart';

/// 播放列表里的一项
class PlaylistEntry {
  const PlaylistEntry({required this.path, this.title, this.durationMs});

  final String path;
  final String? title;
  final int? durationMs;
}

/// 写 m3u8 播放列表（BUILD_GUIDE 第 24.2 节）
///
/// 纯文本。第一行是 `#EXTM3U`，每项两行：`#EXTINF:<秒>,<标题>` 与绝对路径。
/// 时长未知时写 -1，标题先取传入值，再取文件名。
class PlaylistWriter {
  PlaylistWriter({required this.outputDir});

  /// 输出目录，通常取 <数据目录>/playlist
  final String outputDir;

  /// 拼 m3u8 文本。不碰文件系统，便于单测。
  static String buildM3u8(List<PlaylistEntry> entries) {
    final buf = StringBuffer()..writeln('#EXTM3U');
    for (final e in entries) {
      final seconds =
          e.durationMs == null ? -1 : (e.durationMs! / 1000).round();
      buf.writeln('#EXTINF:$seconds,${_titleOf(e)}');
      buf.writeln(e.path);
    }
    return buf.toString();
  }

  static String _titleOf(PlaylistEntry e) {
    final t = e.title?.trim();
    if (t != null && t.isNotEmpty) return t;
    return p.basename(e.path);
  }

  /// 写文件，返回写好的绝对路径
  Future<String> write({
    required String name,
    required List<PlaylistEntry> entries,
  }) async {
    final dir = Directory(outputDir);
    if (!dir.existsSync()) await dir.create(recursive: true);
    final file = File(p.join(outputDir, '${_safeName(name)}.m3u8'));
    final text = buildM3u8(entries);
    // 走临时文件再改名：直接覆盖写的话，写到一半断电就剩半份播放列表。
    await writeFileAtomic(file, (tmp) => tmp.writeAsString(text, flush: true));
    logInfo('Playlist', '写入播放列表 ${file.path}，${entries.length} 项');
    return file.path;
  }

  /// 文件名里去掉 Windows 与 POSIX 都不接受的字符。
  ///
  /// 替换是「多对一」的：`第1话/上` 与 `第1话:上` 都会变成 `第1话_上`，
  /// 于是两个不同的播放列表落到同一个文件上互相覆盖。所以替换真的改动了
  /// 名字时补一段原始名字的短哈希：同一个名字仍然稳定映射到同一个文件
  /// （重复导出是覆盖自己），不同名字一定落到不同文件。
  static String _safeName(String raw) {
    final trimmed = raw.trim();
    final cleaned = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (cleaned.isEmpty) return 'playlist';
    if (cleaned == trimmed) return cleaned;
    return '${cleaned}_${_shortHash(trimmed)}';
  }

  /// 名字的短哈希（FNV-1a 32 位转 36 进制），只用来给文件名去重，不做校验。
  static String _shortHash(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(36).padLeft(6, '0');
  }
}
