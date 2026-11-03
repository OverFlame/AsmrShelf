import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../db/database.dart';
import '../db/tables.dart';
import '../utils/file_io.dart';
import '../utils/log_util.dart';
import 'data_dir_service.dart';

/// 一次待确认的结构升级：库文件里的版本号与 [Tables.version] 不一致。
///
/// [dbPath] 只用来定位库文件，此时数据库还没被升级，一行也没动。
class MigrationPlan {
  const MigrationPlan({
    required this.fromVersion,
    required this.toVersion,
    required this.dbPath,
  });

  final int fromVersion;
  final int toVersion;
  final String dbPath;
}

/// 升级前备份的结果。界面确认页用它显示备份位置。
class MigrationBackup {
  const MigrationBackup({
    required this.plan,
    required this.backupPath,
    required this.bytes,
  });

  final MigrationPlan plan;
  final String backupPath;
  final int bytes;
}

/// 一份可还原的备份，供还原列表显示。
class BackupEntry {
  const BackupEntry({
    required this.path,
    required this.version,
    required this.bytes,
    required this.modified,
  });

  final String path;
  final int version;
  final int bytes;
  final DateTime modified;

  /// 文件名，列表里直接显示。
  String get name => p.basename(path);
}

/// 启动前的结构升级守卫。
///
/// 顺序固定为：检查版本 → checkpoint 并备份 → 界面确认 → 才允许
/// [DatabaseManager.init] 走 `Tables.applyMigrations` 的删表重建。
/// 任何一步失败都停在确认页之前，现有库原样保留。
class MigrationGuard {
  MigrationGuard._();

  static final MigrationGuard instance = MigrationGuard._();

  static const String backupDirName = 'backup';

  /// 只留最近 10 份备份。升级失败才会用到，留多了只是占磁盘。
  static const int keepBackups = 10;

  /// 检查现有库的结构版本。没有库或已是最新则返回 null。
  ///
  /// 故意不传 version：sqflite 只在显式传 version 时才调 onCreate/onUpgrade，
  /// 这次打开绝不会触发 [Tables.applyMigrations] 的删表重建。
  Future<MigrationPlan?> inspect() async {
    DatabaseManager.ensureFactory();
    final dir = await DataDirService.instance.dataDir;
    final dbPath = p.join(dir, 'asmr_shelf.db');
    if (!await File(dbPath).exists()) return null;

    // singleInstance: false：这次连接只读版本，绝不能和应用里正在用的连接共享，
    // 否则 close() 会把应用的库一起关掉。
    final db = await openDatabase(dbPath, singleInstance: false);
    int version;
    try {
      version = _readVersion(await db.rawQuery('PRAGMA user_version'));
    } finally {
      await db.close();
    }
    if (version == Tables.version) return null;

    logInfo(
        'Migration', '库结构 v$version 与代码 v${Tables.version} 不一致，需要重建');
    return MigrationPlan(
      fromVersion: version,
      toVersion: Tables.version,
      dbPath: dbPath,
    );
  }

  /// 把现有库 checkpoint 后复制到 `<数据目录>/backup/`，再回读校验。
  ///
  /// checkpoint 把 -wal 里的页并回主库，备份只需一个文件；不 checkpoint 的话
  /// 只拷主库会丢掉最近一次写入。
  Future<MigrationBackup> backup(MigrationPlan plan) async {
    DatabaseManager.ensureFactory();

    final db = await openDatabase(plan.dbPath, singleInstance: false);
    try {
      final rows = await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      final busy = rows.isEmpty ? 0 : rows.first['busy'];
      if (busy is int && busy != 0) {
        throw StateError('数据库正忙，无法完成升级前备份。请关闭其他实例后重试。');
      }
    } finally {
      await db.close();
    }

    final dir = Directory(p.join(p.dirname(plan.dbPath), backupDirName));
    await dir.create(recursive: true);
    final src = File(plan.dbPath);
    final dst = File(p.join(dir.path, 'db-v${plan.fromVersion}-${_stamp()}.db'));
    await src.copy(dst.path);

    final bytes = await src.length();
    final copied = await dst.length();
    if (copied != bytes) {
      await _deleteQuietly(dst);
      throw StateError('备份校验失败，字节数 $copied != $bytes: ${dst.path}');
    }

    // 备份必须自己能开、版本对，否则不如不做。
    final check = await openDatabase(dst.path, singleInstance: false);
    try {
      final version = _readVersion(await check.rawQuery('PRAGMA user_version'));
      if (version != plan.fromVersion) {
        throw StateError(
            '备份版本不符，期望 v${plan.fromVersion}，实际 v$version: ${dst.path}');
      }
    } finally {
      await check.close();
    }

    logInfo('Migration',
        '已备份 v${plan.fromVersion} 媒体库到 ${dst.path}（$bytes 字节）');
    await _prune(dir);
    return MigrationBackup(plan: plan, backupPath: dst.path, bytes: bytes);
  }

