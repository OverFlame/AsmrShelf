import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:sqflite/sqflite.dart';

import '../db/sql_like.dart';
import '../utils/crop_math.dart';
import 'media_rules.dart';

/// 卷封面的来源，[priority] 越小越优先（BUILD_GUIDE 第 19.2 节）。
enum VolumeCoverSource {
  /// ① 卷子树里的白名单图（cover / folder / front / album / albumart /
  /// artwork / jacket）
  whitelistImage(1, '卷内封面图'),

  /// ② 卷子树里路径字典序第一张图
  lexicalImage(2, '卷内第一张图'),

  /// ③ 卷内第一首曲目的内嵌封面
  trackEmbedded(3, '曲目内嵌封面'),

  /// ④ 系列（works）封面兜底
  seriesCover(4, '系列封面');

  const VolumeCoverSource(this.priority, this.label);

  final int priority;
  final String label;
}

/// 一个候选封面。
class VolumeCoverCandidate {
  const VolumeCoverCandidate({
    required this.path,
    required this.source,
    this.fromMediaId,
  });

  /// 封面图路径；来源 3 时是文件内嵌封面的落地缓存路径
  final String path;

  final VolumeCoverSource source;

  /// 来源 1/2 是图片行 id，来源 3 是曲目行 id，来源 4 为 null
  final int? fromMediaId;

  int get priority => source.priority;

  @override
  String toString() =>
      'VolumeCoverCandidate(${source.name}, path=$path, media=$fromMediaId)';
}

/// 卷封面与裁剪的读写（BUILD_GUIDE 第 19.2 / 21.1 / 21.2 节）。
///
/// - 自动候选四级顺序见 [VolumeCoverSource]；
/// - 手动指定的结果写在 `folders.cover_path`，只要它非空就不再被自动扫描
///   覆盖（第 19.2 节「手动优先」）；
/// - 裁剪框写在 `folders.cover_crop`（`左,上,右,下` 四个归一化数），
///   计算全在 [CropMath]，本服务只做换算与存储；
/// - 原图永不修改（第 21.1 节）。
///
/// 文件存在性判断通过构造参数 [fileExists] 注入：没有真实图片也能测候选
/// 解析与「缺图回退」。
class VolumeCoverService {
  VolumeCoverService(this._db, {bool Function(String path)? fileExists})
      : _fileExists = fileExists ?? _defaultFileExists;

  /// 白名单文件名（不含扩展名，小写）。
  ///
  /// 与 `lib/services/file_scanner.dart` 的 `_isCoverImage` 同一张表；那边
  /// 是私有实现，这里复制一份，改那边要同步改这里。
  static const Set<String> coverFileNames = <String>{
    'cover',
    'folder',
    'front',
    'album',
    'albumart',
    'artwork',
    'jacket',
  };

