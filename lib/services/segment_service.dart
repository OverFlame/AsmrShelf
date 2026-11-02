import 'package:sqflite/sqflite.dart';

/// 播放推进策略（BUILD_GUIDE 第 24.3 节的优先级表）
enum PlaybackPolicy {
  /// 只循环选中的段
  repeatSegment,

  /// 循环整曲
  repeatTrack,

  /// 顺序推进到下一首
  advance,

  /// 播完停止
  finish,
}

/// 一轨上的一段收藏区间
class MediaSegment {
  const MediaSegment({
    this.id,
    required this.mediaId,
    required this.startMs,
    required this.endMs,
    this.name,
    required this.createdAt,
  });

  final int? id;
  final int mediaId;
  final int startMs;
  final int endMs;
  final String? name;
  final int createdAt;

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);
  Duration get length => Duration(milliseconds: endMs - startMs);

  /// 显示名：名字为空时用「未命名选段」
  String get label {
    final n = name?.trim() ?? '';
    return n.isEmpty ? '未命名选段' : n;
  }

  MediaSegment copyWith({
    int? id,
    int? mediaId,
    int? startMs,
    int? endMs,
    String? name,
    int? createdAt,
  }) =>
      MediaSegment(
        id: id ?? this.id,
        mediaId: mediaId ?? this.mediaId,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        name: name ?? this.name,
        createdAt: createdAt ?? this.createdAt,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaSegment &&
      other.id == id &&
      other.mediaId == mediaId &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.name == name &&
      other.createdAt == createdAt;

  @override
  int get hashCode =>
      Object.hash(id, mediaId, startMs, endMs, name, createdAt);
}

/// 收藏选段服务：起止校验、越界收口与优先级判定（BUILD_GUIDE 第 24.3 节）
class SegmentService {
  SegmentService(this._db);

  final Database _db;

  /// 段的最小长度。拖动手柄重合时不产生空段。
  static const int minSegmentMs = 200;

  static int _clampInt(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
  }

  /// 起止换算：两端收口到 `[0, durationMs]` 内，并保证 `end` 大于 `start`
  static ({int startMs, int endMs}) normalizeRange(
      int startMs, int endMs, int durationMs) {
    if (durationMs <= 0) return (startMs: 0, endMs: 0);
    var start = _clampInt(startMs, 0, durationMs);
    var end = _clampInt(endMs, 0, durationMs);
    if (end - start >= minSegmentMs) return (startMs: start, endMs: end);
    if (start + minSegmentMs <= durationMs) {
      end = start + minSegmentMs;
    } else {
      end = durationMs;
      start = _clampInt(end - minSegmentMs, 0, durationMs);
    }
    return (startMs: start, endMs: end);
  }

  /// 区间是否合法：长度为正
  static bool isValidRange(int startMs, int endMs) => endMs > startMs;

  /// 循环优先级判定：选段循环压过整曲循环
  static PlaybackPolicy policyOf({
    required bool segmentLoop,
    required bool repeatOne,
    required bool repeatAll,
  }) {
    if (segmentLoop) return PlaybackPolicy.repeatSegment;
    if (repeatOne) return PlaybackPolicy.repeatTrack;
    if (repeatAll) return PlaybackPolicy.advance;
    return PlaybackPolicy.finish;
  }

  /// 一轨的全部段，按起点升序
  Future<List<MediaSegment>> listByMedia(int mediaId) async {
    final rows = await _db.query(
      'media_segments',
      where: 'media_id = ?',
      whereArgs: [mediaId],
      orderBy: 'start_ms ASC, id ASC',
    );
    return rows.map(fromRow).toList();
  }

  Future<MediaSegment?> getById(int id) async {
    final rows =
        await _db.query('media_segments', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return fromRow(rows.first);
  }

  /// 新增一段。传了 [durationMs] 就先做越界收口。
  Future<MediaSegment> add({
    required int mediaId,
    required int startMs,
    required int endMs,
    int? durationMs,
    String? name,
    int? createdAt,
  }) async {
    final range = (durationMs == null || durationMs <= 0)
        ? (startMs: startMs, endMs: endMs)
        : normalizeRange(startMs, endMs, durationMs);
    final clean = _cleanName(name);
    final stamp = createdAt ?? DateTime.now().millisecondsSinceEpoch;
    final id = await _db.insert('media_segments', {
      'media_id': mediaId,
      'start_ms': range.startMs,
      'end_ms': range.endMs,
      'name': clean,
      'created_at': stamp,
    });
    return MediaSegment(
      id: id,
      mediaId: mediaId,
      startMs: range.startMs,
      endMs: range.endMs,
      name: clean,
      createdAt: stamp,
    );
  }

  Future<void> rename(int id, String? name) async {
    await _db.update(
      'media_segments',
      {'name': _cleanName(name)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> remove(int id) async {
    await _db.delete('media_segments', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> removeForMedia(int mediaId) async {
    await _db
        .delete('media_segments', where: 'media_id = ?', whereArgs: [mediaId]);
  }

  /// 落库前把空白名字收成 null
  static String? _cleanName(String? name) {
    final n = name?.trim() ?? '';
    return n.isEmpty ? null : n;
  }

  static MediaSegment fromRow(Map<String, Object?> row) => MediaSegment(
        id: row['id'] as int?,
        mediaId: row['media_id'] as int,
        startMs: row['start_ms'] as int,
        endMs: row['end_ms'] as int,
        name: row['name'] as String?,
        createdAt: row['created_at'] as int,
      );
}
