import 'package:sqflite/sqflite.dart';
import '../utils/filter_expression.dart';
import '../utils/log_util.dart';
import 'media_dao.dart';

/// 标签数据类
class Tag {
  final int? id;
  final String namespace;
  final String name;
  final String color;

  const Tag({
    this.id,
    this.namespace = 'general',
    required this.name,
    this.color = '#cba6f7',
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'namespace': namespace,
        'name': name,
        'color': color,
      };

  factory Tag.fromMap(Map<String, dynamic> map) => Tag(
        id: map['id'] as int?,
        namespace: map['namespace'] as String? ?? 'general',
        name: map['name'] as String,
        color: map['color'] as String? ?? '#cba6f7',
      );

  @override
  bool operator ==(Object other) =>
      other is Tag && other.namespace == namespace && other.name == name;

  @override
  int get hashCode => Object.hash(namespace, name);

  /// 规则标签（kind/ext）只作筛选条件，不写关联行，也不该出现在「手动打标签」的
  /// 列表里（第 18.4 节）。
  bool get isRule => TagDao.ruleNamespaces.contains(namespace);

  @override
  String toString() => namespace == 'general' ? name : '$namespace:$name';
}

class TagCount {
  final Tag tag;
  final int trackCount;
  const TagCount({required this.tag, required this.trackCount});
}

class TagDao {
  final Database _db;
  TagDao(this._db);

  // ═══ CRUD ═══

