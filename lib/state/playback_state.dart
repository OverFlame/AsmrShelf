import 'dart:async';

import 'package:flutter/foundation.dart';

import '../db/media_dao.dart';
import '../services/segment_service.dart';
import '../db/track_dao.dart';
import '../services/play_position.dart';
import '../state/player_controller.dart';
import '../utils/log_util.dart';

/// 播放状态：队列命令、播放历史、选段与续播位置。
///
/// 拆分自 `AppState`。队列本身在 [PlayerController]，这里只做「取哪些曲目、
/// 从哪首开始」与「播完写回什么」；改当前列表由 [onTracksChanged] 回调交给
/// `AppState`，所以不 import 别的状态对象。
class PlaybackState extends ChangeNotifier {
  PlaybackState({
    required this.player,
    required this.trackDao,
    required this.mediaDao,
    required this.segmentService,
    required this.currentTracks,
    required this.onTracksChanged,
    required this.rememberQueueCover,
    required this.queueCoverPath,
  });

  final PlayerController player;
  final TrackDao Function() trackDao;
  final MediaDao Function() mediaDao;
  final SegmentService Function() segmentService;

  /// 当前中间栏的曲目（播放「全部」时用）。
  final List<TrackItem> Function() currentTracks;

  /// 把新的曲目列表写回作品库（续播位置变了）。
  final void Function(List<TrackItem> tracks) onTracksChanged;

  /// 队列来源作品的封面，交给 `CoverState`。
  final void Function(String? coverPath) rememberQueueCover;

  /// 当前作品的封面路径；最近播放跨作品，用它时传 null。
  final String? Function() queueCoverPath;

  List<TrackItem> recentTracks = const [];
  int _recentLoadGeneration = 0;
  List<MediaSegment> segments = const [];

  /// 播放位置落盘的节流（见 lib/services/play_position.dart）
  final PlayPositionThrottle _positionThrottle = PlayPositionThrottle();

  // ═══════════════ 队列 ═══════════════

  /// 播放当前列表从 [startIndex] 开始
  Future<void> playTracks(List<TrackItem> list, int startIndex) async {
    _rememberQueueCover();
    await player.playQueue(list, startIndex: startIndex);
  }

  Future<void> playAllCurrent() async {
    final tracks = currentTracks();
    if (tracks.isEmpty) return;
    _rememberQueueCover();
    await player.playQueue(tracks, startIndex: 0);
  }

  Future<void> playTrackAt(int index) async {
    final tracks = currentTracks();
    if (index < 0 || index >= tracks.length) return;
    _rememberQueueCover();
    await player.playQueue(tracks, startIndex: index);
  }

  /// 最近播放跨作品，没有单一来源封面，回退到每首曲目自己的封面。
  Future<void> playRecent(int startIndex) async {
    if (recentTracks.isEmpty) return;
    rememberQueueCover(null);
    await player.playQueue(recentTracks, startIndex: startIndex);
  }

  void _rememberQueueCover() => rememberQueueCover(queueCoverPath());

  // ═══════════════ 选段 ═══════════════

  /// 载入当前曲目的选段。没有曲目时清空列表。
  Future<void> reloadSegments() async {
    final id = player.currentTrack?.id;
    if (id == null) {
      assignSegments(const []);
      return;
    }
    await reloadSegmentsFor(id);
  }

  Future<void> reloadSegmentsFor(int mediaId) async {
    assignSegments(await segmentService().listByMedia(mediaId));
  }

  /// 列表真的变了才通知：切歌时顺带载入选段，不该多出无谓的重建。
  void assignSegments(List<MediaSegment> list) {
    if (_sameSegments(segments, list)) return;
    segments = list;
    notifyListeners();
  }

