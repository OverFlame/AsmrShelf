/// 自动导入的「先看清单」扫描。
///
/// 只读文件系统与数据库，不写库、不改封面。界面拿到候选列表，用户勾选后
/// 再交给 AppState 落库。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../db/media_dao.dart';
import '../db/work_dao.dart';
import '../db/work_metadata_dao.dart';
import 'dlsite/work_code.dart';
import 'import_scanner.dart';

/// 候选目录在清单里的五态。
enum AutoImportState {
  /// 库里没有这个目录，导入会新建作品。
  newWork('新建作品'),

  /// 作品已存在，但目录里有没入库的音频。
  newTracks('有新增文件'),

  /// 作品已存在，曲目也都入库了。
  unchanged('无变化'),

  /// 用户之前标记过忽略。
  ignored('已忽略'),

  /// 目录读不了（权限、断链、被占用）。
  unreadable('读不了');

  const AutoImportState(this.label);

  final String label;
}

/// 一个待确认的候选目录。
class AutoImportCandidate {
  const AutoImportCandidate({
    required this.rootPath,
    required this.dirPath,
    required this.name,
    required this.state,
    required this.audioCount,
    required this.newCount,
    this.workId,
    this.code,
    this.reason,
  });

  final String rootPath;
  final String dirPath;

  /// 目录名剥掉编号后的名字，用作清单里的标题。
  final String name;

  final AutoImportState state;

  /// 目录里扫到的音频总数（忽略特典目录）。
  final int audioCount;

  /// 还没入库的音频数。
  final int newCount;

  /// 已有作品的 id；新建时为 null。
  final int? workId;

  /// 目录名里的 RJ 或 VJ 编号。
  final String? code;

  /// 补充说明，例如「同编号的作品已存在」。
  final String? reason;

  bool get selectable =>
      state == AutoImportState.newWork || state == AutoImportState.newTracks;

  @override
  String toString() =>
      'AutoImportCandidate($name, ${state.label}, +$newCount/$audioCount)';
}

/// 扫描多个根目录，产出候选清单。
class AutoImportScanner {
  AutoImportScanner(this._db);

  final Database _db;

  /// [roots] 按设置里的顺序处理；[ignored] 是用户标记忽略的目录；
  /// [nested] 为 true 时允许作品再套一层（与 [scanImportTree] 一致）。
  Future<List<AutoImportCandidate>> scan({
    required Iterable<String> roots,
    Iterable<String> ignored = const [],
    bool nested = false,
    int maxDepth = 3,
  }) async {
    final workByRoot = <String, Work>{};
    for (final work in await WorkDao(_db).listAll()) {
      final rootPath = work.rootPath;
      if (rootPath == null) continue;
      workByRoot[_norm(rootPath)] = work;
    }
    final ignoredNorm = ignored.map(_norm).toSet();
    final metadataDao = WorkMetadataDao(_db);
    final mediaDao = MediaDao(_db);

    final out = <AutoImportCandidate>[];
    final counters = <String, int>{};
    for (final root in roots) {
      final rootDir = Directory(root);
      List<Directory> children;
      try {
        children = await rootDir
            .list(followLinks: false)
            .where((e) => e is Directory && !p.basename(e.path).startsWith('.'))
            .cast<Directory>()
            .toList();
      } catch (_) {
        continue;
      }
      children.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final dir in children) {
        final name = p.basename(dir.path);
        if (ignoredNorm.contains(_norm(dir.path))) {
          out.add(AutoImportCandidate(
            rootPath: root,
            dirPath: dir.path,
            name: name,
            state: AutoImportState.ignored,
            audioCount: 0,
            newCount: 0,
          ));
          continue;
        }

        List<String> files;
        try {
          files = await _audioFiles(dir);
        } catch (_) {
          out.add(AutoImportCandidate(
            rootPath: root,
            dirPath: dir.path,
            name: name,
            state: AutoImportState.unreadable,
            audioCount: 0,
            newCount: 0,
            reason: '目录读不了，可能被占用或没有权限',
          ));
          continue;
        }
        if (files.isEmpty) continue; // 不是作品目录，不进清单。

        final work = workByRoot[_norm(dir.path)];
        final existing = await mediaDao.existingPaths(files, type: MediaType.audio);
        final newCount = files.length - existing.length;
        final parsed = parseWorkCode(name);
        final code = parsed?.code;

        if (work == null) {
          String? reason;
          if (code != null) {
            final meta = await metadataDao.getByRjCode(code);
            if (meta != null) {
              reason = '同编号 $code 的作品已存在，导入会再建一份';
            }
          }
          out.add(AutoImportCandidate(
            rootPath: root,
            dirPath: dir.path,
            name: (parsed?.title.trim().isNotEmpty ?? false)
                ? parsed!.title.trim()
                : name,
            state: AutoImportState.newWork,
            audioCount: files.length,
            newCount: files.length,
            code: code,
            reason: reason,
          ));
        } else {
          out.add(AutoImportCandidate(
            rootPath: root,
            dirPath: dir.path,
            name: work.name,
            state: newCount > 0
                ? AutoImportState.newTracks
                : AutoImportState.unchanged,
            audioCount: files.length,
            newCount: newCount,
            workId: work.id,
            code: code,
          ));
        }
      }
      counters[root] = (counters[root] ?? 0) + 1;
    }
    return out;
  }

  /// 与 [_planWork] 的口径一致：递归、只看导入白名单扩展名、跳过特典目录。
  Future<List<String>> _audioFiles(Directory dir) async {
    final files = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!importAudioExtensions.contains(ext.substring(1))) continue;
      if (p.split(entity.path).any((s) => s == '特典')) continue;
      files.add(entity.path);
    }
    return files;
  }
}

/// Windows 路径大小写不敏感，其余平台保持原样。
String _norm(String path) {
  final normalized = p.normalize(path);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}
