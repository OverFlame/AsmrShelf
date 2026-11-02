import 'package:sqflite_common/sqlite_api.dart';

import '../services/media_rules.dart';
import '../utils/log_util.dart';
import 'path_range.dart';
import 'sql_like.dart';

/// 媒体类型。音频、图片、视频、字幕共用一张 media 表。
enum MediaType {
  audio('audio'),
  image('image'),
  video('video'),
  subtitle('subtitle');

  const MediaType(this.value);

  /// 落库值
  final String value;

  /// 由落库值反解，未知值返回 null
  static MediaType? fromValue(Object? value) {
    for (final t in values) {
      if (t.value == value) return t;
    }
    return null;
  }

  /// 全部落库值，供 CHECK 断言与 IN 查询拼接
  static List<String> get allValues => values.map((t) => t.value).toList();
}

/// media 表的一行
class MediaItem {
  final int? id;
  final String path;
  final MediaType mediaType;
  final String ext;
  final String nameLower;
  final String filename;
  final String? format;
  final int? fileSize;
  final int? fileMtime;
  final int addedAt;
  final String? title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final int? width;
  final int? height;
  final String? alias;
  final String? subtitlePath;
  final String? coverPath;
  /// 自然排序键，见 lib/services/media_rules.dart 的 sortKeyOfPath。
  final String? sortKey;

  const MediaItem({
    this.id,
    required this.path,
    required this.mediaType,
    this.ext = '',
    this.nameLower = '',
    required this.filename,
    this.format,
    this.fileSize,
    this.fileMtime,
    required this.addedAt,
    this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.width,
    this.height,
    this.alias,
    this.subtitlePath,
    this.coverPath,
    this.sortKey,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'path': path,
        'media_type': mediaType.value,
        'ext': ext,
        'name_lower': nameLower,
        'filename': filename,
        'format': format,
        'file_size': fileSize,
        'file_mtime': fileMtime,
        'added_at': addedAt,
        'title': title,
        'artist': artist,
        'album': album,
        'duration_ms': durationMs,
        'width': width,
        'height': height,
        'alias': alias,
        'subtitle_path': subtitlePath,
        'cover_path': coverPath,
        'sort_key': sortKey,
      };

  factory MediaItem.fromMap(Map<String, dynamic> map) => MediaItem(
        id: map['id'] as int?,
        path: map['path'] as String,
        mediaType:
            MediaType.fromValue(map['media_type']) ?? MediaType.image,
        ext: (map['ext'] as String?) ?? '',
        nameLower: (map['name_lower'] as String?) ?? '',
        filename: (map['filename'] as String?) ?? '',
        format: map['format'] as String?,
        fileSize: map['file_size'] as int?,
        fileMtime: map['file_mtime'] as int?,
        addedAt: (map['added_at'] as int?) ?? 0,
        title: map['title'] as String?,
        artist: map['artist'] as String?,
        album: map['album'] as String?,
        durationMs: map['duration_ms'] as int?,
        width: map['width'] as int?,
        height: map['height'] as int?,
        alias: map['alias'] as String?,
        subtitlePath: map['subtitle_path'] as String?,
        coverPath: map['cover_path'] as String?,
        sortKey: map['sort_key'] as String?,
      );
}

/// media 表的读写入口。视图 tracks / images 只读，写入一律走这里。
class MediaDao {
  final Database _db;
  MediaDao(this._db);

  static const int _batchSize = 500;

  // ═══ 归一化工具 ═══

  /// 取小写扩展名（含点）。规则在 media_rules.dart，这里只是转发。
  ///
  /// 只认最后一个点；点在路径开头（隐藏文件）或结尾时算没有扩展名，
  /// 所以 `.gitignore` 与 `a` 都返回空串，`a.tar.gz` 返回 `.gz`。
  static String extOf(String path) => extOfPath(path);

  /// 供大小写不敏感查找的列值，统一小写。查询侧也要先 toLowerCase 再回填。
  static String nameLowerOf(String path) => nameLowerOfPath(path);

  /// 补全 ext、name_lower 与 sort_key 再落库，避免调用点漏填。
  static Map<String, Object?> rowWithDerived(Map<String, Object?> row) {
    final path = (row['path'] as String?) ?? '';
    return {
      ...row,
      'ext': row['ext'] ?? extOf(path),
      'name_lower': row['name_lower'] ?? nameLowerOf(path),
      'sort_key': row['sort_key'] ?? sortKeyOfPath(path),
    };
  }

