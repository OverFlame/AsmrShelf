import 'dart:async';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import '../utils/log_util.dart';

/// 一卷的阅读进度，对应 `reading_progress` 表的一行。
///
/// 表结构（v8，`lib/db/tables.dart`）：
/// `volume_id INTEGER PRIMARY KEY REFERENCES folders(id) ON DELETE CASCADE`、
/// `media_id INTEGER REFERENCES media(id) ON DELETE SET NULL`、
/// `page_index INTEGER NOT NULL DEFAULT 0`、
/// `finished INTEGER NOT NULL DEFAULT 0`、
/// `updated_at INTEGER NOT NULL`。
class ReadingProgress {
  const ReadingProgress({
    required this.volumeId,
    this.mediaId,
    this.pageIndex = 0,
    this.finished = false,
    required this.updatedAt,
  });

  /// 卷 = `folders.id`
  final int volumeId;

  /// 上次读到的图片行；卷被清空或图片被删时可能为 null
  final int? mediaId;

  /// 卷内页序（0 基）
  final int pageIndex;

  /// 是否已读完
  final bool finished;

  /// 落盘时刻，Unix 毫秒；由注入的时钟决定
  final int updatedAt;

  ReadingProgress copyWith({
    int? mediaId,
    bool clearMediaId = false,
    int? pageIndex,
    bool? finished,
    int? updatedAt,
  }) {
    return ReadingProgress(
      volumeId: volumeId,
      mediaId: clearMediaId ? null : (mediaId ?? this.mediaId),
      pageIndex: pageIndex ?? this.pageIndex,
      finished: finished ?? this.finished,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'volume_id': volumeId,
        'media_id': mediaId,
        'page_index': pageIndex,
        'finished': finished ? 1 : 0,
        'updated_at': updatedAt,
      };

  static ReadingProgress fromMap(Map<String, Object?> map) {
    final finished = map['finished'];
    return ReadingProgress(
      volumeId: map['volume_id']! as int,
      mediaId: map['media_id'] as int?,
      pageIndex: (map['page_index'] as int?) ?? 0,
      finished: finished is int ? finished != 0 : (finished as bool? ?? false),
      updatedAt: (map['updated_at'] as int?) ?? 0,
    );
  }

  @override
  String toString() =>
      'ReadingProgress(volume=$volumeId, media=$mediaId, page=$pageIndex, '
      'finished=$finished, updatedAt=$updatedAt)';
}

/// 节流用的定时器抽象，方便测试用假定时器驱动，不依赖真实等待。
abstract class ThrottleScheduler {
  /// 延迟 [delay] 后执行 [action]，返回一个可传给 [cancel] 的句柄
  Object schedule(Duration delay, void Function() action);

  /// 取消 [schedule] 返回的句柄
  void cancel(Object handle);
}

/// 生产实现：真的起一个 [Timer]
class TimerThrottleScheduler implements ThrottleScheduler {
  const TimerThrottleScheduler();

  @override
  Object schedule(Duration delay, void Function() action) =>
      Timer(delay, action);

  @override
  void cancel(Object handle) {
    if (handle is Timer) handle.cancel();
  }
}

/// 阅读进度读写（BUILD_GUIDE 第 22.6 节）。
///
/// 写入按 [throttle]（默认 1 秒，指南要求 1 秒级）节流：
/// - 距上次落盘超过一个窗口 → 立刻写；
/// - 窗口内的继续写入先攒在内存，只在窗口末尾补一次（trailing）；
/// - 窗口内无论写多少次，落盘次数只加一；
/// - [flush] 是强制通道，忽略窗口立刻落盘，离开阅读器前调用。
///
/// [clock] 与 [scheduler] 都可注入：测试用假时钟 + 假定时器驱动，
/// 不需要真的 `await Future.delayed`。`updated_at` 取 [clock] 的值。
class ReadingProgressService {
  ReadingProgressService(
    Database db, {
    Duration? throttle,
    DateTime Function()? clock,
    ThrottleScheduler? scheduler,
    void Function(int volumeId, ReadingProgress progress)? persistListener,
  })  : _db = db,
        _throttle = throttle ?? const Duration(seconds: 1),
        _clock = clock ?? DateTime.now,
        _scheduler = scheduler ?? const TimerThrottleScheduler(),
        _onPersist = persistListener;

