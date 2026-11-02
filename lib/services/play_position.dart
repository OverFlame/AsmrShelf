/// 音频续播位置的取舍与落盘节流。
///
/// 库里 media.play_position_ms 存的是「上一次播到的位置」，续播时不能照搬：
/// 太靠前的位置等于没听过，离结尾只剩几秒的位置一按播放就会立刻跳下一首。
/// 播放器每 250 毫秒报一次位置，照单全收等于每秒四次 UPDATE，所以写入按
/// 位置前进量节流，而不是按时间。
library;

class PlayPositionRules {
  PlayPositionRules._();

  /// 小于这个进度就当作没听过，下次从头开始。
  static const Duration minResume = Duration(seconds: 5);

  /// 离结尾不足这个距离就当作已经听完，下次从头开始。
  static const Duration endGuard = Duration(seconds: 5);

  /// 由库里存的位置与总时长算出这次从哪儿接着放；从头则返回 [Duration.zero]。
  ///
  /// [durationMs] 未知（null 或 0）时只能信位置本身，不做结尾判断。
  static Duration resumeOf(int positionMs, int? durationMs) {
    if (positionMs <= 0) return Duration.zero;
    final position = Duration(milliseconds: positionMs);
    if (position < minResume) return Duration.zero;
    if (durationMs != null && durationMs > 0) {
      final total = Duration(milliseconds: durationMs);
      if (total - position <= endGuard) return Duration.zero;
    }
    return position;
  }
}

/// 播放位置落盘的节流：位置每前进 [step] 才允许写一次库。
class PlayPositionThrottle {
  PlayPositionThrottle({this.step = const Duration(seconds: 5)})
      : assert(step > Duration.zero);

  /// 两次落盘之间位置至少要前进多少
  final Duration step;

  Duration _saved = Duration.zero;

  /// 上一次放行落盘的位置，供用例断言
  Duration get lastSaved => _saved;

  /// 位置回退（用户往回拖）时把基准清掉，下一次前进照样能落盘。
  bool shouldSave(Duration position) {
    if (position < _saved) _saved = Duration.zero;
    if (position - _saved >= step) {
      _saved = position;
      return true;
    }
    return false;
  }

  void reset() => _saved = Duration.zero;
}
