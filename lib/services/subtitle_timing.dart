import 'subtitle_parser.dart';

/// 返回 [position] 命中的最后一行下标。
///
/// 早于第一行时返回 -1；调用方可以把它当成「第一行即将出现」。
/// 字幕页与常驻字幕共用同一套判定，避免两处进度算法漂移。
int subtitleLineIndex(List<LyricLine> lines, Duration position) {
  final ms = position.inMilliseconds;
  var index = -1;
  for (var i = 0; i < lines.length; i++) {
    if (ms >= lines[i].startMs) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}
