import 'package:sqflite/sqflite.dart';
import '../utils/log_util.dart';

/// 作品集：音频库是专辑，视频库是剧集
class Work {
  final int? id;
  final String name;

  /// 库归属：audio / video（BUILD_GUIDE 第 18.2 节）
  final String library;
  final String? coverPath;
  final int sortOrder;
  final int createdAt;

  const Work({
    this.id,
    required this.name,
    this.library = 'audio',
    this.coverPath,
    this.sortOrder = 0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'library': library,
        'cover_path': coverPath,
        'sort_order': sortOrder,
        'created_at': createdAt,
      };

  factory Work.fromMap(Map<String, dynamic> map) => Work(
        id: map['id'] as int?,
        name: map['name'] as String,
        library: (map['library'] as String?) ?? 'audio',
        coverPath: map['cover_path'] as String?,
        sortOrder: map['sort_order'] as int? ?? 0,
        createdAt: map['created_at'] as int,
      );
}

class WorkDao {
  final Database _db;
  WorkDao(this._db);

  Future<Work> create(String name,
      {String? coverPath, String library = 'audio'}) async {
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    final id = await _db.insert('works', {
      'name': name,
      'library': library,
      'cover_path': coverPath,
      'sort_order': 0,
      'created_at': createdAt,
    });
    logInfo('WorkDao',
        'Created work: id=$id name="$name" lib=$library');
    return Work(
        id: id,
        name: name,
        library: library,
        coverPath: coverPath,
        createdAt: createdAt);
  }

  /// 作品列表。给了 library 就只返回该库的作品。
  Future<List<Work>> listAll({String? library}) async {
    final rows = library == null
        ? await _db.query('works', orderBy: 'sort_order, created_at DESC')
        : await _db.query('works',
            where: 'library = ?',
            whereArgs: [library],
            orderBy: 'sort_order, created_at DESC');
    return rows.map(Work.fromMap).toList();
  }

  Future<Work?> getById(int id) async {
    final rows = await _db.query('works', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Work.fromMap(rows.first);
  }

  Future<int> rename(int id, String newName) async {
    return _db.update('works', {'name': newName},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> setCover(int id, String? coverPath) async {
    return _db.update('works', {'cover_path': coverPath},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> setSortOrder(int id, int order) async {
    return _db.update('works', {'sort_order': order},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 删除作品，并在同一事务内摘掉其下文件夹的归属。
  ///
  /// 两步必须原子：只摘归属不删作品会留下空作品，只删作品不摘归属会留下指向
  /// 已删作品的悬空引用（外键开启时直接抛错）。事务保证要么都成，要么都不成。
  Future<int> delete(int id) async {
    return _db.transaction((txn) async {
      await txn.update('folders', {'work_id': null},
          where: 'work_id = ?', whereArgs: [id]);
      final count = await txn.delete('works', where: 'id = ?', whereArgs: [id]);
      logInfo('WorkDao', 'Deleted work id=$id (affected $count row(s))');
      return count;
    });
  }
}
