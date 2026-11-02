import 'package:flutter/foundation.dart';

import '../utils/log_util.dart';

/// 导入期的状态：是否在导入、进度、最近一次错误。
///
/// 拆分自 [AppState]。这里只管这三个值和一个并发守卫，真正的扫描、
/// 落库与刷新仍由 AppState 编排：状态对象不反向调用上层。
class ImportState extends ChangeNotifier {
  bool _importing = false;

  /// 是否有一次导入正在进行。
  bool get importing => _importing;

  double _progress = 0;

  /// 0 到 1。导入结束后归零。
  double get progress => _progress;

  String? _error;

  /// 最近一次导入的失败原因。下一次导入开始时清空。
  String? get error => _error;

  /// 同步置位，返回 false 表示已有导入在跑、本次请求被拒。
  ///
  /// 必须在调用方的第一个 await 之前调用：两次导入同时进来时，
  /// 第二次要在这里就被挡住。
  bool begin(String caller) {
    if (_importing) {
      logWarn('ImportState', '$caller: 已有导入进行中，忽略本次请求');
      return false;
    }
    _importing = true;
    _progress = 0;
    _error = null;
    notifyListeners();
    return true;
  }

  void reportProgress(double value) {
    final next = value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0;
    if (next == _progress) return;
    _progress = next;
    notifyListeners();
  }

  void fail(Object error) {
    _error = error.toString();
    notifyListeners();
  }

  /// 收尾：清进度与进行中标志，保留错误供界面提示。
  void end() {
    _importing = false;
    _progress = 0;
    notifyListeners();
  }
}