  /// 白名单认的图片扩展名，同样与 `_isCoverImage` 对齐
  static const Set<String> coverExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
  };

  final Database _db;
  final bool Function(String path) _fileExists;

  static bool _defaultFileExists(String path) => File(path).existsSync();

  /// 路径是否是白名单封面图（只看名字与扩展名，不碰磁盘）
  static bool isWhitelistCoverPath(String path) {
    final name = stemOfPath(path).toLowerCase();
    final ext = extOfPath(path);
    return coverFileNames.contains(name) && coverExtensions.contains(ext);
  }

  // ═══ 候选 ═══

  /// 按优先级列出全部可用候选（缺图的来源直接跳过，不会出现空洞）。
  ///
  /// 同一条路径只会出现一次，取它能命中的最高优先级来源。
  Future<List<VolumeCoverCandidate>> listCandidates(int folderId) async {
    final dirs = await _volumeDirs(folderId);
    final images = dirs.isEmpty ? <String>[] : await _imagePathsInDirs(dirs);
    final out = <VolumeCoverCandidate>[];
    final seen = <String>{};

    void tryAdd(String path, VolumeCoverSource source, {int? mediaId}) {
      if (path.isEmpty || seen.contains(path)) return;
      if (!_fileExists(path)) return;
      seen.add(path);
      out.add(VolumeCoverCandidate(
          path: path, source: source, fromMediaId: mediaId));
    }

    // ① 白名单图（第一张存在的；缺图就继续找下一张白名单图）
    var before = out.length;
    for (final path in images) {
      if (!isWhitelistCoverPath(path)) continue;
      tryAdd(path, VolumeCoverSource.whitelistImage);
      if (out.length > before) break;
    }
    // ② 字典序第一张图（已被 ① 选中就顺延到下一张，避免候选重复）
    before = out.length;
    for (final path in images) {
      tryAdd(path, VolumeCoverSource.lexicalImage);
      if (out.length > before) break;
    }
    // ③ 卷内第一首曲目的内嵌封面（缺图就顺延到下一首）
    before = out.length;
    for (final row in await _audioCoverRows(dirs)) {
      tryAdd(
        row['cover_path'] as String? ?? '',
        VolumeCoverSource.trackEmbedded,
        mediaId: row['id'] as int?,
      );
      if (out.length > before) break;
    }
    // ④ 系列封面兜底
    final series = await seriesCoverPath(folderId);
    if (series != null) {
      tryAdd(series, VolumeCoverSource.seriesCover);
    }
    return out;
  }

  /// 四级顺序里最优先的候选；一个都没有返回 null
  Future<VolumeCoverCandidate?> resolve(int folderId) async {
    final candidates = await listCandidates(folderId);
    return candidates.isEmpty ? null : candidates.first;
  }

  /// 界面实际该显示的封面：手动指定优先，其次自动候选。
  ///
  /// 这个方法**不写库**，适合列表渲染时调用。
  ///
  /// 手动那一份文件可能已经被删掉或搬走了（用户整理目录、换机器），所以
  /// 也要过一遍存在性判断：直接返回它会让卡片一直空着，而自动候选明明
  /// 还在，本该兜底。
  Future<String?> effectiveCover(int folderId) async {
    final manual = await currentCover(folderId);
    if (manual != null && manual.isNotEmpty && _fileExists(manual)) {
      return manual;
    }
    return (await resolve(folderId))?.path;
  }

  // ═══ 手动指定 ═══

  /// 读 `folders.cover_path`（手动指定或上次自动结果）
  Future<String?> currentCover(int folderId) async {
    final rows = await _db.query(
      'folders',
      columns: <String>['cover_path'],
      where: 'id = ?',
      whereArgs: <Object?>[folderId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final value = rows.first['cover_path'] as String?;
    return (value == null || value.isEmpty) ? null : value;
  }

  /// 手动指定卷封面；传 null 或空串 = 清掉，退回自动候选。
  Future<void> setCover(int folderId, String? path) async {
    await _db.update(
      'folders',
      <String, Object?>{
        'cover_path': (path == null || path.isEmpty) ? null : path,
      },
      where: 'id = ?',
      whereArgs: <Object?>[folderId],
    );
  }

  /// 清掉手动指定，交还给自动候选
  Future<void> clearCover(int folderId) => setCover(folderId, null);

  // ═══ 裁剪 ═══

  /// 读 `folders.cover_crop` 并解成归一化矩形；没设过返回 null
  Future<Rect?> cropOf(int folderId) async {
    final rows = await _db.query(
      'folders',
      columns: <String>['cover_crop'],
      where: 'id = ?',
      whereArgs: <Object?>[folderId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CropMath.decode(rows.first['cover_crop'] as String?);
  }

  /// 写裁剪框；传 null 或整幅图 = 清空（等比适应）。
  Future<void> setCrop(int folderId, Rect? crop) async {
    await _db.update(
      'folders',
      <String, Object?>{'cover_crop': CropMath.encode(crop)},
      where: 'id = ?',
      whereArgs: <Object?>[folderId],
    );
  }

  /// 一次写好封面和裁剪（界面上「确定」按钮的落点）
  Future<void> setCoverWithCrop(
    int folderId,
    String? path,
    Rect? crop,
  ) async {
    await _db.update(
      'folders',
      <String, Object?>{
        'cover_path': (path == null || path.isEmpty) ? null : path,
        'cover_crop': CropMath.encode(crop),
      },
      where: 'id = ?',
      whereArgs: <Object?>[folderId],
    );
  }

  /// 所属系列的封面（`works.cover_path`）；卷没挂系列返回 null
  Future<String?> seriesCoverPath(int folderId) async {
    final rows = await _db.rawQuery(
      'SELECT w.cover_path AS cover FROM folders f '
      'JOIN works w ON w.id = f.work_id WHERE f.id = ? LIMIT 1',
      <Object?>[folderId],
    );
    if (rows.isEmpty) return null;
    final value = rows.first['cover'] as String?;
    return (value == null || value.isEmpty) ? null : value;
  }

  // ═══ 内部 ═══

  /// 卷的子树的全部目录（含卷自己及其全部子孙），按 id 去重
  Future<List<String>> _volumeDirs(int folderId) async {
    final ids = <int>{folderId};
    final queue = <int>[folderId];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      final children = await _db.query(
        'folders',
        columns: <String>['id'],
        where: 'parent = ?',
        whereArgs: <Object?>[current],
      );
      for (final row in children) {
        final id = row['id'] as int;
        if (ids.add(id)) queue.add(id);
      }
    }

    final idList = ids.toList(growable: false);
    final out = <String>[];
    const chunk = 500;
    for (var start = 0; start < idList.length; start += chunk) {
      final slice =
          idList.sublist(start, math.min(start + chunk, idList.length));
      final placeholders = List.filled(slice.length, '?').join(',');
      final rows = await _db.query(
        'folder_paths',
        columns: <String>['path'],
        where: 'folder_id IN ($placeholders)',
        whereArgs: slice,
      );
      for (final row in rows) {
        final path = row['path'] as String?;
        if (path != null && path.isNotEmpty) out.add(path);
      }
    }
    out.sort();
    return out;
  }

  /// 子树里的图片路径，按路径字典序（不区分大小写）排
  Future<List<String>> _imagePathsInDirs(List<String> dirs) async {
    final out = <String>[];
    const chunk = 100;
    for (var start = 0; start < dirs.length; start += chunk) {
      final slice = dirs.sublist(start, math.min(start + chunk, dirs.length));
      final clauses = <String>[];
      final args = <Object?>[];
      for (final dir in slice) {
        clauses.add("path LIKE ? $sqlLikeEscape");
        args.add('${escapeLike(_pathPrefix(dir))}%');
      }
      final rows = await _db.query(
        'media',
        columns: <String>['path'],
        where: "media_type = 'image' AND (${clauses.join(' OR ')})",
        whereArgs: args,
        orderBy: 'path COLLATE NOCASE, path',
      );
      for (final row in rows) {
        final path = row['path'] as String?;
        if (path != null && path.isNotEmpty) out.add(path);
      }
    }
    return out;
  }

  /// 子树里带内嵌封面的曲目，按「卷内曲序」排（sort_key 优先，其次文件名）
  Future<List<Map<String, Object?>>> _audioCoverRows(List<String> dirs) async {
    if (dirs.isEmpty) return const <Map<String, Object?>>[];
    final out = <Map<String, Object?>>[];
    const chunk = 100;
    for (var start = 0; start < dirs.length; start += chunk) {
      final slice = dirs.sublist(start, math.min(start + chunk, dirs.length));
      final clauses = <String>[];
      final args = <Object?>[];
      for (final dir in slice) {
        clauses.add("path LIKE ? $sqlLikeEscape");
        args.add('${escapeLike(_pathPrefix(dir))}%');
      }
      final rows = await _db.query(
        'media',
        columns: <String>['id', 'path', 'cover_path'],
        where: "media_type = 'audio' AND cover_path IS NOT NULL "
            "AND cover_path <> '' AND (${clauses.join(' OR ')})",
        whereArgs: args,
        orderBy: "COALESCE(NULLIF(sort_key, ''), filename) COLLATE NOCASE, "
            'path COLLATE NOCASE',
      );
      out.addAll(rows);
    }
    return out;
  }

  /// 目录 → LIKE 前缀；目录里的分隔符风格按目录自己判断
  static String _pathPrefix(String dir) {
    var d = dir;
    while (d.length > 1 && (d.endsWith('/') || d.endsWith('\\'))) {
      d = d.substring(0, d.length - 1);
    }
    if (d.isEmpty) return '/';
    final sep =
        (d.contains('\\') || RegExp(r'^[A-Za-z]:').hasMatch(d)) ? '\\' : '/';
    return d.endsWith(sep) ? d : '$d$sep';
  }
}