  /// 默认排序：自然排序键优先，为空时回落文件名，两者都不区分大小写。
  ///
  /// 第 10 页排在第 2 页后面靠这一条（BUILD_GUIDE 第 20.2 节）。
  static const String naturalOrderBy =
      "(CASE WHEN sort_key IS NULL OR sort_key = '' THEN filename "
      "ELSE sort_key END) COLLATE NOCASE, filename COLLATE NOCASE";

  // ═══ 写 ═══

  Future<int> insertRow(
    Map<String, Object?> row, {
    ConflictAlgorithm conflict = ConflictAlgorithm.ignore,
  }) {
    return _db.insert('media', rowWithDerived(row), conflictAlgorithm: conflict);
  }

  /// 一个事务里插入多行，返回真正落库的行数。
  ///
  /// 图片与视频一次导入几百到几千行，逐条 insert 会各自开一次事务，
  /// 在 Android 上慢得明显。这里统一走一个事务；冲突策略默认 ignore，
  /// 重复导入不会报错也不会产生重复行（media.path 有 UNIQUE）。
  Future<int> insertRows(
    Iterable<Map<String, Object?>> rows, {
    ConflictAlgorithm conflict = ConflictAlgorithm.ignore,
  }) async {
    final ids = await insertRowsReturningIds(rows, conflict: conflict);
    if (ids.isEmpty) return 0;
    final inserted = ids.where((id) => id > 0).length;
    logInfo('MediaDao', 'insertRows 落库 $inserted/${ids.length} 行');
    return inserted;
  }

  /// 与 [insertRows] 相同，但返回与输入同序的 id；被 UNIQUE 忽略的行为 0。
  ///
  /// 导入时需要 id 写内嵌封面，所以不能只拿落库条数。
  Future<List<int>> insertRowsReturningIds(
    Iterable<Map<String, Object?>> rows, {
    ConflictAlgorithm conflict = ConflictAlgorithm.ignore,
  }) async {
    final list = rows.toList();
    if (list.isEmpty) return const <int>[];
    final ids = <int>[];
    await _db.transaction((txn) async {
      for (final row in list) {
        ids.add(await txn.insert('media', rowWithDerived(row),
            conflictAlgorithm: conflict));
      }
    });
    return ids;
  }

  /// 按 id 更新。给了 type 就顺带校验这一行的类型，避免跨类型误改。
  Future<int> updateRow(int id, Map<String, Object?> fields,
      {MediaType? type}) async {
    final where = StringBuffer('id = ?');
    final args = <Object?>[id];
    if (type != null) {
      where.write(' AND media_type = ?');
      args.add(type.value);
    }
    return _db.update('media', fields, where: where.toString(), whereArgs: args);
  }

  Future<void> setSubtitlePath(int id, String? path) async {
    await updateRow(id, {'subtitle_path': path}, type: MediaType.audio);
  }

  /// 按媒体路径给还没有字幕的音频补一条，避免覆盖用户手选的字幕。
  Future<int> setSubtitlePathByPathIfMissing(
    String path,
    String subtitlePath,
  ) {
    return _db.update(
      'media',
      {'subtitle_path': subtitlePath},
      where: "path = ? AND media_type = 'audio' "
          "AND (subtitle_path IS NULL OR subtitle_path = '')",
      whereArgs: <Object?>[path],
    );
  }

  Future<void> setCoverPath(int id, String? path) async {
    await updateRow(id, {'cover_path': path});
  }

  /// 记住这一首播到的位置（毫秒），0 表示从头播。
  ///
  /// 只在音频行上写，避免 id 撞到图片/视频行。
  Future<void> setPlayPosition(int id, int positionMs) async {
    await updateRow(id, {'play_position_ms': positionMs},
        type: MediaType.audio);
  }

  Future<int> deleteByPaths(Iterable<String> paths, {MediaType? type}) async {
    final list = paths.toList();
    if (list.isEmpty) return 0;
    final typeSql = type == null ? '' : ' AND media_type = ?';
    final typeArg = type == null ? const <Object?>[] : <Object?>[type.value];
    var deleted = 0;
    // 分批是为了躲开 SQL 变量上限，但整批要在一个事务里：拆成多条独立
    // DELETE 时第二条抛错，库里会留下删了一半的集合。
    await _db.transaction((txn) async {
      for (var i = 0; i < list.length; i += _batchSize) {
        final batch = list.sublist(
            i, i + _batchSize > list.length ? list.length : i + _batchSize);
        final ph = List.filled(batch.length, '?').join(',');
        deleted += await txn.delete('media',
            where: 'path IN ($ph)$typeSql', whereArgs: [...batch, ...typeArg]);
      }
    });
    logInfo('MediaDao', 'deleteByPaths 删除 $deleted 行（type=${type?.value}）');
    return deleted;
  }

