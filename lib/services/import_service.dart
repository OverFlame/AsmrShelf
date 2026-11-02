// 命名参数不能以下划线开头，字段 `_workDao` 等无法写成 `this._workDao`
// 的初始化形参。这 3 条 prefer_initializing_formals 是 lint 误报。
// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../db/folder_dao.dart';
import '../db/track_dao.dart';
import '../db/work_dao.dart';
import '../utils/log_util.dart';
import 'cover_service.dart';
import 'file_scanner.dart';
import 'metadata_service.dart';

/// 导入进度事件
class ImportProgress {
  final int current;
  final int total;
  final String currentFile;

  ImportProgress({
    required this.current,
    required this.total,
    required this.currentFile,
  });

  double get percent => total > 0 ? current / total : 0;
}

/// 批量导入服务
/// 流程：扫描目录 → 读取元数据/内嵌封面 → 写入 DB → 镜像目录树 → 自动封面
class ImportService {
  final WorkDao _workDao;
  final FolderDao _folderDao;
  final TrackDao _trackDao;

  /// 所有实例共享。实例字段拦不住并发导入：调用方每次都新建实例。
  /// AppState 才是主守卫，这里兜住直接调用的场景。
  static bool _isImporting = false;
  bool get isImporting => _isImporting;

  ImportService({
    required WorkDao workDao,
    required FolderDao folderDao,
    required TrackDao trackDao,
  })  : _workDao = workDao,
        _folderDao = folderDao,
        _trackDao = trackDao;

  factory ImportService.fromDB() {
    final db = DatabaseManager.instance.db;
    return ImportService(
      workDao: WorkDao(db),
      folderDao: FolderDao(db),
      trackDao: TrackDao(db),
    );
  }

  /// 导入目录到指定作品 [workId]。
  ///
  /// [scan] 可由调用方预先扫描并传入，省掉一次目录遍历（AppState 建作品前要先确认
  /// 目录里有音频）。
  Stream<ImportProgress> importDirectory(String dirPath,
      {required int workId, ScanResult? scan, String library = 'audio'}) async* {
    if (_isImporting) {
      // 静默返回会让直接调用方以为导入成功。AppState 的主守卫会先挡住，
      // 这里兜住绕过 AppState 的调用，把拒绝理由显式交给调用方。
      throw StateError('已有导入任务进行中');
    }
    _isImporting = true;
    try {
      final scanned = scan ?? await FileScanner.scanDirectoryOffThread(dirPath);
      if (scanned.audioPaths.isEmpty) {
        logInfo('Import', 'importDirectory: 目录内无音频 "$dirPath"');
        return;
      }

      final existing = await _trackDao.existingPaths(scanned.audioPaths);
      final newPaths =
          scanned.audioPaths.where((p) => !existing.contains(p)).toList();
      final total = newPaths.length;
      logInfo('Import',
          'scanned ${scanned.audioPaths.length} total, $total new, ${scanned.audioPaths.length - total} dupes');

      // 先镜像物理目录树，再写曲目（报告第 18 项）。
      //
      // 反过来的话，建树失败时曲目已经落库、却没有任何 folder_paths 覆盖它们：
      // 曲目搜得到、树里进不去，而且调用方看到的是「导入完成」。
      await _mirrorFolderTree(dirPath, scanned.audioPaths, workId,
          library: library);

      // 元数据解析整批丢到单独 isolate，主 isolate 只做落库和进度（报告第 25 项）。
      //
      // 分批还能把内嵌封面的内存占用压在几十张图以内，别一次读几千首。
      const batchSize = 32;
      for (int start = 0; start < newPaths.length; start += batchSize) {
        final end = start + batchSize < newPaths.length
            ? start + batchSize
            : newPaths.length;
        final metas = await MetadataService.readAll(newPaths.sublist(start, end));

        final items = <TrackItem>[];
        for (int i = start; i < end; i++) {
          final path = newPaths[i];
          final file = File(path);
          final meta = metas[i - start];

          int sizeBytes = 0;
          try {
            sizeBytes = await file.length();
          } catch (error) {
            // 文件被删或权限不足：大小与时间会以 0 入库，至少留一条线索。
            logWarn('Import', '读不到文件大小，将按 0 入库：$path', error);
          }
          int mtime = 0;
          try {
            // 用异步版：同步版在主 isolate 上做一次文件 IO（报告第 25 项）。
            mtime = (await file.lastModified()).millisecondsSinceEpoch;
          } catch (error) {
            logWarn('Import', '读不到修改时间，将按 0 入库：$path', error);
          }

          final ext = p.extension(path).toLowerCase();
          final filename = p.basename(path);
          final now = DateTime.now().millisecondsSinceEpoch;

          // 多字幕归属模型在阶段 6 落地（BUILD_GUIDE 第 23.6 节），
          // 这一步先沿用 media.subtitle_path 记下优先级最高的那一条。
          final matched = scanned.subtitleByAudio[path];
          final subtitlePath =
              (matched == null || matched.isEmpty) ? null : matched.first;

          items.add(TrackItem(
            path: path,
            filename: filename,
            title: meta.title,
            artist: meta.artist,
            album: meta.album,
            durationMs: meta.durationMs,
            format: ext.isNotEmpty ? ext.substring(1) : 'unknown',
            fileSize: sizeBytes > 0 ? sizeBytes : null,
            fileMtime: mtime > 0 ? mtime : null,
            subtitlePath: subtitlePath,
            addedAt: now,
          ));
        }

        // 整批写库放一个事务：中途失败不会留下半批曲目，
        // 也避免每首各开一次事务（报告第 26 项）。
        final ids = await _trackDao.insertMany(items);

        // 内嵌封面是文件 IO，留在事务外逐张写，避免长事务卡住数据库。
        for (int i = start; i < end; i++) {
          final id = ids[i - start];
          final meta = metas[i - start];
          if (id > 0 && meta.pictureBytes != null) {
            final coverPath = await CoverService.writeEmbedded(
                id, meta.pictureBytes!, meta.pictureMimetype ?? 'image/jpeg');
            if (coverPath != null) await _trackDao.setCoverPath(id, coverPath);
          }

          yield ImportProgress(
              current: i + 1, total: total, currentFile: newPaths[i]);
        }
      }

      // 自动封面
      await _ensureWorkCover(
          workId, scanned.coverFiles, dirPath, scanned.audioPaths);
      logInfo('Import', 'importDirectory done for work=$workId');
    } finally {
      _isImporting = false;
    }
  }

