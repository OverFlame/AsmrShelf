import 'dart:async';

import 'package:flutter/foundation.dart';

import '../db/track_dao.dart';
import '../state/player_controller.dart';
import 'subtitle_overlay_bridge.dart';
import 'subtitle_parser.dart';
import 'subtitle_timing.dart';

typedef SubtitleLookup = SubtitleDocument Function(TrackItem track);

/// 把当前曲目的字幕行算出来，推给系统级常驻字幕窗口。
///
/// 只负责「什么时候显示哪两句」，不碰播放器与数据库本身。播放器每 250ms
/// 通知一次，这里只在文字变化时下发，避免窗口每帧重画。
class SubtitleOverlayController extends ChangeNotifier {
  SubtitleOverlayController({
    required this.player,
    required this.subtitleFor,
    required this.bridge,
    required this.persistEnabled,
    required this.persistLocked,
  }) {
    player.addListener(_onPlayerChanged);
  }

  final PlayerController player;
  final SubtitleLookup subtitleFor;
  final SubtitleOverlayBridge bridge;
  final Future<void> Function(bool enabled) persistEnabled;
  final Future<void> Function(bool locked) persistLocked;

  bool _enabled = false;
  bool _locked = false;
  bool _visible = false;
  bool _syncing = false;
  String? _lastKey;
  String? _error;

  bool get enabled => _enabled;
  bool get locked => _locked;
  bool get visible => _visible;
  String? get error => _error;

  /// 启动时从设置恢复。权限没给时不弹授权页，静默关闭，避免每次启动打断用户。
  Future<void> configure({required bool enabled, required bool locked}) async {
    _locked = locked;
    _error = null;
    if (!enabled) {
      _enabled = false;
      await _hide();
      notifyListeners();
      return;
    }
    if (!await bridge.hasPermission()) {
      _enabled = false;
      await persistEnabled(false);
      _error = '常驻字幕需要系统悬浮窗权限，请在系统设置里允许后重新打开';
      notifyListeners();
      return;
    }
    _enabled = true;
    final ok = await _sync(force: true);
    if (!ok) {
      _enabled = false;
      await persistEnabled(false);
    }
    notifyListeners();
  }

  /// 返回是否成功进入请求的状态。关闭总是成功。
  Future<bool> setEnabled(bool value) async {
    if (!value) {
      _enabled = false;
      _error = null;
      await persistEnabled(false);
      await _hide();
      notifyListeners();
      return true;
    }
    if (_enabled) return true;

    final allowed = await bridge.requestPermission();
    if (!allowed) {
      _error = '常驻字幕需要系统悬浮窗权限，请在系统设置里允许后重新打开';
      await persistEnabled(false);
      notifyListeners();
      return false;
    }
    _enabled = true;
    _error = null;
    await persistEnabled(true);
    final ok = await _sync(force: true);
    if (!ok) {
      _enabled = false;
      await persistEnabled(false);
      notifyListeners();
      return false;
    }
    notifyListeners();
    return true;
  }

  Future<bool> toggle() => setEnabled(!_enabled);

  Future<void> setLocked(bool value) async {
    _locked = value;
    await persistLocked(value);
    if (_enabled) await bridge.setLocked(value);
    notifyListeners();
  }

  /// 字幕文件换了、曲目刚补完字幕后手动催一次刷新。
  void refresh() {
    if (_enabled) unawaited(_sync(force: true));
  }

  void _onPlayerChanged() {
    if (_enabled) unawaited(_sync());
  }

  Future<bool> _sync({bool force = false}) async {
    if (!_enabled || _syncing) return true;
    _syncing = true;
    try {
      final track = player.currentTrack;
      if (track == null) {
        await _hide();
        return true;
      }
      final doc = subtitleFor(track);
      if (!doc.parsed || doc.lines.isEmpty) {
        await _hide();
        return true;
      }

      var index = doc.hasTiming
          ? subtitleLineIndex(doc.lines, player.position)
          : 0;
      if (index < 0) index = 0;
      var current = doc.lines[index].text.trim();
      if (current.isEmpty) current = '♪';

      var nextIndex = index + 1;
      while (nextIndex < doc.lines.length &&
          doc.lines[nextIndex].text.trim().isEmpty) {
        nextIndex++;
      }
      final next = nextIndex < doc.lines.length
          ? doc.lines[nextIndex].text.trim()
          : '';

      final key = '${track.id ?? track.path}|$current|$next';
      if (!force && _visible && key == _lastKey) return true;

      if (!_visible) {
        final shown = await bridge.show(
          current: current,
          next: next,
          locked: _locked,
        );
        if (!shown) {
          _error = '无法显示常驻字幕，请检查系统悬浮窗权限';
          return false;
        }
        _visible = true;
      } else {
        await bridge.update(current: current, next: next);
      }
      _lastKey = key;
      if (_error != null) {
        _error = null;
        notifyListeners();
      }
      return true;
    } finally {
      _syncing = false;
    }
  }

  Future<void> _hide() async {
    if (_visible) await bridge.hide();
    _visible = false;
    _lastKey = null;
  }

  @override
  void dispose() {
    player.removeListener(_onPlayerChanged);
    super.dispose();
  }
}
