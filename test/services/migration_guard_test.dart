import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/tables.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/migration_guard.dart';
import 'package:asmrshelf/utils/log_util.dart';

import '../support/test_env.dart';

void main() {
  sqfliteFfiInit();

  late Directory root;
  late String dataDir;
  late String dbPath;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('asmrshelf_guard');
    PathProviderPlatform.instance = FakePathProvider(root.path);
    DataDirService.instance.resetCache();
    // 这些用例会触发 MigrationGuard 的 logInfo，没有文件 sink 时只走控制台。
    LogUtil.detachFileSink();
    dataDir = await DataDirService.instance.dataDir;
    dbPath = p.join(dataDir, 'asmr_shelf.db');
  });

  tearDown(() async {
    if (DatabaseManager.instance.isOpen) {
      await DatabaseManager.instance.close();
    }
    DataDirService.instance.resetCache();
    await root.delete(recursive: true);
  });

  /// 造一个指定版本的老库，带一行数据。
  Future<void> seedVersion(int version) async {
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE media ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'path TEXT NOT NULL UNIQUE, '
            'media_type TEXT NOT NULL)',
          );
        },
      ),
    );
    await db.insert('media', {'path': '/m/keep.jpg', 'media_type': 'image'});
    await db.close();
  }

  Future<int> versionOf(String path) async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final rows = await db.rawQuery('PRAGMA user_version');
      return rows.first.values.first! as int;
    } finally {
      await db.close();
    }
  }

  test('没有库文件时不备份也不拦启动', () async {
    expect(await MigrationGuard.instance.inspect(), isNull);
    expect(Directory(p.join(dataDir, 'backup')).existsSync(), isFalse);
  });

  test('当前版本直接放过，不产生备份', () async {
    await seedVersion(Tables.version);

    expect(await MigrationGuard.instance.inspect(), isNull);
    expect(Directory(p.join(dataDir, 'backup')).existsSync(), isFalse);
  });

  test('旧库返回升级计划，备份可打开且数据都在', () async {
    await seedVersion(9);

    final plan = await MigrationGuard.instance.inspect();
    expect(plan, isNotNull);
    expect(plan!.fromVersion, 9);
    expect(plan.toVersion, Tables.version);
    expect(plan.dbPath, dbPath);

    final backup = await MigrationGuard.instance.backup(plan);
    expect(p.dirname(backup.backupPath), p.join(dataDir, 'backup'));
    expect(p.basename(backup.backupPath), startsWith('db-v9-'));
    expect(await File(backup.backupPath).exists(), isTrue);
    expect(backup.bytes, greaterThan(0));
    expect(await File(backup.backupPath).length(), backup.bytes);

    // 备份自己必须能开、版本对、行还在。
    final bdb = await databaseFactoryFfi.openDatabase(backup.backupPath);
    try {
      expect(await bdb.rawQuery('PRAGMA user_version'), hasLength(1));
      expect((await bdb.query('media')).single['path'], '/m/keep.jpg');
    } finally {
      await bdb.close();
    }
    expect(await versionOf(backup.backupPath), 9);

    // 备份阶段不许动原库。
    expect(await versionOf(dbPath), 9);
  });

  test('确认后数据库才升到当前版本，原数据被清空但备份还在', () async {
    await seedVersion(9);
    final plan = await MigrationGuard.instance.inspect();
    final backup = await MigrationGuard.instance.backup(plan!);

    await DatabaseManager.instance.init();

    expect(await versionOf(dbPath), Tables.version);
    expect(await DatabaseManager.instance.db.query('media'), isEmpty);
    expect(await File(backup.backupPath).exists(), isTrue);
    expect(await versionOf(backup.backupPath), 9);
    // 升级完再检查就是最新版，不会反复弹窗。
    expect(await MigrationGuard.instance.inspect(), isNull);
  });

  test('超过上限时只留最近的备份', () async {
    await seedVersion(9);
    final dir = Directory(p.join(dataDir, 'backup'));
    await dir.create(recursive: true);

    // 造 10 份更早的备份，再加本轮 1 份，共 11 份。
    for (var i = 0; i < MigrationGuard.keepBackups; i++) {
      await File(p.join(dir.path, 'db-v9-20200101-0000${i.toString().padLeft(2, '0')}-000.db'))
          .writeAsBytes([i]);
    }

    final plan = await MigrationGuard.instance.inspect();
    final backup = await MigrationGuard.instance.backup(plan!);
    final names = dir
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toList()
      ..sort();

    expect(names, hasLength(MigrationGuard.keepBackups));
    expect(names, contains(p.basename(backup.backupPath)));
    expect(names, isNot(contains('db-v9-20200101-000000-000.db')));
  });

  test('备份列表按时间倒序，只收 db-v 开头的文件', () async {
    final dir = Directory(p.join(dataDir, 'backup'));
    await dir.create(recursive: true);
    final older = File(p.join(dir.path, 'db-v9-20200101-000000-000.db'));
    await older.writeAsBytes([1]);
    await older.setLastModified(DateTime(2020, 1, 1));
    final newer = File(p.join(dir.path, 'db-v10-20250101-000000-000.db'));
    await newer.writeAsBytes([1, 2, 3]);
    await newer.setLastModified(DateTime(2025, 1, 1));
    await File(p.join(dir.path, 'notes.txt')).writeAsString('ignore');

    final entries = await MigrationGuard.instance.listBackups();

    expect(entries.map((e) => e.version), [10, 9]);
    expect(entries.first.name, 'db-v10-20250101-000000-000.db');
    expect(entries.first.bytes, 3);
  });

  test('还原备份会替换当前库并清掉旧 WAL', () async {
    await seedVersion(9);
    final plan = await MigrationGuard.instance.inspect();
    final backup = await MigrationGuard.instance.backup(plan!);

    // 模拟升级前留下的旧 WAL 与共享内存文件，还原时必须清掉。
    await File('$dbPath-wal').writeAsBytes([9, 9]);
    await File('$dbPath-shm').writeAsBytes([8, 8]);
    await File(dbPath).writeAsString('broken');

    final version = await MigrationGuard.instance.restore(backup.backupPath);

    expect(version, 9);
    expect(await File(dbPath).length(), backup.bytes);
    expect(await File('$dbPath-wal').exists(), isFalse);
    expect(await File('$dbPath-shm').exists(), isFalse);

    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      expect((await db.query('media')).single['path'], '/m/keep.jpg');
    } finally {
      await db.close();
    }
    expect(await versionOf(dbPath), 9);
  });

  test('备份文件不存在时还原报错，不动当前库', () async {
    await seedVersion(9);
    final before = await File(dbPath).length();

    await expectLater(
      MigrationGuard.instance.restore(p.join(dataDir, 'backup', 'missing.db')),
      throwsA(isA<StateError>()),
    );

    expect(await File(dbPath).length(), before);
    expect(await versionOf(dbPath), 9);
  });
}
