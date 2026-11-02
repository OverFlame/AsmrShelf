import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/play_position.dart';

/// 续播位置的取舍与落盘节流。
///
/// 位置几乎总是「听到一半」的，直接拿来续播会让用户一按播放就跳下一首；
/// 播放器每 250 毫秒报一次位置，不节流就是每秒四次 UPDATE。
void main() {
  group('PlayPositionRules.resumeOf', () {
    test('没播过、位置是 0 或负数都从头开始', () {
      expect(PlayPositionRules.resumeOf(0, 200000), Duration.zero);
      expect(PlayPositionRules.resumeOf(-1000, 200000), Duration.zero);
    });

    test('不足 5 秒的进度等于没听过', () {
      expect(PlayPositionRules.resumeOf(4999, 200000), Duration.zero);
      expect(PlayPositionRules.resumeOf(5000, 200000),
          const Duration(seconds: 5));
    });

    test('离结尾 5 秒以内算听完，从头开始', () {
      expect(PlayPositionRules.resumeOf(198000, 200000), Duration.zero);
      expect(PlayPositionRules.resumeOf(199000, 200000), Duration.zero);
      expect(PlayPositionRules.resumeOf(195000, 200000), Duration.zero);
      // 还剩 6 秒：还没听完，接着播
      expect(PlayPositionRules.resumeOf(194000, 200000),
          const Duration(seconds: 194));
    });

    test('位置超出总时长（换了文件）也从头开始', () {
      expect(PlayPositionRules.resumeOf(300000, 200000), Duration.zero);
    });

    test('总时长未知时不判断结尾，只听位置', () {
      expect(PlayPositionRules.resumeOf(60000, null),
          const Duration(seconds: 60));
      expect(PlayPositionRules.resumeOf(60000, 0), const Duration(seconds: 60));
      // 位置本身太靠前照样从头
      expect(PlayPositionRules.resumeOf(3000, null), Duration.zero);
    });
  });

  group('PlayPositionThrottle', () {
    test('位置每前进一个步长才放行一次', () {
      final t = PlayPositionThrottle();
      expect(t.lastSaved, Duration.zero);
      expect(t.shouldSave(const Duration(seconds: 5)), isTrue);
      expect(t.lastSaved, const Duration(seconds: 5));
      expect(t.shouldSave(const Duration(seconds: 9)), isFalse);
      expect(t.shouldSave(const Duration(seconds: 10)), isTrue);
      expect(t.shouldSave(const Duration(seconds: 14, milliseconds: 900)),
          isFalse);
      expect(t.shouldSave(const Duration(seconds: 15)), isTrue);
    });

    test('250 毫秒一报，10 分钟只写 12 次而不是 2400 次', () {
      final t = PlayPositionThrottle();
      var saves = 0;
      for (var ms = 0; ms <= 60000; ms += 250) {
        if (t.shouldSave(Duration(milliseconds: ms))) saves++;
      }
      expect(saves, 12);
    });

    test('往回拖之后把基准清掉，库里的旧位置很快被追平', () {
      final t = PlayPositionThrottle();
      expect(t.shouldSave(const Duration(seconds: 30)), isTrue);
      // 拖回 2 秒这一步不写，但它把基准清了（库里记的 30 秒已经不准）
      expect(t.shouldSave(const Duration(seconds: 2)), isFalse);
      expect(t.shouldSave(const Duration(seconds: 6)), isTrue);
      expect(t.lastSaved, const Duration(seconds: 6));
    });

    test('reset 之后重新起步', () {
      final t = PlayPositionThrottle();
      expect(t.shouldSave(const Duration(seconds: 20)), isTrue);
      t.reset();
      expect(t.lastSaved, Duration.zero);
      expect(t.shouldSave(const Duration(seconds: 20)), isTrue);
    });

    test('步长可调，且不能是 0', () {
      final t = PlayPositionThrottle(step: const Duration(milliseconds: 250));
      expect(t.shouldSave(const Duration(milliseconds: 250)), isTrue);
      expect(t.shouldSave(const Duration(milliseconds: 400)), isFalse);
      expect(t.shouldSave(const Duration(milliseconds: 500)), isTrue);
      expect(() => PlayPositionThrottle(step: Duration.zero),
          throwsAssertionError);
    });
  });
}
