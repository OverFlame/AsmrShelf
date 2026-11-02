/// 一次性导入工具：把一个整理好的目录树写进 AsmrShelf 的库。
///
/// 用法（在仓库根目录）：
///
/// ```text
/// dart run tool/import_cli.dart --root "D:/ASMR" --db "D:/AsmrShelf/asmr_shelf.db"
/// dart run tool/import_cli.dart --root "D:/ASMR" --db ... --nested --dry-run
/// ```
///
/// 只写库与作品目录里的封面文件，不移动、不删除任何音频。库文件必须是应用
/// 建好的（schema v1）；这里不会创建目录也不改数据目录指针，路径交给用户给。
library;

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:asmrshelf/db/tables.dart';
import 'package:asmrshelf/services/import_scanner.dart';
import 'package:asmrshelf/services/plan_importer.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options == null) {
    stdout.writeln(_usage);
    exitCode = 64;
    return;
  }

  final root = Directory(options.root);
  if (!root.existsSync()) {
    stderr.writeln('目录不存在：${options.root}');
    exitCode = 66;
    return;
  }

  stdout.writeln('扫描 ${options.root} ...');
  final plan = await scanImportTree(
    options.root,
    nested: options.nested,
    writeCover: !options.dryRun,
  );
  stdout.writeln('${plan.works.length} 部作品，${plan.trackCount} 首曲目');
  for (final work in plan.works) {
    final code = work.code == null ? '' : ' [${work.code}]';
    final cover = switch (work.coverLevel) {
      6 => '无封面',
      final level => '封面 L$level',
    };
    stdout.writeln('  ${work.title}$code  ${work.trackCount} 首  $cover');
  }
  if ((plan.skipped ?? const []).isNotEmpty) {
    stdout.writeln('跳过 ${plan.skipped!.length} 个没有音频的目录');
    for (final dir in plan.skipped!) {
      stdout.writeln('  $dir');
    }
  }

  if (options.dryRun) {
    stdout.writeln('--dry-run：只扫描，不写库。');
    return;
  }

  final dbFile = File(options.db);
  if (!dbFile.existsSync()) {
    stderr.writeln('库文件不存在：${options.db}');
    stderr.writeln('先启动一次应用让它建库，再把这里的 --db 指过去。');
    exitCode = 66;
    return;
  }

  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    options.db,
    options: OpenDatabaseOptions(
      singleInstance: true,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  try {
    final version = await db.getVersion();
    if (version != Tables.version) {
      stderr.writeln('库版本是 v$version，应用要求 v${Tables.version}，拒绝写入。');
      exitCode = 65;
      return;
    }
    final outcome = await PlanImporter(db).apply(plan);
    stdout.writeln('$outcome');
  } finally {
    await db.close();
  }
}

class _Options {
  const _Options({
    required this.root,
    required this.db,
    this.nested = false,
    this.dryRun = false,
  });

  final String root;
  final String db;
  final bool nested;
  final bool dryRun;
}

_Options? _parseArgs(List<String> args) {
  String? root;
  String? db;
  var nested = false;
  var dryRun = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--root':
        if (i + 1 >= args.length) return null;
        root = args[++i];
      case '--db':
        if (i + 1 >= args.length) return null;
        db = args[++i];
      case '--nested':
        nested = true;
      case '--dry-run':
        dryRun = true;
      case '-h':
      case '--help':
        return null;
      default:
        return null;
    }
  }
  if (root == null) return null;
  return _Options(
    root: root,
    db: db ?? '',
    nested: nested,
    dryRun: dryRun,
  );
}

const String _usage = '''
一次性导入工具

  dart run tool/import_cli.dart --root <目录> [--db <库文件>] [--nested] [--dry-run]

  --root      要导入的目录，里面的每个子目录算一部作品
  --db        应用的库文件，未指定时只扫描
  --nested    允许「社团/作品」两层
  --dry-run   只扫描并打印计划，不写库也不写封面
''';
