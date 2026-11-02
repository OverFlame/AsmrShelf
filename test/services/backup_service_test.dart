import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/backup_service.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import '../support/test_env.dart';

/// 手动备份：导出一份可打开、内容完整的库；同秒多次导出不覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory dataDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_backup');
    dataDir = Directory(p.join(tmp.path, 'support'))..createSync();
    PathProviderPlatform.instance = FakePathProvider(dataDir.path);
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  test('导出后能打开备份，作品行都在', () async {
    await WorkDao(DatabaseManager.instance.db).create('作品A');
    final target = Directory(p.join(tmp.path, '备份'))..createSync();

    final result = await BackupService().export(target.path);
    expect(await File(result.path).exists(), isTrue);
    expect(result.bytes, greaterThan(0));
    expect(p.basename(result.path), startsWith('asmr_shelf-'));

    final copy = await openDatabase(result.path);
    final rows = await copy.query('works');
    await copy.close();
    expect(rows, hasLength(1));
    expect(rows.single['name'], '作品A');
  });

  test('连续导出两次得到两个文件，不覆盖', () async {
    final target = Directory(p.join(tmp.path, '备份'))..createSync();
    final service = BackupService();
    final a = await service.export(target.path);
    final b = await service.export(target.path);
    expect(a.path, isNot(b.path));
    expect(await File(a.path).exists(), isTrue);
    expect(await File(b.path).exists(), isTrue);
  });

  test('目标目录不存在时自动创建', () async {
    final target = p.join(tmp.path, '还没建的', '子目录');
    final result = await BackupService().export(target);
    expect(await File(result.path).exists(), isTrue);
  });
}
