/// 「同一时刻只跑一个任务，跑的过程中来的请求合并成一次重跑」。
///
/// 异步准备数据再 `setState` 的地方常用一个布尔量防重入：
///
/// ```dart
/// if (_generating) return;
/// _generating = true;
/// ```
///
/// 这个写法有个缺口：任务在跑的时候参数变了（卡片被复用给另一张图、
/// 缓存代数变了），新请求被直接丢掉，跑完的旧结果又照常写进 State，
/// 界面就停在旧结果上，之后也没有任何人再来触发一次。
///
/// [LatestOnlyRunner] 把这种情况改成「登记一次重跑」：本轮结束后按最新的
/// 状态再跑一遍，参数变几次只补跑一次。
class LatestOnlyRunner {
  bool _running = false;
  bool _again = false;

  /// 当前是否有任务在跑。
  bool get isRunning => _running;

  /// 跑 [task]。已有任务在跑时只登记一次重跑并立即返回；调用方要是
  /// `await` 了这个返回值，它不会等到重跑结束（重跑属于下一个调用者
  /// 启动的那一轮），所以这里不要依赖它的完成时机去读结果。
  Future<void> run(Future<void> Function() task) async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        // 先清标记再跑：跑的过程中来的请求会把它重新置真。
        _again = false;
        await task();
      } while (_again);
    } finally {
      _running = false;
    }
  }
}