  static bool _sameSegments(List<MediaSegment> a, List<MediaSegment> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 保存一段选区。起止按当前曲目时长收口。
  Future<MediaSegment?> addSegment({
    required int startMs,
    required int endMs,
    String? name,
  }) async {
    final id = player.currentTrack?.id;
    if (id == null) return null;
    final seg = await segmentService().add(
      mediaId: id,
      startMs: startMs,
      endMs: endMs,
      durationMs: player.duration.inMilliseconds,
      name: name,
    );
    await reloadSegmentsFor(id);
    return seg;
  }

  Future<void> renameSegment(MediaSegment seg, String? name) async {
    final id = seg.id;
    if (id == null) return;
    await segmentService().rename(id, name);
    await reloadSegments();
  }

  /// 删除一段。删掉的正是当前循环段时同时关掉选区循环。
  Future<void> deleteSegment(MediaSegment seg) async {
    final id = seg.id;
    if (id == null) return;
    final looping = player.loopSegment;
    if (looping != null && looping.id == id) {
      await player.setLoopSegment(null);
    }
    await segmentService().remove(id);
    await reloadSegments();
  }

  /// 开启或关闭选段循环。[seg] 为 null 时关闭。
  Future<void> loopSegment(MediaSegment? seg) => player.setLoopSegment(seg);

  /// 跳到段首播放
  Future<void> jumpToSegment(MediaSegment seg) =>
      player.seek(Duration(milliseconds: seg.startMs));

  // ═══════════════ 播放事件 ═══════════════

  void onTrackStarted(TrackItem track) {
    final id = track.id;
    if (id == null) return;
    unawaited(reloadSegmentsFor(id));
    final gen = ++_recentLoadGeneration;
    unawaited(trackDao().recordPlay(id, DateTime.now().millisecondsSinceEpoch).then(
        (_) => _reloadRecent(gen)).catchError((Object e) {
      logError('PlaybackState', 'recordPlay 失败: $e');
    }));
  }

  /// 续播位置：太靠前、或快听完的位置都从头开始（见 PlayPositionRules）。
  Duration resumeOf(TrackItem track) =>
      PlayPositionRules.resumeOf(track.playPositionMs, track.durationMs);

  /// 播放中每 250 毫秒报一次位置，按前进量节流后才写库。
  void onPosition(TrackItem track, Duration position) {
    final id = track.id;
    if (id == null) return;
    if (!_positionThrottle.shouldSave(position)) return;
    savePosition(id, position.inMilliseconds);
  }

  /// 一首播到结尾：位置清零，下次从头播。
  void onTrackCompleted(TrackItem track) {
    final id = track.id;
    if (id == null) return;
    _positionThrottle.reset();
    savePosition(id, 0);
  }

  void savePosition(int mediaId, int positionMs) {
    unawaited(mediaDao().setPlayPosition(mediaId, positionMs).then((_) {
      // 磁贴右侧的「已播时间」跟着刷新
      _applyPosition(mediaId, positionMs);
    }).catchError((Object e) {
      logError('PlaybackState', '播放位置落盘失败: $e');
    }));
  }

  /// 把新位置同步进内存里的曲目列表（不重新查库）。
  void _applyPosition(int mediaId, int positionMs) {
    var changed = false;
    final next = <TrackItem>[];
    for (final track in currentTracks()) {
      if (track.id == mediaId && track.playPositionMs != positionMs) {
        changed = true;
        next.add(track.copyWith(playPositionMs: positionMs));
      } else {
        next.add(track);
      }
    }
    if (!changed) return;
    onTracksChanged(next);
  }

  // ═══════════════ 最近播放 ═══════════════

  Future<void> loadRecent() => _reloadRecent(_recentLoadGeneration);

  /// 只有最后一次触发的重载能写回结果。
  ///
  /// 快速切歌会并发触发多次 recordPlay 与多次重载，先发起的那次可能后完成。
  Future<void> _reloadRecent(int gen) async {
    final list = await trackDao().recentPlayedTracks();
    if (gen != _recentLoadGeneration) {
      logInfo('PlaybackState', 'recent gen=$gen 已被取代，丢弃结果');
      return;
    }
    recentTracks = list;
    notifyListeners();
  }
}