  Future<Tag> insert(Tag tag) async {
    final id = await _db.insert('tags', tag.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    if (id > 0) {
      return Tag(id: id, namespace: tag.namespace, name: tag.name);
    }
    final rows = await _db.query('tags',
        where: 'namespace = ? AND name = ?',
        whereArgs: [tag.namespace, tag.name]);
    return Tag.fromMap(rows.first);
  }

  Future<Tag?> getById(int id) async {
    final rows = await _db.query('tags', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Tag.fromMap(rows.first);
  }

  Future<Tag?> getByFullName(String namespace, String name) async {
    final rows = await _db.query('tags',
        where: 'namespace = ? AND name = ?',
        whereArgs: [namespace, name]);
    if (rows.isEmpty) return null;
    return Tag.fromMap(rows.first);
  }

  Future<int> update(Tag tag) async {
    if (tag.id == null) return 0;
    return _db.update('tags', tag.toMap(),
        where: 'id = ?', whereArgs: [tag.id]);
  }

  Future<int> delete(int id) async {
    return _db.delete('tags', where: 'id = ?', whereArgs: [id]);
  }

  /// 这个标签被多少条媒体、多少个文件夹引用。
  ///
  /// 删除前用来告诉用户会解除多少关联；规则标签（kind/ext）不写关联行，
  /// 这里一般返回 0。
  Future<({int media, int folders})> countUsage(int tagId) async {
    final mediaRows = await _db.rawQuery(
        'SELECT COUNT(*) AS c FROM media_tags WHERE tag_id = ?', [tagId]);
    final folderRows = await _db.rawQuery(
        'SELECT COUNT(*) AS c FROM folder_tags WHERE tag_id = ?', [tagId]);
    return (
      media: (mediaRows.first['c'] as int?) ?? 0,
      folders: (folderRows.first['c'] as int?) ?? 0,
    );
  }

  Future<List<Tag>> getAll() async {
    final rows = await _db.query('tags', orderBy: 'namespace, name');
    return rows.map(Tag.fromMap).toList();
  }

  Future<List<TagCount>> listWithCount() async {
    final rows = await _db.rawQuery('''
      SELECT t.*, COUNT(tt.media_id) as track_count
      FROM tags t
      LEFT JOIN media_tags tt ON t.id = tt.tag_id
      GROUP BY t.id
      ORDER BY t.namespace, t.name
    ''');
    return rows
        .map((r) =>
            TagCount(tag: Tag.fromMap(r), trackCount: r['track_count'] as int))
        .toList();
  }

  Future<List<Tag>> listByNamespace(String namespace) async {
    final rows = await _db.query('tags',
        where: 'namespace = ?', whereArgs: [namespace], orderBy: 'name');
    return rows.map(Tag.fromMap).toList();
  }

  Future<List<String>> listNamespaces() async {
    final rows = await _db.rawQuery(
        'SELECT DISTINCT namespace FROM tags ORDER BY namespace');
    return rows.map((r) => r['namespace'] as String).toList();
  }

  // ═══ 曲目标签关联 ═══

  Future<void> addTagToTrack(int trackId, int tagId) async {
    await _db.insert('media_tags', {'media_id': trackId, 'tag_id': tagId},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeTagFromTrack(int trackId, int tagId) async {
    await _db.delete('media_tags',
        where: 'media_id = ? AND tag_id = ?', whereArgs: [trackId, tagId]);
  }

  Future<void> setTrackTags(int trackId, List<int> tagIds) async {
    await _db.transaction((txn) async {
      await txn
          .delete('media_tags', where: 'media_id = ?', whereArgs: [trackId]);
      for (final tagId in tagIds) {
        await txn.insert('media_tags', {'media_id': trackId, 'tag_id': tagId});
      }
    });
  }

  /// 一次事务里给多条曲目打同一批标签。
  ///
  /// 逐条 await 的写法在 N×M 次提交之外还有更硬的问题：中途一条失败，
  /// 前面已经写进库的关联留下半截状态。放进事务后要么全成、要么全不成。
  Future<void> addTagsToTracks(
      Iterable<int> trackIds, Iterable<int> tagIds) async {
    final tids = trackIds.toList();
    final gids = tagIds.toList();
    if (tids.isEmpty || gids.isEmpty) return;
    await _db.transaction((txn) async {
      for (final trackId in tids) {
        for (final tagId in gids) {
          await txn.insert('media_tags',
              {'media_id': trackId, 'tag_id': tagId},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    });
  }

  /// 一次事务里摘掉多条曲目上的同一批标签，与 [addTagsToTracks] 对称。
  Future<void> removeTagsFromTracks(
      Iterable<int> trackIds, Iterable<int> tagIds) async {
    final tids = trackIds.toList();
    final gids = tagIds.toList();
    if (tids.isEmpty || gids.isEmpty) return;
    await _db.transaction((txn) async {
      for (final trackId in tids) {
        for (final tagId in gids) {
          await txn.delete('media_tags',
              where: 'media_id = ? AND tag_id = ?',
              whereArgs: [trackId, tagId]);
        }
      }
    });
  }

  Future<List<Tag>> getTagsForTrack(int trackId) async {
    final rows = await _db.rawQuery('''
      SELECT t.* FROM tags t
      INNER JOIN media_tags tt ON t.id = tt.tag_id
      WHERE tt.media_id = ?
      ORDER BY t.namespace, t.name
    ''', [trackId]);
    return rows.map(Tag.fromMap).toList();
  }

  Future<Map<int, List<Tag>>> getTagsForTracks(List<int> trackIds) async {
    if (trackIds.isEmpty) return {};
    final placeholders = trackIds.map((_) => '?').join(',');
    final rows = await _db.rawQuery('''
      SELECT tt.media_id, t.*
      FROM media_tags tt
      INNER JOIN tags t ON t.id = tt.tag_id
      WHERE tt.media_id IN ($placeholders)
      ORDER BY t.namespace, t.name
    ''', trackIds);
    final map = <int, List<Tag>>{};
    for (final row in rows) {
      final tid = row['media_id'] as int;
      map.putIfAbsent(tid, () => []).add(Tag.fromMap(row));
    }
    return map;
  }

  // ═══ 图片标签关联 ═══
  //
  // media_tags 以 media.id 为键，不分媒体类型；图片与曲目共用同一批方法，
  // 这里只给出图片侧的命名别名，避免复制一份同样的 SQL。

  Future<void> addTagToImage(int imageId, int tagId) =>
      addTagToTrack(imageId, tagId);

  Future<void> removeTagFromImage(int imageId, int tagId) =>
      removeTagFromTrack(imageId, tagId);

  Future<List<Tag>> getTagsForImage(int imageId) => getTagsForTrack(imageId);

  Future<Map<int, List<Tag>>> getTagsForImages(List<int> imageIds) =>
      getTagsForTracks(imageIds);

  /// 按标签 AND/OR/NOT 筛选，返回匹配的 media id 集合。
  ///
  /// [type] 传 null 表示不限媒体类型（多媒体栏用）；音频与图片那两个便捷
  /// 入口只是固定类型的包装。
  Future<Set<int>> getIdsByTags(
    MediaType? type, {
    List<int> andTagIds = const [],
    List<int> orTagIds = const [],
    List<int> notTagIds = const [],
  }) =>
      _getIdsByTags(type,
          andTagIds: andTagIds, orTagIds: orTagIds, notTagIds: notTagIds);

  /// 按标签 AND/OR/NOT 筛选曲目，返回匹配的曲目 id 集合
  Future<Set<int>> getTrackIdsByTags({
    List<int> andTagIds = const [],
    List<int> orTagIds = const [],
    List<int> notTagIds = const [],
  }) =>
      getIdsByTags(MediaType.audio,
          andTagIds: andTagIds, orTagIds: orTagIds, notTagIds: notTagIds);

  /// 按标签 AND/OR/NOT 筛选图片，返回匹配的图片 id 集合
  Future<Set<int>> getImageIdsByTags({
    List<int> andTagIds = const [],
    List<int> orTagIds = const [],
    List<int> notTagIds = const [],
  }) =>
      getIdsByTags(MediaType.image,
          andTagIds: andTagIds, orTagIds: orTagIds, notTagIds: notTagIds);

  Future<Set<int>> _getIdsByTags(
    MediaType? type, {
    List<int> andTagIds = const [],
    List<int> orTagIds = const [],
    List<int> notTagIds = const [],
  }) async {
    final and = andTagIds.toSet();
    final or = orTagIds.toSet();
    final not = notTagIds.toSet();

    if (and.isEmpty && or.isEmpty && not.isEmpty) {
      final rows = await _db.query('media',
          columns: ['id'],
          where: type == null ? null : 'media_type = ?',
          whereArgs: type == null ? null : [type.value]);
      return rows.map((r) => r['id'] as int).toSet();
    }

    final conds = <String>[];
    final args = <Object?>[];

    // kind / ext 这类规则标签在库里只有定义行，不写 media_tags，所以要翻成
    // media 的列条件。列表按类型 null 查询时（多媒体栏）类型范围挡不住字幕，
    // 「默认用 tag 反选掉字幕」全靠这一步。
    final ruleSql = await _ruleSqlByIds(<int>{...and, ...or, ...not});
    final andRule = and.where(ruleSql.containsKey).toList();
    final orRule = or.where(ruleSql.containsKey).toList();
    final notRule = not.where(ruleSql.containsKey).toList();
    final andPlain = and.where((id) => !ruleSql.containsKey(id)).toList();
    final orPlain = or.where((id) => !ruleSql.containsKey(id)).toList();
    final notPlain = not.where((id) => !ruleSql.containsKey(id)).toList();

    for (final id in andRule) {
      conds.add('(${ruleSql[id]})');
    }

    if (andPlain.isNotEmpty) {
      final ph = andPlain.map((_) => '?').join(',');
      conds.add('''
        id IN (
          SELECT media_id FROM media_tags
          WHERE tag_id IN ($ph)
          GROUP BY media_id
          HAVING COUNT(DISTINCT tag_id) = ${andPlain.length}
        )
      ''');
      args.addAll(andPlain);
    }

    if (orPlain.isNotEmpty || orRule.isNotEmpty) {
      final parts = <String>[];
      if (orPlain.isNotEmpty) {
        final ph = orPlain.map((_) => '?').join(',');
        parts.add(
            '(id IN (SELECT DISTINCT media_id FROM media_tags WHERE tag_id IN ($ph)))');
        args.addAll(orPlain);
      }
      for (final id in orRule) {
        parts.add('(${ruleSql[id]})');
      }
      conds.add(parts.length == 1 ? parts.single : '(${parts.join(' OR ')})');
    }

    for (final id in notRule) {
      conds.add('NOT (${ruleSql[id]})');
    }

    if (notPlain.isNotEmpty) {
      final ph = notPlain.map((_) => '?').join(',');
      conds.add(
          'id NOT IN (SELECT DISTINCT media_id FROM media_tags WHERE tag_id IN ($ph))');
      args.addAll(notPlain);
    }

    final typeSql = type == null ? '' : 'media_type = ? AND ';
    final rows = await _db.rawQuery(
      'SELECT id FROM media WHERE $typeSql${conds.join(' AND ')}',
      type == null ? args : [type.value, ...args],
    );
    return rows.map((r) => r['id'] as int).toSet();
  }

  /// 按布尔表达式筛选，返回匹配的 media id 集合。
  ///
  /// [type] 传 null 表示不限媒体类型（多媒体栏用）。
  Future<Set<int>> getIdsByExpression(
          MediaType? type, String expression, List<Tag> allTags) =>
      _getIdsByExpression(type, expression, allTags);

  /// 按布尔表达式筛选曲目
  Future<Set<int>> getTrackIdsByExpression(
          String expression, List<Tag> allTags) =>
      getIdsByExpression(MediaType.audio, expression, allTags);

  /// 按布尔表达式筛选图片
  Future<Set<int>> getImageIdsByExpression(
          String expression, List<Tag> allTags) =>
      getIdsByExpression(MediaType.image, expression, allTags);

  Future<Set<int>> _getIdsByExpression(
      MediaType? type, String expression, List<Tag> allTags) async {
    final ast = FilterExpressionParser.parse(expression);
    final sub =
        buildTrackIdSubquery(ast, (ref) => _resolveTagRefSql(ref, allTags));
    final rows = type == null
        ? await _db.rawQuery('SELECT id FROM media WHERE id IN ($sub)')
        : await _db.rawQuery(
            'SELECT id FROM media WHERE media_type = ? AND id IN ($sub)',
            [type.value]);
    return rows.map((r) => r['id'] as int).toSet();
  }

  /// 规则标签 id → 它对应的 media 列条件；普通标签不在结果里。
  Future<Map<int, String>> _ruleSqlByIds(Set<int> ids) async {
    if (ids.isEmpty) return const <int, String>{};
    final ph = ids.map((_) => '?').join(',');
    final rows = await _db.query(
      'tags',
      columns: ['id', 'namespace', 'name'],
      where: 'id IN ($ph)',
      whereArgs: ids.toList(),
    );
    final out = <int, String>{};
    for (final r in rows) {
      final ns = r['namespace'] as String?;
      if (ns == null || !ruleNamespaces.contains(ns)) continue;
      final sql = ruleTagSql(TagRef('$ns:${r['name']}'));
      if (sql != null) out[r['id'] as int] = sql;
    }
    return out;
  }

  /// 规则标签的命名空间。库里只放定义行，不写关联行。
  static const String kindNamespace = 'kind';
  static const String extNamespace = 'ext';

  /// 规则命名空间集合，界面用来区分「可手动打」与「只能筛」。
  static const Set<String> ruleNamespaces = {kindNamespace, extNamespace};

  /// 标签引用 → 返回 media id 集合的子查询字符串。
  ///
  /// kind 与 ext 翻成 media 的列条件，普通标签查 media_tags（第 18.4 节）。
  String _resolveTagRefSql(TagRef ref, List<Tag> allTags) {
    final rule = ruleTagSql(ref);
    if (rule != null) return 'SELECT id FROM media WHERE $rule';
    return tagIdsSubquery(_resolveTagRef(ref, allTags));
  }

  /// 规则标签 → media 列条件；不是规则标签返回 null。
  ///
  /// 值先过白名单再拼进 SQL：kind 只认四个媒体类型，ext 只认字母与数字。
  static String? ruleTagSql(TagRef ref) {
    if (ref.quoted) return null;
    final text = ref.text.toLowerCase();
    final ci = text.indexOf(':');
    if (ci <= 0) return null;
    final ns = text.substring(0, ci);
    var name = text.substring(ci + 1);
    if (name.startsWith('.')) name = name.substring(1);
    if (ns == kindNamespace) {
      if (!MediaType.allValues.contains(name)) return null;
      return "media_type = '$name'";
    }
    if (ns == extNamespace) {
      if (!RegExp(r'^[a-z0-9]{1,12}$').hasMatch(name)) return null;
      return "ext = '.$name'";
    }
    return null;
  }

  /// 补齐规则标签的定义行：kind 取四个媒体类型，ext 由调用方给扩展名集合。
  Future<void> ensureRuleTags({Iterable<String> extNames = const []}) async {
    await _db.transaction((txn) async {
      for (final k in MediaType.allValues) {
        await txn.insert('tags', {'namespace': kindNamespace, 'name': k},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final e in extNames) {
        final name =
            e.startsWith('.') ? e.substring(1).toLowerCase() : e.toLowerCase();
        if (name.isEmpty) continue;
        await txn.insert('tags', {'namespace': extNamespace, 'name': name},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  List<int> _resolveTagRef(TagRef ref, List<Tag> allTags) {
    final target = ref.text.toLowerCase();
    final Iterable<Tag> matches;
    if (ref.quoted) {
      matches = allTags.where((t) => t.name.toLowerCase() == target);
    } else {
      final ci = ref.text.indexOf(':');
      if (ci > 0) {
        final ns = ref.text.substring(0, ci).toLowerCase();
        final name = ref.text.substring(ci + 1).toLowerCase();
        matches = allTags.where((t) =>
            t.namespace.toLowerCase() == ns && t.name.toLowerCase() == name);
      } else {
        matches = allTags.where((t) => t.name.toLowerCase() == target);
      }
    }
    return matches.where((t) => t.id != null).map((t) => t.id!).toList();
  }

  // ═══ 文件夹标签关联 ═══

  Future<void> addTagToFolder(int folderId, int tagId) async {
    await _db.insert('folder_tags', {'folder_id': folderId, 'tag_id': tagId},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeTagFromFolder(int folderId, int tagId) async {
    await _db.delete('folder_tags',
        where: 'folder_id = ? AND tag_id = ?', whereArgs: [folderId, tagId]);
  }

  Future<void> setFolderTags(int folderId, List<int> tagIds) async {
    await _db.transaction((txn) async {
      await txn.delete('folder_tags',
          where: 'folder_id = ?', whereArgs: [folderId]);
      for (final tagId in tagIds) {
        await txn
            .insert('folder_tags', {'folder_id': folderId, 'tag_id': tagId});
      }
    });
  }

  Future<List<Tag>> getTagsForFolder(int folderId) async {
    final rows = await _db.rawQuery('''
      SELECT t.* FROM tags t
      INNER JOIN folder_tags ft ON t.id = ft.tag_id
      WHERE ft.folder_id = ?
      ORDER BY t.namespace, t.name
    ''', [folderId]);
    return rows.map(Tag.fromMap).toList();
  }

  Future<Map<int, List<Tag>>> getTagsForFolders(List<int> folderIds) async {
    if (folderIds.isEmpty) return {};
    final placeholders = folderIds.map((_) => '?').join(',');
    final rows = await _db.rawQuery('''
      SELECT ft.folder_id, t.*
      FROM folder_tags ft
      INNER JOIN tags t ON t.id = ft.tag_id
      WHERE ft.folder_id IN ($placeholders)
      ORDER BY t.namespace, t.name
    ''', folderIds);
    final map = <int, List<Tag>>{};
    for (final row in rows) {
      final fid = row['folder_id'] as int;
      map.putIfAbsent(fid, () => []).add(Tag.fromMap(row));
    }
    return map;
  }

  /// 删除无引用的孤立标签
  Future<int> deleteOrphanTags() async {
    final count = await _db.delete('tags',
        where: '''
      id NOT IN (SELECT DISTINCT tag_id FROM media_tags)
      AND id NOT IN (SELECT DISTINCT tag_id FROM folder_tags)
    ''');
    logInfo('TagDao', 'deleteOrphanTags: removed $count orphan(s)');
    return count;
  }
}