  static const String _table = 'reading_progress';

  final Database _db;
  final Duration _throttle;
  final DateTime Function() _clock;
  final ThrottleScheduler _scheduler;
  final void Function(int volumeId, ReadingProgress progress)? _onPersist;

  /// 还没落盘的进度，按 volume_id 去重（窗口内后写覆盖先写）
  final Map<int, ReadingProgress> _pending = <int, ReadingProgress>{};

  Object? _timer;
  DateTime? _lastWriteAt;
  int _writeCount = 0;
  bool _disposed = false;

  /// 已经真正写库的次数，测试用来断言节流生效
  int get writeCount => _writeCount;

  /// 是否有攒着没落盘的进度
  bool get hasPending => _pending.isNotEmpty;

  /// 是否已经 dispose
  bool get isDisposed => _disposed;

  /// 当前节流窗口长度
  Duration get throttle => _throttle;

  /// 待落盘的卷号（测试用）
  List<int> get pendingVolumeIds => _pending.keys.toList(growable: false);

  // ═══ 读 ═══

  /// 读一卷的进度；没有记录返回 null。未落盘的 pending 会覆盖库里的值。
  Future<ReadingProgress?> get(int volumeId) async {
    final pending = _pending[volumeId];
    if (pending != null) return pending;

    final rows = await _db.query(
      _table,
      where: 'volume_id = ?',
      whereArgs: <Object?>[volumeId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ReadingProgress.fromMap(rows.first);
  }

  /// 一次读多卷的进度（图片库列表页给每张卷卡片显示角标用）。
  ///
  /// 返回值里只包含有记录的卷；pending 覆盖库值。
  Future<Map<int, ReadingProgress>> getMany(Iterable<int> volumeIds) async {
    final ids = volumeIds.toSet().toList(growable: false);
    final out = <int, ReadingProgress>{};
    if (ids.isEmpty) return out;

    const chunk = 500;
    for (var start = 0; start < ids.length; start += chunk) {
      final slice = ids.sublist(
          start, math.min(start + chunk, ids.length));
      final placeholders = List.filled(slice.length, '?').join(',');
      final rows = await _db.query(
        _table,
        where: 'volume_id IN ($placeholders)',
        whereArgs: slice,
      );
      for (final row in rows) {
        final progress = ReadingProgress.fromMap(row);
        out[progress.volumeId] = progress;
      }
    }
    for (final id in ids) {
      final pending = _pending[id];
      if (pending != null) out[id] = pending;
    }
    return out;
  }

  /// 是否读完了
  Future<bool> isFinished(int volumeId) async =>
      (await get(volumeId))?.finished ?? false;

  // ═══ 写 ═══

  /// 记一次翻页。窗口内合并，窗口末尾补写一次。
  ///
  /// 不传 [finished] 时保留原来的完成标记（翻一页不等于重读）。
  Future<void> record(
    int volumeId, {
    int? mediaId,
    int? pageIndex,
    bool? finished,
  }) =>
      _stage(
        volumeId,
        mediaId: mediaId,
        pageIndex: pageIndex,
        finished: finished,
      );

  /// 标记读完（写入本身也走节流，需要立刻生效就再调 [flush]）
  Future<void> markFinished(int volumeId, {int? mediaId, int? pageIndex}) =>
      _stage(volumeId, mediaId: mediaId, pageIndex: pageIndex, finished: true);

  /// 改读完状态（取消完成标记用 `finished: false`）
  Future<void> setFinished(
    int volumeId,
    bool finished, {
    int? mediaId,
    int? pageIndex,
  }) =>
      _stage(
        volumeId,
        mediaId: mediaId,
        pageIndex: pageIndex,
        finished: finished,
      );

  /// 立刻落盘所有攒着的进度。没有待写内容时什么都不做（不计入 writeCount）。
  Future<void> flush() async {
    if (_pending.isEmpty) {
      _cancelTimer();
      return;
    }
    await _writePending();
    _lastWriteAt = _clock();
    _cancelTimer();
  }

  /// 清掉一卷的进度（重读用）。同时丢弃该卷未落盘的 pending。
  Future<void> clear(int volumeId) async {
    _ensureUsable();
    _pending.remove(volumeId);
    if (_pending.isEmpty) _cancelTimer();
    await _db.delete(_table, where: 'volume_id = ?', whereArgs: <Object?>[volumeId]);
  }

  /// 清掉全部进度
  Future<void> clearAll() async {
    _ensureUsable();
    _pending.clear();
    _cancelTimer();
    await _db.delete(_table);
  }

  /// 先停止使用，再把攒着的进度落盘。之后任何写操作都会抛 [StateError]。
  ///
  /// `_disposed` 在第一个 await 之前就置位：调用方常常是 fire-and-forget
  /// （换库实例时 `unawaited(stale.dispose())`），若等落盘完才失效，紧接着的
  /// 一次 [record] 会穿过 `_ensureUsable()` 打到已经关掉的连接上。
  /// [flush] 自己不查 `_ensureUsable`，所以置位后照样能把 pending 写下去。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await flush();
    } catch (error, stack) {
      logError('ReadingProgressService', 'dispose 落盘失败', error);
      logDebug('ReadingProgressService', '$stack');
    }
    _cancelTimer();
  }

