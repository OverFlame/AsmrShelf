/// 进度通知的节流器：进度没走够一格就不值得惊动界面。
///
/// 导入一个 5000 张图的目录时，导入流的每个文件都会走一遍
/// `notifyListeners()`，而首页是整页 `context.watch`：5000 次重建里，
/// 用户能看出差别的只有进度条上那百分之几。
///
/// 进度换算成千分位整数再比，避免 0.21 - 0.2 = 0.00999… 这种浮点误差
/// 把边界上的那一格吃掉。
class ProgressThrottle {
  ProgressThrottle({this.stepPermille = 10})
      : assert(stepPermille > 0 && stepPermille <= 1000);

  /// 两次通知之间进度至少要涨多少（单位千分比，10 即 1%）。
  final int stepPermille;

  int _last = 0;

  /// 已经通知过的进度（千分比）。
  int get lastNotified => _last;

  /// 进度涨够 [stepPermille] 就返回 true 并记下这次的位置。
  ///
  /// 进度回退说明是新的一次导入，先归零再判：那一下必须通知，
  /// 否则进度条会停在上一轮的位置上。
  bool shouldNotify(double percent) {
    final now = (percent * 1000).round().clamp(0, 1000);
    if (now < _last) _last = 0;
    if (now - _last >= stepPermille) {
      _last = now;
      return true;
    }
    return false;
  }
}
