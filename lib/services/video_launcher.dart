import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/log_util.dart';

/// 外链播放的结果
enum LaunchResult { ok, unsupportedPlatform, failed }

/// Android 侧「交给系统播放器」的入口签名。
///
/// 参数是文件路径与 MIME，返回系统是否接下了这次分派。
typedef SystemOpen = Future<bool> Function(String path, String mimeType);

/// 把文件或播放列表交给系统默认播放器（BUILD_GUIDE 第 9.4、9.5 与 24.2 节）
///
/// 桌面端起进程，Android 走 Intent，都不链接任何播放器库，
/// 因此不引入许可证风险。
class VideoLauncher {
  VideoLauncher({
    Future<Process> Function(String, List<String>)? start,
    SystemOpen? openWithSystem,
    String? os,
    this.openTimeout = const Duration(seconds: 10),
    this.exitCodeGrace = const Duration(milliseconds: 1200),
  })  : _start = start ?? Process.start,
        _openWithSystem = openWithSystem ?? _invokeNativeOpen,
        _os = os ?? detectOs();

  final Future<Process> Function(String executable, List<String> arguments)
      _start;
  final SystemOpen _openWithSystem;
  final String _os;

  /// 等平台通道回话的上限。Android 侧 Activity 没起来或是旧版本没有
  /// `openVideo` 实现时，通道回调可能永远不来，不能把界面挂在那里。
  final Duration openTimeout;

  /// 桌面进程退出码的观察窗口。`xdg-open` 找不到处理器时立刻非 0 退出，
  /// 这个失败要让用户看见；但有些桌面处理器会把进程挂在后台（等应用退出），
  /// 所以超过这个窗口还没退出就按成功算。
  final Duration exitCodeGrace;

  /// 平台通道，名字与 `MediaBridge.channel` 一致：同一个通道由 MainActivity 处理。
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('asmrshelf/playback');

  static Future<bool> _invokeNativeOpen(String path, String mimeType) async {
    final ok = await channel.invokeMethod<bool>('openVideo', <String, Object>{
      'path': path,
      'mimeType': mimeType,
    });
    return ok ?? false;
  }

  static String detectOs() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    return 'other';
  }

  /// 桌面平台分派表。Android 走 Intent，认不出平台时返回 null。
  static (String, List<String>)? commandFor(String path, String os) =>
      switch (os) {
        // explorer.exe 接收的是独立参数，路径里的 & ^ % 不会被 cmd 解释。
        'windows' => ('explorer.exe', <String>[path]),
        'linux' => ('xdg-open', <String>[path]),
        _ => null,
      };

  /// 扩展名到 MIME 的对照表（BUILD_GUIDE 第 9.5 节：MIME 由扩展名给出）
  static const Map<String, String> mimeByExtension = <String, String>{
    '.mp4': 'video/mp4',
    '.m4v': 'video/x-m4v',
    '.mkv': 'video/x-matroska',
    '.webm': 'video/webm',
    '.avi': 'video/x-msvideo',
    '.mov': 'video/quicktime',
    '.flv': 'video/x-flv',
    '.wmv': 'video/x-ms-wmv',
    '.mpg': 'video/mpeg',
    '.mpeg': 'video/mpeg',
    '.ts': 'video/mp2t',
    '.3gp': 'video/3gpp',
    // 外链播放的产物是 m3u8 播放列表
    '.m3u8': 'application/x-mpegurl',
    '.m3u': 'audio/x-mpegurl',
  };

  /// 取 MIME。认不出扩展名时给 `video/*`，让系统自己挑应用。
  static String mimeTypeFor(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return 'video/*';
    return mimeByExtension[path.substring(dot).toLowerCase()] ?? 'video/*';
  }

  Future<LaunchResult> open(String path) async {
    if (_os == 'android') return _openOnAndroid(path);
    final cmd = commandFor(path, _os);
    if (cmd == null) {
      logWarn('Launch', '平台 $_os 不支持外链播放：$path');
      return LaunchResult.unsupportedPlatform;
    }
    try {
      final proc = await _start(cmd.$1, cmd.$2);
      // explorer.exe 即使成功打开也常返回 1，Windows 上不看退出码。
      final code = _os == 'windows' ? null : await _exitCodeOrNull(proc);
      if (code != null && code != 0) {
        logWarn('Launch',
            '外部播放器立刻退出（退出码 $code）：${cmd.$1} ${cmd.$2.join(' ')}');
        return LaunchResult.failed;
      }
      logInfo('Launch', '已交给外部播放器：${cmd.$1} ${cmd.$2.join(' ')}');
      return LaunchResult.ok;
    } catch (e) {
      logWarn('Launch', '外链播放失败：$e');
      return LaunchResult.failed;
    }
  }

  /// 等 [exitCodeGrace]，进程退出就给退出码，超时给 null。
  Future<int?> _exitCodeOrNull(Process proc) => Future.any<int?>(<Future<int?>>[
        proc.exitCode,
        Future<int?>.delayed(exitCodeGrace, () => null),
      ]);

  /// Android 起不了进程：交给 MainActivity，用 Intent.ACTION_VIEW + FileProvider 分派。
  Future<LaunchResult> _openOnAndroid(String path) async {
    final mime = mimeTypeFor(path);
    try {
      // 没装播放器、Activity 没起来、旧版本没有 openVideo 实现，通道都可能不回话。
      final ok = await _openWithSystem(path, mime).timeout(openTimeout);
      if (!ok) {
        logWarn('Launch', '没有应用能打开 $mime：$path');
        return LaunchResult.failed;
      }
      logInfo('Launch', '已交给系统播放器（$mime）：$path');
      return LaunchResult.ok;
    } catch (e) {
      logWarn('Launch', '外链播放失败：$e');
      return LaunchResult.failed;
    }
  }
}