  /// 列出 `<数据目录>/backup/` 下可还原的备份，新的在前。
  Future<List<BackupEntry>> listBackups() async {
    final dir = Directory(p.join(
        await DataDirService.instance.dataDir, backupDirName));
    if (!await dir.exists()) return const [];

    final entries = <BackupEntry>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final match =
          RegExp(r'^db-v(\d+)-').firstMatch(p.basename(entity.path));
      if (match == null) continue;
      entries.add(BackupEntry(
        path: entity.path,
        version: int.parse(match.group(1)!),
        bytes: await entity.length(),
        modified: await entity.lastModified(),
      ));
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  /// 用一个备份覆盖当前库，返回备份的结构版本。
  ///
  /// 只能在 [DatabaseManager.init] 之前调用：此时应用没有库连接，
  /// 替换文件不会被正在运行的 SQLite 连接看到。
  ///
  /// 旧 `-wal` / `-shm` 先改名藏起来，主库替换成功后才删除。旧 WAL 若留到
  /// 替换之后，SQLite 下次打开会把旧页套到新文件上，库直接坏掉。
  Future<int> restore(String backupPath) async {
    final dir = await DataDirService.instance.dataDir;
    final dbPath = p.join(dir, 'asmr_shelf.db');
    final src = File(backupPath);
    if (!await src.exists()) {
      throw StateError('备份文件不存在: $backupPath');
    }

    DatabaseManager.ensureFactory();
    // 先确认备份自己能开、版本号可读，免得把坏文件盖到库上。
    final check = await openDatabase(backupPath, singleInstance: false);
    int version;
    try {
      version = _readVersion(await check.rawQuery('PRAGMA user_version'));
    } finally {
      await check.close();
    }

    // 不能先删 -wal/-shm：主库替换失败时，旧 WAL 里已提交但未 checkpoint
    // 的事务会永久丢失。先改名藏起来，主库替换成功后再删；失败则改回原名。
    final movedSidecars = <String, String>{};
    var mainReplaced = false;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    try {
      for (final suffix in const ['-wal', '-shm']) {
        final side = File('$dbPath$suffix');
        if (!await side.exists()) continue;
        final hidden = '$dbPath$suffix.restore-$stamp';
        await side.rename(hidden);
        movedSidecars[side.path] = hidden;
      }

      await writeFileAtomic(File(dbPath), (tmp) async {
        await src.copy(tmp.path);
      });
      mainReplaced = true;

      final bytes = await src.length();
      final restored = await File(dbPath).length();
      if (restored != bytes) {
        throw StateError('还原校验失败，字节数 $restored != $bytes: $dbPath');
      }

      for (final hidden in movedSidecars.values) {
        final file = File(hidden);
        if (await file.exists()) await file.delete();
      }
    } catch (e) {
      if (!mainReplaced) {
        // 主库还是旧的，把原来的 -wal/-shm 放回去，上一会话的事务仍可用。
        for (final entry in movedSidecars.entries) {
          final hidden = File(entry.value);
          if (!await hidden.exists()) continue;
          final original = File(entry.key);
          if (await original.exists()) await original.delete();
          await hidden.rename(entry.key);
        }
      } else {
        // 主库已经换成新文件，旧 WAL 绝不能再套回去；尽力清掉隐藏文件。
        for (final hidden in movedSidecars.values) {
          try {
            final file = File(hidden);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }
      rethrow;
    }

    logInfo('Migration', '已把备份 ${src.path} 还原到 $dbPath（v$version）');
    return version;
  }

  static int _readVersion(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return 0;
    final value = rows.first.values.first;
    return value is int ? value : int.tryParse('$value') ?? 0;
  }

  /// 本地时间戳，定宽便于按文件名排序。
  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '-${now.millisecond.toString().padLeft(3, '0')}';
  }

  Future<void> _prune(Directory backupDir) async {
    try {
      final files = <File>[];
      await for (final entity in backupDir.list()) {
        if (entity is File && p.basename(entity.path).startsWith('db-v')) {
          files.add(entity);
        }
      }
      if (files.length <= keepBackups) return;
      files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final file in files.take(files.length - keepBackups)) {
        await _deleteQuietly(file);
      }
    } catch (e) {
      logWarn('Migration', '清理旧备份失败: $e');
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (e) {
      logWarn('Migration', '删除备份失败 ${file.path}: $e');
    }
  }
}
