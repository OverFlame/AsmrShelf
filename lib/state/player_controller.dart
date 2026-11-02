import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../db/track_dao.dart';
import '../services/segment_service.dart';
import '../utils/log_util.dart';

enum RepeatMode { off, all, one }

/// 播放器控制器（封装 flutter_soloud / SoLoud）
///
/// 提供播放队列、上一首/下一首、循环/随机、seek、位置流。
class PlayerController extends ChangeNotifier {
  SoLoud? _soloud;
  SoLoud get _engine => _soloud ??= SoLoud.instance;
  bool _initialized = false;

  List<TrackItem> _queue = [];
  int _index = -1;

  AudioSource? _source;
  SoundHandle? _handle;
  StreamSubscription<StreamSoundEvent>? _sub;

  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  RepeatMode _repeat = RepeatMode.all;
  bool _shuffle = false;
  double _volume = 1.0;
  double _speed = 1.0;

  /// 正在循环的收藏选段。为空表示没开选区循环（BUILD_GUIDE 第 24.3 节）。
  MediaSegment? _loopSegment;

  /// 洗牌顺序：队列下标的一个排列。播放按 _order 走，一轮内不重复。
  List<int> _order = [];
  int _orderPos = -1;

  bool get initialized => _initialized;
  bool get playing => _playing;
  Duration get position => _position;
  Duration get duration => _duration;
  RepeatMode get repeatMode => _repeat;
  bool get shuffle => _shuffle;
  double get volume => _volume;
  double get speed => _speed;

  /// 当前循环的选段，未开启时为 null
  MediaSegment? get loopSegment => _loopSegment;

  /// 是否开着选段循环
  bool get segmentLoopEnabled => _loopSegment != null;

  bool get hasTrack => _index >= 0 && _index < _queue.length;
  TrackItem? get currentTrack =>
      hasTrack ? _queue[_index] : null;
  int get queueLength => _queue.length;

  /// 当前队列的只读视图，供播放队列面板显示
  List<TrackItem> get queue => List.unmodifiable(_queue);

  /// 当前曲目在队列中的下标；无曲目时为 -1
  int get index => _index;

  /// 播放速度的下限、上限与步长
  static const double minSpeed = 0.5;
  static const double maxSpeed = 2.0;
  static const double speedStep = 0.25;

  /// 洗牌顺序的只读视图，仅供用例断言
  @visibleForTesting
  List<int> get shuffleOrder => List.unmodifiable(_order);

  /// 每首曲目开始播放时回调（用于记录播放历史）
  void Function(TrackItem track)? onTrackStarted;

  /// 循环模式变化后回调（用于持久化设置）
  void Function(RepeatMode mode)? onRepeatModeChanged;

  /// 随机开关变化后回调（用于持久化设置）
  void Function(bool shuffle)? onShuffleChanged;

  /// 播放速度变化后回调（用于持久化设置）
  void Function(double speed)? onSpeedChanged;

  /// 每次要播一首曲目时问一次「从哪儿接着放」，返回 [Duration.zero] 表示从头。
  ///
  /// 引擎的 play 没有起始位置参数，所以非零值由控制器 play 之后再 seek。
  Duration Function(TrackItem track)? resumeFrom;

  /// 播放中的位置变化（约每 250 毫秒一次，暂停时不报）
  void Function(TrackItem track, Duration position)? onPositionChanged;

  /// 一首正常播完、即将切下一首时回调
  void Function(TrackItem track)? onTrackCompleted;

  Timer? _ticker;

  /// 初始化共享 Future：并发调用只初始化一次
  Future<void>? _initFuture;

