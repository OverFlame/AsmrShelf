import 'package:sqflite_common/sqlite_api.dart';
import '../utils/log_util.dart';
import 'media_dao.dart';
import 'path_range.dart';
import 'sql_like.dart';

/// 音频曲目
class TrackItem {
  final int? id;
  final String path;
  final String filename;
  final String? title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final String? format;
  final int? fileSize;
  final int? fileMtime;
  final String? subtitlePath;
  final String? coverPath;
  final int addedAt;

  /// 上一次播到的位置（毫秒）。0 表示没播过，续播取舍见
  /// lib/services/play_position.dart。
  final int playPositionMs;

  const TrackItem({
    this.id,
    required this.path,
    required this.filename,
    this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.format,
    this.fileSize,
    this.fileMtime,
    this.subtitlePath,
    this.coverPath,
    required this.addedAt,
    this.playPositionMs = 0,
  });

  /// 显示标题：直接显示源文件名（含扩展名）
  String get displayTitle => filename;

  TrackItem copyWith({
    String? subtitlePath,
    String? coverPath,
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    int? playPositionMs,
  }) {
    return TrackItem(
      id: id,
      path: path,
      filename: filename,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      durationMs: durationMs ?? this.durationMs,
      format: format,
      fileSize: fileSize,
      fileMtime: fileMtime,
      subtitlePath: subtitlePath ?? this.subtitlePath,
      coverPath: coverPath ?? this.coverPath,
      addedAt: addedAt,
      playPositionMs: playPositionMs ?? this.playPositionMs,
    );
  }

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'path': path,
        'filename': filename,
        'title': title,
        'artist': artist,
        'album': album,
        'duration_ms': durationMs,
        'format': format,
        'file_size': fileSize,
        'file_mtime': fileMtime,
        'subtitle_path': subtitlePath,
        'cover_path': coverPath,
        'added_at': addedAt,
        'play_position_ms': playPositionMs,
      };

  factory TrackItem.fromMap(Map<String, dynamic> map) => TrackItem(
        id: map['id'] as int?,
        path: map['path'] as String,
        filename: map['filename'] as String,
        title: map['title'] as String?,
        artist: map['artist'] as String?,
        album: map['album'] as String?,
        durationMs: map['duration_ms'] as int?,
        format: map['format'] as String?,
        fileSize: map['file_size'] as int?,
        fileMtime: map['file_mtime'] as int?,
        subtitlePath: map['subtitle_path'] as String?,
        coverPath: map['cover_path'] as String?,
        addedAt: map['added_at'] as int,
        playPositionMs: map['play_position_ms'] as int? ?? 0,
      );
}

class TrackDao {
  final Database _db;
  TrackDao(this._db);

  /// 写入走 media 表（视图 tracks 只读）；ext 与 name_lower 由 MediaDao 补全。
  MediaDao get _mediaDao => MediaDao(_db);

  Map<String, Object?> _mediaRow(TrackItem track) =>
      {...track.toMap(), 'media_type': MediaType.audio.value};

  Future<int> insert(TrackItem track) async {
    return _mediaDao.insertRow(_mediaRow(track));
  }

  /// 一个事务插入多首，返回与输入同序的 id；重复路径为 0。
  Future<List<int>> insertMany(Iterable<TrackItem> tracks) {
    return _mediaDao.insertRowsReturningIds(tracks.map(_mediaRow));
  }