  // ═══ 内部 ═══

  Future<void> _stage(
    int volumeId, {
    int? mediaId,
    int? pageIndex,
    required bool? finished,
  }) async {
    _ensureUsable();

    var next = _pending[volumeId];
    if (next == null) {
      final rows = await _db.query(
        _table,
        where: 'volume_id = ?',
        whereArgs: <Object?>[volumeId],
        limit: 1,
      );
      next = rows.isEmpty
          ? ReadingProgress(
              volumeId: volumeId,
              pageIndex: 0,
              finished: false,
              updatedAt: 0,
            )
          : ReadingProgress.fromMap(rows.first);
    }

    final now = _clock();
    _pending[volumeId] = ReadingProgress(
      volumeId: volumeId,
      mediaId: mediaId ?? next.mediaId,
      pageIndex: math.max(0, pageIndex ?? next.pageIndex),
      finished: finished ?? next.finished,
      updatedAt: now.millisecondsSinceEpoch,
    );

    await _maybeWrite(now);
  }

  Future<void> _maybeWrite(DateTime now) async {
    final last = _lastWriteAt;
    if (last == null || now.difference(last) >= _throttle) {
      await _writePending();
      _lastWriteAt = now;
      _cancelTimer();
      return;
    }
    _scheduleTrailing(now, last);
  }

  void _scheduleTrailing(DateTime now, DateTime last) {
    if (_timer != null) return; // 窗口内只挂一个补写定时器
    final remaining = _throttle - now.difference(last);
    final delay = remaining.isNegative ? Duration.zero : remaining;
    _timer = _scheduler.schedule(delay, () {
      _timer = null;
      unawaited(
        flush().catchError((Object error) {
          logError('ReadingProgressService', '节流补写失败', error);
        }),
      );
    });
  }

  Future<void> _writePending() async {
    if (_pending.isEmpty) return;
    final batch = _pending.values.toList(growable: false);

    await _db.transaction((txn) async {
      final batching = txn.batch();
      for (final progress in batch) {
        batching.insert(
          _table,
          progress.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batching.commit(noResult: true);
    });

    _writeCount++;
    for (final progress in batch) {
      // 落盘期间又来了新写的卷不要被清掉
      if (identical(_pending[progress.volumeId], progress)) {
        _pending.remove(progress.volumeId);
      }
      final callback = _onPersist;
      if (callback != null) {
        try {
          callback(progress.volumeId, progress);
        } catch (error) {
          logWarn('ReadingProgressService', 'onPersist 回调抛错', error);
        }
      }
    }
  }

  void _cancelTimer() {
    final timer = _timer;
    if (timer == null) return;
    _timer = null;
    _scheduler.cancel(timer);
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('ReadingProgressService 已 dispose，不能再读写');
    }
  }
}
