import 'dart:developer' as dev;
import 'dart:io';

import 'package:path/path.dart' as p;

/// 等价于 Flutter 的 `kDebugMode`：只有 assert 生效的构建里才是 true。
///
/// 不用 `package:flutter/foundation.dart` 的常量，是为了让日志工具保持纯 Dart：
/// `tool/import_cli.dart` 这类命令行入口要能在没有 Flutter 引擎时跑（`dart run`）。
bool get _isDebugMode {
  var debug = false;
  assert(() {
    debug = true;
    return true;
  }());
  return debug;
}

/// 统一日志工具 — 输出到 [dart:developer.log]（控制台 + DevTools）；
/// 调过 [LogUtil.attachFileSink] 之后再落一份到 `<dataDir>/logs/`，
/// 界面提示「详情见 logs 目录」时那里才有东西可看。
enum Log {
  debug,
  info,
  warn,
  error;

  String get _label {
    switch (this) {
      case Log.debug:
        return 'DBG';
      case Log.info:
        return 'INF';
      case Log.warn:
        return 'WRN';
      case Log.error:
        return 'ERR';
    }
  }

  int get _devLevel {
    switch (this) {
      case Log.debug:
        return 500;
      case Log.info:
        return 800;
      case Log.warn:
        return 900;
      case Log.error:
        return 1000;
    }
  }
}

// ignore: non_constant_identifier_names
final LogUtil = _LogUtil.instance;

class _LogUtil {
  static final _LogUtil instance = _LogUtil._();
  _LogUtil._();

  bool showDebug = _isDebugMode;

  /// 单个日志文件的轮转上限，超过就改名成 `.1` 重开。
  static const int defaultMaxFileBytes = 2 * 1024 * 1024;

  /// 日志目录；为 null 表示只写控制台（未初始化、或目录写不进去）。
  String? _logDir;
  int _maxFileBytes = defaultMaxFileBytes;
  String? _fileDay;
  int _fileBytes = 0;

  /// 把日志同时写到 `<dir>/app-<日期>.log`：按天分文件，单文件超过
  /// [maxBytes] 轮转成 `.1`。目录建不出来时静默退回只写控制台。
  ///
  /// 用同步追加写：日志量小，换来的是崩溃瞬间已落盘、且不需要维护
  /// 一个跨行的 sink 生命周期。
  void attachFileSink(String dir, {int maxBytes = defaultMaxFileBytes}) {
    _maxFileBytes = maxBytes;
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {
      _logDir = null;
      return;
    }
    _logDir = dir;
    _fileDay = null;
    _fileBytes = 0;
    _currentFile();
  }

  /// 关掉文件 sink（数据目录迁移、测试收尾时用）。
  void detachFileSink() {
    _logDir = null;
    _fileDay = null;
    _fileBytes = 0;
  }

  /// 当前该写的文件，顺带处理跨天与计数复位。
  File _currentFile() {
    final day = _dayStamp(DateTime.now());
    if (day != _fileDay) {
      _fileDay = day;
      _fileBytes = 0;
    }
    final file = File(p.join(_logDir!, 'app-$day.log'));
    if (_fileBytes == 0 && file.existsSync()) {
      _fileBytes = file.lengthSync();
    }
    return file;
  }

  void _emit(Log level, String tag, String msg, [Object? data]) {
    if (level == Log.debug && !showDebug) return;

    final buf = StringBuffer()
      ..write('[${level._label}] ')
      ..write(tag.padRight(18))
      ..write(' | ')
      ..write(msg);
    // data 以前被整个丢掉：`logError('X', 'msg', '$e\n$st')` 只剩一句 msg，
    // 启动失败的堆栈全链路不可见。
    if (data != null) {
      buf
        ..write(' | ')
        ..write(data);
    }
    final line = buf.toString();

    try {
      dev.log(line,
          name: 'AsmrShelf',
          level: level._devLevel,
          error: level == Log.error ? data : null,
          time: DateTime.now());
    } catch (_) {
      // 没有 Flutter 引擎（命令行入口）时退回 stdout。
      stdout.writeln(line);
    }

    _appendToFile(line);
  }

  void _appendToFile(String line) {
    final dir = _logDir;
    if (dir == null) return;
    try {
      final file = _currentFile();
      final entry = '${_timeStamp(DateTime.now())} $line\n';
      if (_fileBytes > 0 && _fileBytes + entry.length > _maxFileBytes) {
        final rotated = File('${file.path}.1');
        if (rotated.existsSync()) rotated.deleteSync();
        if (file.existsSync()) file.renameSync(rotated.path);
        _fileBytes = 0;
      }
      file.writeAsStringSync(entry, mode: FileMode.append);
      _fileBytes += entry.length;
    } catch (_) {
      // 写不进去就关掉 sink，免得每条日志都抛一次异常。
      _logDir = null;
    }
  }

  void d(String tag, String msg, [Object? data]) =>
      _emit(Log.debug, tag, msg, data);
  void i(String tag, String msg, [Object? data]) =>
      _emit(Log.info, tag, msg, data);
  void w(String tag, String msg, [Object? data]) =>
      _emit(Log.warn, tag, msg, data);
  void e(String tag, String msg, [Object? data]) =>
      _emit(Log.error, tag, msg, data);
}

String _dayStamp(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

String _timeStamp(DateTime t) => '${_dayStamp(t)} '
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}.'
    '${t.millisecond.toString().padLeft(3, '0')}';

void logDebug(String tag, String msg, [Object? data]) =>
    LogUtil.d(tag, msg, data);
void logInfo(String tag, String msg, [Object? data]) =>
    LogUtil.i(tag, msg, data);
void logWarn(String tag, String msg, [Object? data]) =>
    LogUtil.w(tag, msg, data);
void logError(String tag, String msg, [Object? data]) =>
    LogUtil.e(tag, msg, data);
