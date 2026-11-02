/// DLsite 请求的节流与重试。
///
/// 站点 `robots.txt` 写着 `Crawl-delay: 10`，所以串行请求之间至少隔 10 秒。
/// 429 与 503 退避重试两次，403 直接失败不重试（那是被封，重试只会更糟）。
library;

import 'dart:async';

import '../../utils/log_util.dart';

/// 串行节流器：同一时间只跑一个请求，两次之间至少隔 [minInterval]。
class DlsiteRateLimiter {
  DlsiteRateLimiter({
    this.minInterval = const Duration(seconds: 10),
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  })  : _sleep = sleep ?? Future<void>.delayed,
        _now = now ?? DateTime.now;

  final Duration minInterval;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  Future<void> _tail = Future<void>.value();
  DateTime? _lastStart;

  /// 排队执行 [action]，返回它的结果。
  ///
  /// 队列用 Future 链实现，不引入锁：每个任务挂在上一个任务的尾巴上，
  /// 上一个失败也不影响下一个开始。
  Future<T> run<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        final wait = _timeUntilNextSlot();
        if (wait > Duration.zero) await _sleep(wait);
        _lastStart = _now();
        result.complete(await action());
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Duration _timeUntilNextSlot() {
    final last = _lastStart;
    if (last == null) return Duration.zero;
    final elapsed = _now().difference(last);
    final remain = minInterval - elapsed;
    return remain.isNegative ? Duration.zero : remain;
  }
}

/// 重试判定：哪些状态码值得再试。
class DlsiteRetryPolicy {
  const DlsiteRetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(seconds: 5),
  });

  /// 总尝试次数（含第一次）。默认 3，即退避重试两次。
  final int maxAttempts;

  /// 第一次退避的等待时间，之后每次翻倍。
  final Duration baseDelay;

  /// 429 表示限流、503 表示服务暂不可用，都可以等一会儿再来；
  /// 状态码为 null 表示连接层失败（DNS、超时、TLS 握手），也值得重试。
  /// 其它 4xx（尤其 403）重试没有意义。
  bool shouldRetry(int? status) =>
      status == null || status == 429 || status == 503;

  Duration delayFor(int attempt) =>
      baseDelay * (1 << (attempt - 1).clamp(0, 4));

  /// 按策略执行 [action]。`status` 由调用方从响应或异常里取。
  ///
  /// [action] 抛出的异常会被原样抛给调用方，除非 `statusOf` 说这个状态可以
  /// 重试。重试用尽后抛最后一次的错误。
  Future<T> run<T>(
    Future<T> Function() action, {
    int? Function(Object error)? statusOf,
    Future<void> Function(Duration)? sleep,
  }) async {
    final wait = sleep ?? Future<void>.delayed;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } catch (e) {
        lastError = e;
        final status = statusOf?.call(e);
        if (attempt == maxAttempts || !shouldRetry(status)) rethrow;
        logWarn('DlsiteRetryPolicy', '第 $attempt 次请求失败（status=$status），'
            '${delayFor(attempt).inSeconds} 秒后重试');
        await wait(delayFor(attempt));
      }
    }
    // 循环里最后一次失败已经 rethrow，这里只是让类型收敛。
    throw lastError!;
  }
}