  /// 按 id 批量删媒体记录（批量多选的「从软件移除」走这里）。
  ///
  /// 只删库里的行，磁盘文件不动。media_tags 与 media_segments 都按外键级联
  /// 清掉；reading_progress.media_id 是 SET NULL，阅读进度不受影响。
  Future<int> deleteByIds(Iterable<int> ids, {MediaType? type}) async {
    final list = ids.toSet().toList();
    if (list.isEmpty) return 0;
    final typeSql = type == null ? '' : ' AND media_type = ?';
    final typeArg = type == null ? const <Object?>[] : <Object?>[type.value];
    var deleted = 0;
    // 同 deleteByPaths：分批要在同一个事务里，避免删一半。
    await _db.transaction((txn) async {
      for (var i = 0; i < list.length; i += _batchSize) {
        final batch = list.sublist(
            i, i + _batchSize > list.length ? list.length : i + _batchSize);
        final ph = List.filled(batch.length, '?').join(',');
        deleted += await txn.delete('media',
            where: 'id IN ($ph)$typeSql', whereArgs: [...batch, ...typeArg]);
      }
    });
    logInfo('MediaDao', 'deleteByIds 删除 $deleted 行（type=${type?.value}）');
    return deleted;
  }

  // ═══ 读 ═══

  String _typeWhere(MediaType? type, List<Object?> args, {String? extra}) {
    final parts = <String>[];
    if (type != null) {
      parts.add('media_type = ?');
      args.add(type.value);
    }
    if (extra != null) parts.add(extra);
    return parts.join(' AND ');
  }

