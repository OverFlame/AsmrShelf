import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show sqfliteFfiInit, databaseFactoryFfi;

import '../services/data_dir_service.dart';
import '../services/media_rules.dart';
import '../utils/log_util.dart';
import 'tables.dart';

/// 数据库管理器 — 初始化、打开、迁移、单例
///
/// Windows / Linux 使用 sqflite_common_ffi；Android / iOS 使用 sqflite 插件。
class DatabaseManager {
  static DatabaseManager? _instance;
  static Database? _db;

  DatabaseManager._();

  static DatabaseManager get instance {
    _instance ??= DatabaseManager._();
    return _instance!;
  }

  Database get db {
    if (_db == null) {
      throw StateError('Database not initialized. Call init() first.');
    }
    return _db!;
  }

  bool get isOpen => _db != null;

  /// 桌面端切到 ffi 工厂。启动前的 [MigrationGuard] 要先开库检查版本，
  /// 它比 [init] 更早，所以单独公开。
  static void ensureFactory() {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<void> init() async {
    if (_db != null) {
      logWarn('Database', 'Already initialized, skip duplicate init()');
      return;
    }
    logInfo('Database', 'Initializing...');
    ensureFactory();

    final dir = await DataDirService.instance.dataDir;
    final dbPath = p.join(dir, 'asmr_shelf.db');
    logInfo('Database', 'DB path: $dbPath');

    _db = await openDatabase(
      dbPath,
      version: Tables.version,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: (db, version) async {
        logInfo('Database', 'Creating tables (v$version)');
        await Tables.createAll(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        logWarn('Database', 'Refusing upgrade v$oldVersion -> v$newVersion');
        await Tables.applyMigrations(db, oldVersion, newVersion);
      },
      // 库比应用新时 sqflite 走 downgrade 回调：默认什么都不做，会把新库
      // 当成本版本继续读写。这里同样拒绝。
      onDowngrade: (db, oldVersion, newVersion) async {
        logWarn('Database', 'Refusing downgrade v$oldVersion -> v$newVersion');
        await Tables.applyMigrations(db, oldVersion, newVersion);
      },
    );

    // 目录查询用 `path COLLATE NOCASE` 的区间比较。索引建在打开库之后，
    // 老库不用升 schema 也能拿到；新库由 Tables.createAll 一并创建。
    await _db!.execute('CREATE INDEX IF NOT EXISTS idx_media_path_nocase '
        'ON media(path COLLATE NOCASE)');
    await _db!.execute('CREATE INDEX IF NOT EXISTS idx_media_type_path_nocase '
        'ON media(media_type, path COLLATE NOCASE)');

    // journal_mode=WAL 会返回一行结果，Android 端 execSQL 不允许，需用 rawQuery。
    // （Android 8+ 本身默认 WAL，此处桌面端开启；Android 端该语句会被安全执行。）
    await _db!.rawQuery('PRAGMA journal_mode=WAL');
    await _backfillSortKeys(_db!);
    logInfo('Database', 'Initialized OK (WAL+FK enabled)');
  }

  /// 补齐 `media.sort_key`。这一列是 v7 用 ALTER TABLE 加的，纯 SQL 迁移
  /// 没法按 Dart 侧的补零规则回填，老库里全是 NULL：自然排序会退化成按
  /// 文件名字符串比，`10.jpg` 就排到 `2.jpg` 前面（BUILD_GUIDE 20.2）。
  ///
  /// 只补缺的行，补完这次查询就一直是空的，每次启动接近零成本。
  static Future<void> _backfillSortKeys(Database db) async {
    final rows = await db.query(
      'media',
      columns: ['id', 'path'],
      where: "sort_key IS NULL OR sort_key = ''",
    );
    if (rows.isEmpty) return;
    logInfo('Database', 'Backfilling sort_key for ${rows.length} media rows');
    final batch = db.batch();
    for (final row in rows) {
      batch.update(
        'media',
        {'sort_key': sortKeyOfPath(row['path'] as String? ?? '')},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> close() async {
    final db = _db;
    if (db == null) {
      logWarn('Database', 'close() called but no open connection');
      return;
    }
    // 先置空再关：并发调用方看到的是「已关闭」，而不是一个正在关闭的句柄。
    _db = null;
    logInfo('Database', 'Closing connection');
    await db.close();
  }
}