  Future<TrackItem?> getById(int id) async {
    final rows = await _db.query('tracks', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return TrackItem.fromMap(rows.first);
  }

  Future<TrackItem?> getByPath(String path) async {
    final rows = await _db.query('tracks', where: 'path = ?', whereArgs: [path]);
    if (rows.isEmpty) return null;
    return TrackItem.fromMap(rows.first);
  }

  Future<int> update(TrackItem track) async {
    if (track.id == null) return 0;
    return _mediaDao.updateRow(track.id!, _mediaRow(track),
        type: MediaType.audio);
  }

  Future<void> setSubtitlePath(int id, String? path) async {
    await _mediaDao.setSubtitlePath(id, path);
    logDebug('TrackDao', 'setSubtitlePath id=$id -> $path');
  }

  Future<void> setCoverPath(int id, String? path) async {
    await _mediaDao.setCoverPath(id, path);
    logDebug('TrackDao', 'setCoverPath id=$id -> $path');
  }

  /// 给定一批路径，返回已在数据库中的路径集合（用于导入去重）
  Future<Set<String>> existingPaths(List<String> paths) async {
    if (paths.isEmpty) return {};
    const batchSize = 500;
    final existing = <String>{};
    for (int i = 0; i < paths.length; i += batchSize) {
      final end =
          i + batchSize > paths.length ? paths.length : i + batchSize;
      final batch = paths.sublist(i, end);
      final placeholders = batch.map((_) => '?').join(',');
      final rows = await _db.rawQuery(
        'SELECT path FROM tracks WHERE path IN ($placeholders)',
        batch,
      );
      for (final row in rows) {
        existing.add(row['path'] as String);
      }
    }
    return existing;
  }

  /// 某目录下「直接包含」的曲目（不含更深层子目录）
  Future<List<TrackItem>> queryDirectInDir(String dirPath,
      {String? search, String orderBy = 'filename'}) async {
    final (prefix, sep) = _directPrefix(dirPath);
    final head = escapeLike(prefix);
    final conditions = <String>[
      "path LIKE ? $sqlLikeEscape",
      "path NOT LIKE ? $sqlLikeEscape",
    ];
    final args = <dynamic>['$head%', '$head%${escapeLike(sep)}%'];
    if (search != null && search.isNotEmpty) {
      conditions.add("(filename LIKE ? $sqlLikeEscape OR title LIKE ? $sqlLikeEscape)");
      args.add('%${escapeLike(search)}%');
      args.add('%${escapeLike(search)}%');
    }
    final rows = await _db.query(
      'tracks',
      where: conditions.join(' AND '),
      whereArgs: args,
      orderBy: orderBy,
    );
    return rows.map(TrackItem.fromMap).toList();
  }

  /// 匹配多个路径前缀中的曲目（用于作品/文件夹递归）
  ///
  /// 目录数可能上千，占位符数量在 SQLite 里有上限，所以按
  /// [_queryBatchSize] 分批查，再按 id 去重（目录互相包含时会重复命中）。
  Future<List<TrackItem>> queryByDirs(List<String> dirPaths,
      {String orderBy = 'filename'}) async {
    if (dirPaths.isEmpty) return [];
    final out = <TrackItem>[];
    final seen = <int>{};
    for (int i = 0; i < dirPaths.length; i += _queryBatchSize) {
      final end = i + _queryBatchSize > dirPaths.length
          ? dirPaths.length
          : i + _queryBatchSize;
      final batch = dirPaths.sublist(i, end);
      final conditions = batch
          .map((_) =>
              '(path COLLATE NOCASE >= ? AND path COLLATE NOCASE < ?)')
          .join(' OR ');
      final args = <Object?>[];
      for (final dir in batch) {
        final (lower, upper) = dirPathRange(dir);
        args
          ..add(lower)
          ..add(upper);
      }
      final rows = await _db.query('tracks',
          where: conditions, whereArgs: args, orderBy: orderBy);
      for (final item in rows.map(TrackItem.fromMap)) {
        if (item.id == null || seen.add(item.id!)) out.add(item);
      }
    }
    if (dirPaths.length > _queryBatchSize) _sortBy(orderBy, out);
    return out;
  }

  /// 按文件名/标题/艺术家模糊搜索
  Future<List<TrackItem>> searchByName(String q, {int limit = 100000}) async {
    final like = '%${escapeLike(q)}%';
    final rows = await _db.query(
      'tracks',
      where: "filename LIKE ? $sqlLikeEscape OR title LIKE ? $sqlLikeEscape "
          "OR artist LIKE ? $sqlLikeEscape OR album LIKE ? $sqlLikeEscape",
      whereArgs: [like, like, like, like],
      orderBy: 'filename',
      limit: limit,
    );
    return rows.map(TrackItem.fromMap).toList();
  }

  /// 查询一批曲目 id 对应的路径
  Future<List<String>> pathsByIds(Set<int> ids) async {
    if (ids.isEmpty) return [];
    final list = ids.toList();
    final out = <String>[];
    for (int i = 0; i < list.length; i += _queryBatchSize) {
      final end = i + _queryBatchSize > list.length
          ? list.length
          : i + _queryBatchSize;
      final batch = list.sublist(i, end);
      final placeholders = batch.map((_) => '?').join(',');
      final rows = await _db.query('tracks',
          columns: ['path'],
          where: 'id IN ($placeholders)',
          whereArgs: batch,
          orderBy: 'id');
      out.addAll(rows.map((r) => r['path'] as String));
    }
    return out;
  }

  Future<List<TrackItem>> queryByIds(Set<int> ids,
      {String orderBy = 'filename'}) async {
    if (ids.isEmpty) return [];
    final list = ids.toList();
    final out = <TrackItem>[];
    for (int i = 0; i < list.length; i += _queryBatchSize) {
      final end = i + _queryBatchSize > list.length
          ? list.length
          : i + _queryBatchSize;
      final batch = list.sublist(i, end);
      final placeholders = batch.map((_) => '?').join(',');
      final rows = await _db.query('tracks',
          where: 'id IN ($placeholders)',
          whereArgs: batch,
          orderBy: orderBy);
      out.addAll(rows.map(TrackItem.fromMap));
    }
    if (list.length > _queryBatchSize) _sortBy(orderBy, out);
    return out;
  }

  Future<List<TrackItem>> queryAll({String orderBy = 'filename'}) async {
    final rows = await _db.query('tracks', orderBy: orderBy);
    return rows.map(TrackItem.fromMap).toList();
  }

  Future<int> deleteByPaths(List<String> paths) async {
    return _mediaDao.deleteByPaths(paths, type: MediaType.audio);
  }

  // ═══ 播放历史 ═══

  /// 记录一次播放（插入历史后裁剪，同一个事务）
  Future<void> recordPlay(int mediaId, int playedAt) async {
    await _db.transaction((txn) async {
      await txn.insert('play_history',
          {'media_id': mediaId, 'played_at': playedAt});
      // 仅保留最近 200 条，避免无限增长
      await txn.rawDelete(
          'DELETE FROM play_history WHERE id NOT IN '
          '(SELECT id FROM play_history ORDER BY played_at DESC LIMIT 200)');
    });
  }

  /// 最近播放的曲目（按最后播放时间倒序，去重）
  Future<List<TrackItem>> recentPlayedTracks({int limit = 50}) async {
    final rows = await _db.rawQuery('''
      SELECT m.*, MAX(h.played_at) AS last_played
      FROM play_history h
      INNER JOIN media m ON m.id = h.media_id
      WHERE m.media_type = 'audio'
      GROUP BY h.media_id
      ORDER BY last_played DESC
      LIMIT ?
    ''', [limit]);
    return rows.map(TrackItem.fromMap).toList();
  }

  /// 一条 SQL 里的最大占位符数量，超过就分批查
  static const int _queryBatchSize = 500;


  /// 分批查询后按同一列重排；单批时顺序仍由 SQLite 决定
  static void _sortBy(String orderBy, List<TrackItem> items) {
    final col = orderBy.trim().split(' ').first.toLowerCase();
    int cmp(TrackItem a, TrackItem b) => switch (col) {
          'title' => (a.title ?? '').compareTo(b.title ?? ''),
          'artist' => (a.artist ?? '').compareTo(b.artist ?? ''),
          'album' => (a.album ?? '').compareTo(b.album ?? ''),
          'id' => (a.id ?? 0).compareTo(b.id ?? 0),
          'path' => a.path.compareTo(b.path),
          'added_at' => a.addedAt.compareTo(b.addedAt),
          _ => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()),
        };
    final desc = orderBy.toUpperCase().contains('DESC');
    items.sort((a, b) => desc ? -cmp(a, b) : cmp(a, b));
  }

  /// 归一化目录路径，返回 (带分隔符的前缀, 分隔符)
  static (String, String) _directPrefix(String dirPath) {
    // 分隔符必须在剥掉尾部分隔符之前判断：`C:\` 剥成 `C:` 后再判断会误判成 `/`，
    // 生成的 `C:/%` 匹配不到任何 Windows 路径。`C:` 这种盘符根也按 `\` 处理。
    final sep = (dirPath.contains('\\') || dirPath.endsWith(':')) ? '\\' : '/';
    var base = dirPath;
    while (base.endsWith('\\') || base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return ('$base$sep', sep);
  }
}