  // ═══ 目录树镜像 ═══

  /// 按物理磁盘目录镜像建立文件夹父子层级，全部归属 [workId]。
  Future<void> _mirrorFolderTree(
      String root, List<String> audioPaths, int workId,
      {String library = 'audio'}) async {
    final rootNorm = _normPath(root);
    if (rootNorm.isEmpty) return;

    final dirs = <String>{};
    for (final a in audioPaths) {
      final aNorm = _normPath(a);
      if (!_isUnder(aNorm, rootNorm)) continue;
      var dir = _normPath(p.dirname(aNorm));
      while (true) {
        dir = _normPath(dir);
        dirs.add(dir);
        if (dir == rootNorm) break;
        final parent = _normPath(p.dirname(dir));
        if (parent == dir) break; // 文件系统根
        dir = parent;
      }
    }

    final sorted = dirs.toList()
      ..sort((a, b) => _dirDepth(a).compareTo(_dirDepth(b)));

    final map = <String, VirtualFolder>{};
    for (final dir in sorted) {
      final parentDir = _normPath(p.dirname(dir));
      final expectedParentId = map[parentDir]?.id;
      final base = p.basename(dir);
      // 取或建在一个事务里完成，父级与归属一并对齐（报告第 17 项）。
      map[dir] = await _folderDao.ensureByPath(
        dir,
        name: base.isEmpty ? dir : base,
        parentId: expectedParentId,
        workId: workId,
        library: library,
      );
    }
  }

  /// 作品尚无封面时，自动设置：优先根目录下 cover 图，否则第一首内嵌封面
  Future<void> _ensureWorkCover(
      int workId, List<String> coverFiles, String root, List<String> audioPaths) async {
    final work = await _workDao.getById(workId);
    if (work == null) return;
    if (work.coverPath != null && File(work.coverPath!).existsSync()) return;

    if (coverFiles.isNotEmpty) {
      final rootNorm = _normPath(root);
      final rootCover = coverFiles.firstWhere(
        (c) => _normPath(p.dirname(c)) == rootNorm,
        orElse: () => coverFiles.first,
      );
      await _workDao.setCover(workId, rootCover);
      return;
    }

    for (final ap in audioPaths) {
      final t = await _trackDao.getByPath(ap);
      if (t != null && t.coverPath != null && File(t.coverPath!).existsSync()) {
        // 内嵌封面落在 track_ 缓存里，缓存超额清理会把它删掉；
        // 另存一份 work_ 前缀的副本，作品封面才留得住。
        final copied = await CoverService.importCover(t.coverPath!, workId);
        await _workDao.setCover(workId, copied ?? t.coverPath!);
        return;
      }
    }
  }

  // ═══ 路径工具 ═══

  static String _normPath(String s) {
    var x = s;
    while (x.endsWith('\\') || x.endsWith('/')) {
      x = x.substring(0, x.length - 1);
    }
    return x;
  }

  static bool _isUnder(String path, String dir) {
    final a = path.toLowerCase();
    final b = dir.toLowerCase();
    if (a == b) return false;
    return a.startsWith('$b\\') || a.startsWith('$b/');
  }

  static int _dirDepth(String dir) {
    return dir.split(RegExp(r'[\\/]')).length;
  }
}