  /// 加载代际：快速连续切歌时，过期请求作废，避免多轨同时播放
  int _loadGen = 0;

  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    await _engine.init();
    _initialized = true;
    logInfo('Player', 'SoLoud initialized');
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _updatePosition();
    });
  }

  void _updatePosition() {
    final h = _handle;
    if (h == null) return;
    try {
      final next = _engine.getPosition(h);
      // 暂停时位置不变，旧实现每 250ms 还是通知一次，整页跟着重建。
      final changed = next != _position;
      _position = next;
      if (_playing && hasTrack) {
        onPositionChanged?.call(_queue[_index], _position);
      }
      if (changed) notifyListeners();
    } catch (_) {
      // handle 已失效（例如刚播完），忽略
    }
  }

  /// 设置播放队列并开始播放第 [startIndex] 首
  Future<void> playQueue(List<TrackItem> tracks, {int startIndex = 0}) async {
    if (!_initialized) await init();
    _queue = List.from(tracks);
    _index = _queue.isEmpty ? -1 : startIndex.clamp(0, _queue.length - 1);
    if (_shuffle) _rebuildOrder();
    await _loadAndPlay();
  }

  Future<void> _loadAndPlay() async {
    if (!_initialized) {
      // 未初始化时不触碰原生引擎，只同步队列状态。
      // 这样用例能在没有原生库的环境里验证队列与洗牌逻辑。
      _playing = false;
      notifyListeners();
      return;
    }
    final gen = ++_loadGen; // 本次加载代际
    await _disposeCurrent();
    // 释放期间可能已有更新的请求，放弃本次
    if (gen != _loadGen) return;

    if (!hasTrack) {
      _playing = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      notifyListeners();
      return;
    }
    final track = _queue[_index];

    AudioSource? newSource;
    try {
      newSource = await _engine.loadFile(track.path);
    } catch (e) {
      logError('Player', '加载失败 ${track.path}: $e');
      if (gen == _loadGen) {
        _playing = false;
        notifyListeners();
      }
      return;
    }

    // 加载耗时期间若已有新的点击，丢弃这次已加载的资源，避免多轨同时播放
    if (gen != _loadGen) {
      try {
        await _engine.disposeSource(newSource);
      } catch (_) {}
      return;
    }

    _source = newSource;
    _duration = _engine.getLength(newSource);
    // 换了曲目就丢掉上一首的选区，避免循环范围串到新曲目
    if (_loopSegment != null && _loopSegment!.mediaId != track.id) {
      _loopSegment = null;
    }
    final segment = _loopSegment;
    // 续播只在没有选区时问起：选区循环有自己的起点
    var resume = segment == null
        ? (resumeFrom?.call(track) ?? Duration.zero)
        : Duration.zero;
    if (resume < Duration.zero) resume = Duration.zero;
    _handle = segment == null
        ? _engine.play(newSource, volume: _volume)
        : _engine.play(
            newSource,
            volume: _volume,
            looping: true,
            loopingStartAt: Duration(milliseconds: segment.startMs),
            loopingEndAt: Duration(milliseconds: segment.endMs),
          );
    if (resume > Duration.zero) {
      final h = _handle;
      if (h == null) {
        resume = Duration.zero;
      } else {
        try {
          _engine.seek(h, resume);
        } catch (e) {
          logWarn('Player', '续播定位失败，从头播: $e');
          resume = Duration.zero;
        }
      }
    }
    _applySpeed();
    _listenEnd();
    _playing = true;
    _position = segment == null
        ? resume
        : Duration(milliseconds: segment.startMs);
    logInfo('Player', '播放: ${track.path}');
    onTrackStarted?.call(track);
    notifyListeners();
  }

  void _listenEnd() {
    _sub?.cancel();
    final src = _source;
    if (src == null) return;
    _sub = src.soundEvents.listen((e) {
      if (e.event == SoundEventType.handleIsNoMoreValid) {
        _onEnded();
      }
    });
  }

  Future<void> _onEnded() async {
    final seg = _loopSegment;
    if (seg != null && _source != null) {
      // 选区循环：引擎按边界自己回绕，这里兜住句柄失效的情况
      _handle = _engine.play(
        _source!,
        volume: _volume,
        looping: true,
        loopingStartAt: Duration(milliseconds: seg.startMs),
        loopingEndAt: Duration(milliseconds: seg.endMs),
      );
      _applySpeed();
      _position = Duration(milliseconds: seg.startMs);
      _playing = true;
      notifyListeners();
      return;
    }
    if (_repeat == RepeatMode.one && _source != null) {
      // 单曲循环：重新播放同一 source
      _handle = _engine.play(_source!, volume: _volume);
      _position = Duration.zero;
      _playing = true;
      notifyListeners();
      return;
    }
    final finished = hasTrack ? _queue[_index] : null;
    if (finished != null) onTrackCompleted?.call(finished);
    await next(auto: true);
  }

  Future<void> togglePlay() async {
    if (!_initialized) await init();
    if (_handle == null) {
      if (_queue.isNotEmpty) await _loadAndPlay();
      return;
    }
    if (_playing) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> play() async {
    if (_handle == null) {
      await _loadAndPlay();
      return;
    }
    _engine.setPause(_handle!, false);
    _playing = true;
    notifyListeners();
  }

  Future<void> pause() async {
    if (_handle == null) return;
    _engine.setPause(_handle!, true);
    _playing = false;
    notifyListeners();
  }

  Future<void> resume() async {
    if (_handle == null) return;
    _engine.setPause(_handle!, false);
    _playing = true;
    notifyListeners();
  }

  Future<void> seek(Duration d) async {
    final h = _handle;
    if (h == null) return;
    try {
      _engine.seek(h, d);
      _position = d;
      notifyListeners();
    } catch (e) {
      logWarn('Player', 'seek 失败: $e');
    }
  }

  Future<void> next({bool auto = false}) async {
    if (_queue.isEmpty) return;
    if (_shuffle) {
      if (!await _advanceShuffle()) return; // 一轮走完且不循环：已停止
    } else if (_index < _queue.length - 1) {
      _index++;
    } else if (_repeat == RepeatMode.all) {
      _index = 0;
    } else {
      // 列表播完且非循环：停在末尾
      await stop();
      return;
    }
    await _loadAndPlay();
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    if (_position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    if (_shuffle) {
      if (_order.length != _queue.length) _rebuildOrder();
      if (_orderPos > 0) {
        _orderPos--;
      } else if (_repeat == RepeatMode.all) {
        _orderPos = _order.length - 1;
      } else {
        await seek(Duration.zero);
        return;
      }
      _index = _order[_orderPos];
    } else if (_index > 0) {
      _index--;
    } else if (_repeat == RepeatMode.all) {
      _index = _queue.length - 1;
    } else {
      await seek(Duration.zero);
      return;
    }
    await _loadAndPlay();
  }

  /// 按洗牌顺序前进一步。
  ///
  /// 一轮走完时：RepeatMode.off 停止播放，其余模式重开一轮。
  /// 返回 false 表示播放已停止，调用方不要再加载。
  Future<bool> _advanceShuffle() async {
    if (_order.length != _queue.length) _rebuildOrder();
    _orderPos++;
    if (_orderPos >= _order.length) {
      if (_repeat == RepeatMode.off) {
        await stop();
        return false;
      }
      _rebuildOrder(anchorCurrent: false);
    }
    _index = _order[_orderPos];
    return true;
  }

  /// 重排洗牌顺序。
  ///
  /// [anchorCurrent] 为真时把当前曲目放到队首，随后的 next 不会立刻重复它。
  void _rebuildOrder({bool anchorCurrent = true}) {
    final n = _queue.length;
    _order = List<int>.generate(n, (i) => i);
    if (n > 1) {
      final rnd = Random();
      for (var i = n - 1; i > 0; i--) {
        final j = rnd.nextInt(i + 1);
        final tmp = _order[i];
        _order[i] = _order[j];
        _order[j] = tmp;
      }
      if (anchorCurrent && _index >= 0 && _index < n) {
        final pos = _order.indexOf(_index);
        if (pos > 0) {
          final cur = _order.removeAt(pos);
          _order.insert(0, cur);
        }
      }
    }
    _orderPos = 0;
  }

  void setRepeatMode(RepeatMode m) {
    if (_repeat == m) return;
    _repeat = m;
    onRepeatModeChanged?.call(m);
    notifyListeners();
  }

  void setShuffle(bool on) {
    if (_shuffle == on) return;
    _shuffle = on;
    if (on) {
      _rebuildOrder();
    } else {
      _order = [];
      _orderPos = -1;
    }
    onShuffleChanged?.call(on);
    notifyListeners();
  }

  void toggleShuffle() => setShuffle(!_shuffle);

  /// 设置播放速度，钳制在 [minSpeed] 与 [maxSpeed] 之间
  Future<void> setSpeed(double v) async {
    final next = v.clamp(minSpeed, maxSpeed).toDouble();
    if (next == _speed) return;
    _speed = next;
    _applySpeed();
    onSpeedChanged?.call(_speed);
    notifyListeners();
  }

  /// 按步长调速，[steps] 为正加快、为负减慢
  Future<void> stepSpeed(int steps) => setSpeed(_speed + speedStep * steps);

  /// 把当前速度应用到正在播放的句柄
  void _applySpeed() {
    final h = _handle;
    if (h == null) return;
    try {
      _engine.setRelativePlaySpeed(h, _speed);
    } catch (e) {
      logWarn('Player', '设置播放速度失败: $e');
    }
  }

  // ── 收藏选段（BUILD_GUIDE 第 24.3 节） ──

  /// 开启或关闭选段循环，[seg] 为 null 时关闭
  Future<void> setLoopSegment(MediaSegment? seg) async {
    if (seg == null) {
      if (_loopSegment == null) return;
      _loopSegment = null;
      _applyLoopPoints();
      notifyListeners();
      return;
    }
    final cur = _loopSegment;
    if (cur != null &&
        cur.mediaId == seg.mediaId &&
        cur.startMs == seg.startMs &&
        cur.endMs == seg.endMs) {
      return;
    }
    _loopSegment = seg;
    _applyLoopPoints();
    // 选区已生效时跳到段首，避免停在段外
    if (_handle != null) await seek(Duration(milliseconds: seg.startMs));
    notifyListeners();
  }

  /// 把选段循环应用到正在播放的句柄。未初始化时直接返回，用例不碰原生库。
  void _applyLoopPoints() {
    final h = _handle;
    if (!_initialized || h == null) return;
    final seg = _loopSegment;
    try {
      if (seg == null) {
        _engine.setLooping(h, false);
        _engine.setLoopEndPoint(h, null);
        return;
      }
      // 先放开终点，避免起点越过旧终点时校验失败
      _engine.setLooping(h, true);
      _engine.setLoopEndPoint(h, null);
      _engine.setLoopPoint(h, Duration(milliseconds: seg.startMs));
      _engine.setLoopEndPoint(h, Duration(milliseconds: seg.endMs));
    } catch (e) {
      logWarn('Player', '设置选段循环失败: $e');
    }
  }

  Future<void> setVolume(double v) async {
    final next = v.clamp(0.0, 1.0);
    if (next == _volume) return;
    _volume = next;
    final h = _handle;
    if (h != null) {
      try {
        _engine.setVolume(h, _volume);
      } catch (_) {}
    }
    notifyListeners();
  }

  // ── 队列编辑 ──

  /// 把 [track] 插到当前曲目之后，作为下一首播放
  Future<void> playNext(TrackItem track) async {
    if (!hasTrack) {
      await playQueue([track]);
      return;
    }
    _queue.insert(_index + 1, track);
    if (_shuffle) _rebuildOrder();
    notifyListeners();
  }

  /// 从队列移除第 [i] 首。移除的是当前曲目时接着播放下一个。
  Future<void> removeAt(int i) async {
    if (i < 0 || i >= _queue.length) return;
    final removingCurrent = i == _index;
    _queue.removeAt(i);
    if (_queue.isEmpty) {
      await stop();
      return;
    }
    if (i < _index) {
      _index--; // 当前曲目前移一位，下标跟着走
    } else if (removingCurrent && _index >= _queue.length) {
      _index = _queue.length - 1; // 删的是最后一项，落到新的末尾
    }
    if (_shuffle) _rebuildOrder();
    if (removingCurrent) {
      await _loadAndPlay();
      return;
    }
    notifyListeners();
  }

  /// 拖动排序。索引语义同 ReorderableListView：newIndex 是拖入前的目标位置。
  /// 把队列第 [oldIndex] 首移到 [newIndex]（用移除之后的下标，与
  /// ReorderableListView.onReorderItem 的口径一致）
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    var target = newIndex;
    if (target < 0) target = 0;
    if (target >= _queue.length) target = _queue.length - 1;
    if (target == oldIndex) return;
    final current = hasTrack ? _queue[_index] : null;
    final moved = _queue.removeAt(oldIndex);
    _queue.insert(target, moved);
    if (current != null) {
      final pos = _queue.indexWhere((e) => identical(e, current));
      if (pos >= 0) _index = pos;
    }
    if (_shuffle) _rebuildOrder();
    notifyListeners();
  }

  /// 跳到队列第 [i] 首播放
  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= _queue.length) return;
    _index = i;
    if (_shuffle) {
      if (_order.length != _queue.length) _rebuildOrder();
      final pos = _order.indexOf(i);
      _orderPos = pos >= 0 ? pos : 0;
    }
    await _loadAndPlay();
  }

  /// 直接把队列放进控制器，不触碰原生引擎。仅供用例。
  @visibleForTesting
  void debugSeedQueue(List<TrackItem> tracks,
      {int startIndex = 0, Duration? duration}) {
    _queue = List.from(tracks);
    _index = _queue.isEmpty ? -1 : startIndex.clamp(0, _queue.length - 1);
    if (duration != null) _duration = duration;
    if (_shuffle) _rebuildOrder();
  }

  /// 直接改当前位置，不触碰原生引擎。仅供用例。
  @visibleForTesting
  void debugSetPosition(Duration position) {
    _position = position;
    notifyListeners();
  }

  Future<void> stop() async {
    _loadGen++; // 使进行中的加载失效，避免停止后又冒出声音
    await _disposeCurrent();
    _playing = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _index = -1;
    _queue = [];
    _loopSegment = null;
    notifyListeners();
  }

  Future<void> _disposeCurrent() async {
    // 先摘除字段再异步释放，避免并发调用重复释放同一资源
    final h = _handle;
    final s = _source;
    final sub = _sub;
    _handle = null;
    _source = null;
    _sub = null;
    sub?.cancel();
    if (h != null) {
      try {
        await _engine.stop(h);
      } catch (_) {}
    }
    if (s != null) {
      try {
        await _engine.disposeSource(s);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    _engine.deinit();
    super.dispose();
  }
}