  Future<MediaItem?> getById(int id) async {
    final rows = await _db.query('media', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return MediaItem.fromMap(rows.first);
  }

  Future<MediaItem?> getByPath(String path) async {
    final rows =
        await _db.query('media', where: 'path = ?', whereArgs: [path]);
    if (rows.isEmpty) return null;
    return MediaItem.fromMap(rows.first);
  }

  Future<List<MediaItem>> queryAll(
      {MediaType? type, String orderBy = naturalOrderBy}) async {
    final args = <Object?>[];
    final where = _typeWhere(type, args);
    final rows = await _db.query('media',
        where: where.isEmpty ? null : where,
        whereArgs: where.isEmpty ? null : args,
        orderBy: orderBy);
    return rows.map(MediaItem.fromMap).toList();
  }

  /// 匹配多个路径前缀下的媒体行（作品与卷整树取用）
  ///
  /// 目录数可能上千，占位符在 SQLite 里有上限，所以分批查，再按 id 去重。
  /// 跨越批次时按文件名排序，保证行序稳定。
  Future<List<MediaItem>> queryByDirs(List<String> dirPaths,
      {MediaType? type, String orderBy = naturalOrderBy}) async {
    if (dirPaths.isEmpty) return [];
    final out = <MediaItem>[];
    final seen = <int>{};
    final typeSql = type == null ? '' : ' AND media_type = ?';
    final typeArg = type == null ? const <Object?>[] : <Object?>[type.value];
    for (var i = 0; i < dirPaths.length; i += _batchSize) {
      final batch = dirPaths.sublist(
          i, i + _batchSize > dirPaths.length ? dirPaths.length : i + _batchSize);
      // 区间比较走 idx_media_path_nocase，且 lower 自带分隔符，
      // `/m/vol` 不会命中 `/m/vol2`（旧 LIKE 前缀写法会）。
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
      final rows = await _db.rawQuery(
          'SELECT * FROM media WHERE ($conditions)$typeSql ORDER BY $orderBy',
          [...args, ...typeArg]);
      for (final row in rows) {
        final item = MediaItem.fromMap(Map<String, dynamic>.from(row));
        if (item.id == null || seen.add(item.id!)) out.add(item);
      }
    }
    out.sort(compareNatural);
    return out;
  }

  /// 某目录下「直接包含」的媒体行（不含更深层子目录）。
  ///
  /// 图片浏览用：文件夹里只平铺本层的图片，子目录另行展示。
  Future<List<MediaItem>> queryDirectInDir(String dirPath,
      {MediaType? type, String orderBy = naturalOrderBy}) async {
    final (prefix, sep) = _directPrefix(dirPath);
    final head = escapeLike(prefix);
    final conditions = <String>[
      "path LIKE ? $sqlLikeEscape",
      "path NOT LIKE ? $sqlLikeEscape",
    ];
    final args = <Object?>['$head%', '$head%${escapeLike(sep)}%'];
    if (type != null) {
      conditions.add('media_type = ?');
      args.add(type.value);
    }
    final rows = await _db.query('media',
        where: conditions.join(' AND '), whereArgs: args, orderBy: orderBy);
    return rows.map(MediaItem.fromMap).toList();
  }

  /// 按文件名 / 标题 / 艺术家 / 专辑 / 别名模糊搜索。
  ///
  /// 图片侧靠 filename 与 alias 命中，音频侧另有 TrackDao.searchByName。
  Future<List<MediaItem>> searchByName(String q,
      {MediaType? type, int limit = 100000, String orderBy = naturalOrderBy}) async {
    final like = '%${escapeLike(q)}%';
    final args = <Object?>[like, like, like, like, like];
    final search =
        "filename LIKE ? $sqlLikeEscape OR title LIKE ? $sqlLikeEscape "
        "OR artist LIKE ? $sqlLikeEscape OR album LIKE ? $sqlLikeEscape "
        "OR alias LIKE ? $sqlLikeEscape";
    final where = type == null ? search : "($search) AND media_type = ?";
    if (type != null) args.add(type.value);
    final rows = await _db.query('media',
        where: where, whereArgs: args, orderBy: orderBy, limit: limit);
    return rows.map(MediaItem.fromMap).toList();
  }

  /// 查询一批媒体 id 对应的路径（图片筛选时用来反查命中路径）
  Future<List<String>> pathsByIds(Set<int> ids, {MediaType? type}) async {
    if (ids.isEmpty) return [];
    final list = ids.toList();
    final out = <String>[];
    final typeSql = type == null ? '' : ' AND media_type = ?';
    final typeArg = type == null ? const <Object?>[] : <Object?>[type.value];
    for (var i = 0; i < list.length; i += _batchSize) {
      final batch = list.sublist(
          i, i + _batchSize > list.length ? list.length : i + _batchSize);
      final ph = List.filled(batch.length, '?').join(',');
      final rows = await _db.query('media',
          columns: ['path'],
          where: 'id IN ($ph)$typeSql',
          whereArgs: [...batch, ...typeArg],
          orderBy: 'id');
      out.addAll(rows.map((r) => r['path'] as String));
    }
    return out;
  }

  /// 设置别名（图片侧的用户命名）。
  Future<void> setAlias(int id, String? alias) async {
    await updateRow(id, {'alias': alias});
  }

  /// 跨批次合并后的自然顺序比较：先比 sort_key，再比文件名，都不区分大小写。
  static int compareNatural(MediaItem a, MediaItem b) {
    final ka = (a.sortKey == null || a.sortKey!.isEmpty)
        ? a.filename
        : a.sortKey!;
    final kb = (b.sortKey == null || b.sortKey!.isEmpty)
        ? b.filename
        : b.sortKey!;
    final byKey = ka.toLowerCase().compareTo(kb.toLowerCase());
    if (byKey != 0) return byKey;
    return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
  }


  /// 归一化目录路径，返回 (带分隔符的前缀, 分隔符)。
  ///
  /// 分隔符必须在剥掉尾部分隔符之前判断：`C:\` 剥成 `C:` 后再判断会误判成 `/`。
  static (String, String) _directPrefix(String dirPath) {
    final sep = (dirPath.contains('\\') || dirPath.endsWith(':')) ? '\\' : '/';
    var base = dirPath;
    while (base.endsWith('\\') || base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return ('$base$sep', sep);
  }

  Future<int> count({MediaType? type}) async {
    final args = <Object?>[];
    final where = _typeWhere(type, args);
    final rows = await _db.rawQuery(
        'SELECT COUNT(*) AS n FROM media'
        '${where.isEmpty ? '' : ' WHERE $where'}',
        args.isEmpty ? null : args);
    return (rows.first['n'] as int?) ?? 0;
  }

  /// 已入库的路径集合。导入前用它跳过重复文件。
  Future<Set<String>> existingPaths(Iterable<String> paths,
      {MediaType? type}) async {
    final list = paths.toList();
    if (list.isEmpty) return <String>{};
    final typeSql = type == null ? '' : ' AND media_type = ?';
    final typeArg = type == null ? const <Object?>[] : <Object?>[type.value];
    final found = <String>{};
    for (var i = 0; i < list.length; i += _batchSize) {
      final batch = list.sublist(
          i, i + _batchSize > list.length ? list.length : i + _batchSize);
      final ph = List.filled(batch.length, '?').join(',');
      final rows = await _db.rawQuery(
          'SELECT path FROM media WHERE path IN ($ph)$typeSql',
          [...batch, ...typeArg]);
      for (final r in rows) {
        found.add(r['path'] as String);
      }
    }
    return found;
  }
}
