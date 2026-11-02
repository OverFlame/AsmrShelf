import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../db/track_dao.dart';
import '../state/app_state.dart';
import '../state/player_controller.dart';
import '../utils/log_util.dart';

/// 一次通知同步需要的播放状态。
class _SyncState {
  final TrackItem track;
  final bool playing;
  final Duration position;
  final Duration duration;

  const _SyncState(this.track, this.playing, this.position, this.duration);
}

/// Android 侧桥接：后台播放通知栏 + 「所有文件访问」授权。
/// 桌面端（Windows/Linux）自动退化为 no-op。
class MediaBridge {
  MediaBridge._();

  static final MediaBridge instance = MediaBridge._();

  /// 平台通道。测试用它挂 mock handler。
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('asmrshelf/playback');

  PlayerController? _player;
  AppState? _appState;
  bool _serviceStarted = false;
  String _lastKey = '';
  _SyncState? _pendingState;
  Future<void>? _drain;

  /// 平台通道调用超时。原生侧挂死时没有超时，通知同步会永远卡住（报告第 26 项）。
  @visibleForTesting
  Duration callTimeout = const Duration(seconds: 5);

  /// 测试用：测试宿主是 Linux，强行走 Android 分支。
  @visibleForTesting
  bool forceAndroid = false;

  bool get isAndroid => forceAndroid || (!kIsWeb && Platform.isAndroid);

  Future<void> init(PlayerController player, AppState appState) async {
    _player = player;
    _appState = appState;
    if (!isAndroid) return;
    channel.setMethodCallHandler(_onNativeCall);
    player.addListener(_onPlayerChanged);
    logInfo('MediaBridge', 'initialized (Android)');
  }

  /// 发一次平台通道调用，返回「是否成功」和返回值。
  Future<(bool, T?)> _invoke<T>(String method, [Object? args]) async {
    try {
      final value =
          await channel.invokeMethod<T>(method, args).timeout(callTimeout);
      return (true, value);
    } catch (e) {
      logWarn('MediaBridge', '$method 失败: $e');
      return (false, null);
    }
  }

  // ═══════════════ 权限 ═══════════════

  /// 是否已获得「所有文件访问」授权
  Future<bool> hasAllFilesAccess() async {
    if (!isAndroid) return true;
    final (ok, granted) = await _invoke<bool>('checkAllFilesAccess');
    return ok && (granted ?? false);
  }

  /// 跳转到系统「所有文件访问」授权页
  Future<void> requestAllFilesAccess() async {
    if (!isAndroid) return;
    await _invoke('requestAllFilesAccess');
  }

  /// 导入前核对「所有文件访问」。桌面端恒为 true，不动通道。
  ///
  /// 未授权时跳到系统设置页并返回 false：授权要用户在系统界面里完成，
  /// 这里等不到结果，界面负责提示「授权后重试」。
  Future<bool> ensureScanAccess() async {
    if (!isAndroid) return true;
    if (await hasAllFilesAccess()) return true;
    await requestAllFilesAccess();
    return await hasAllFilesAccess();
  }

  /// 确保通知权限（Android 13+）
  Future<void> ensureNotificationPermission() async {
    if (!isAndroid) return;
    final (ok, granted) = await _invoke<bool>('checkNotificationPermission');
    if (ok && granted == false) {
      await _invoke('requestNotificationPermission');
    }
  }

  // ═══════════════ 服务 / 通知 ═══════════════

  Future<void> _startService() async {
    if (!isAndroid || _serviceStarted) return;
    final (ok, _) = await _invoke('startPlaybackService');
    if (ok) _serviceStarted = true;
    // 起不来就让它失败：这次通知丢掉，但去重键也不写，
    // 下一次状态变化会重新起服务并补发（报告第 26 项）。
  }

  Future<void> stopService() async {
    if (!isAndroid) return;
    _serviceStarted = false;
    _lastKey = '';
    await _invoke('stopPlaybackService');
  }

  void _onPlayerChanged() {
    final player = _player;
    if (player == null) return;
    final track = player.currentTrack;

    if (track == null) {
      // 停止/清空队列 → 停掉前台服务
      if (_serviceStarted) unawaited(stopService());
      return;
    }

    unawaited(_requestSync(_SyncState(
      track,
      player.playing,
      player.position,
      player.duration,
    )));
  }

  /// 把一次状态变化交给同步状态机。
  ///
  /// 同一时刻只跑一次原生同步；同步期间来的新状态覆盖等待中的状态，合并成
  /// 一次补跑，不会堆出几十个平台通道调用。返回值等本轮同步结束。
  Future<void> _requestSync(_SyncState state) {
    _pendingState = state;
    final running = _drain;
    if (running != null) return running;
    final drain = _drainSync();
    _drain = drain;
    return drain;
  }

  Future<void> _drainSync() async {
    try {
      while (_pendingState != null) {
        final state = _pendingState!;
        _pendingState = null;
        await _syncOnce(state);
      }
    } finally {
      // 这一段同步执行，不会有新请求插进来。
      _drain = null;
    }
  }

  Future<void> _syncOnce(_SyncState state) async {
    final cover = _appState?.coverForTrack(state.track);
    final key = '${state.track.path}|${state.playing}|'
        '${state.duration.inMilliseconds}|${state.position.inSeconds}|$cover';
    if (_serviceStarted && key == _lastKey) return;

    // 先起服务再发通知：通知挂在前台服务上，服务没起来就发会被丢掉。
    await _startService();
    if (!_serviceStarted) return;

    final (ok, _) = await _invoke('updateNotification', <String, dynamic>{
      'title': state.track.displayTitle,
      'artist': state.track.artist ?? state.track.album ?? '',
      'playing': state.playing,
      'positionMs': state.position.inMilliseconds,
      'durationMs': state.duration.inMilliseconds,
      'coverPath': cover,
    });
    // 发出去了才记去重键；失败的话下次状态变化还会重发。
    if (ok) _lastKey = key;
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    final player = _player;
    if (player == null) return null;
    switch (call.method) {
      case 'onPlayPause':
        await player.togglePlay();
        break;
      case 'onNext':
        await player.next();
        break;
      case 'onPrevious':
        await player.previous();
        break;
      case 'onSeekTo':
        final ms = (call.arguments as num?)?.toInt() ?? 0;
        await player.seek(Duration(milliseconds: ms));
        break;
      case 'onStop':
        await player.stop();
        await stopService();
        break;
    }
    return null;
  }

  void dispose() {
    if (!isAndroid) return;
    _player?.removeListener(_onPlayerChanged);
  }

  /// 测试用：直接跑一次同步，等本轮同步（含合并进来的补跑）结束。
  @visibleForTesting
  Future<void> debugSync(
    TrackItem track, {
    bool playing = false,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
  }) {
    return _requestSync(_SyncState(track, playing, position, duration));
  }

  /// 测试用：清掉单例状态。
  @visibleForTesting
  void resetForTest() {
    _player = null;
    _appState = null;
    _serviceStarted = false;
    _lastKey = '';
    _pendingState = null;
    _drain = null;
    forceAndroid = false;
    callTimeout = const Duration(seconds: 5);
  }
}
