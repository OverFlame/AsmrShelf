/// 手动备份：把当前的库完整复制到用户选的目录。
///
/// 只做「一份一致的快照」，不碰封面缓存与设置；恢复靠把备份文件放回数据目录
/// 再启动（应用会在还原页提示）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../db/database.dart';
import 'data_dir_service.dart';

class BackupResult {
  const BackupResult({required this.path, required this.bytes});

  final String path;
  final int bytes;
}

class BackupService {
  /// [db] 与 [dataDir] 只给测试注入，正常路径用全局实例。
  BackupService({this.db, this.dataDir});

  /// 只给测试注入；为 null 时用 [DatabaseManager.instance.db]。
  final Database? db;

  /// 只给测试注入；为 null 时用数据目录设置。
  final String? dataDir;

  /// 导出到 [targetDir]，文件名带时间戳，绝不覆盖已有备份。
  Future<BackupResult> export(String targetDir) async {
    final conn = db ?? DatabaseManager.instance.db;
    // 先把 WAL 落进主库，避免只复制到一部分日志。
    await conn.execute('PRAGMA wal_checkpoint(FULL)');

    final baseDir = dataDir ?? await DataDirService.instance.dataDir;
    final source = File(p.join(baseDir, 'asmr_shelf.db'));
    if (!await source.exists()) {
      throw FileSystemException('数据库文件不存在', source.path);
    }

    final dir = Directory(targetDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final stamp = _stamp(DateTime.now());
    var target = File(p.join(dir.path, 'asmr_shelf-$stamp.db'));
    var n = 1;
    while (await target.exists()) {
      target = File(p.join(dir.path, 'asmr_shelf-$stamp-$n.db'));
      n++;
    }
    await source.copy(target.path);
    return BackupResult(path: target.path, bytes: await target.length());
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
