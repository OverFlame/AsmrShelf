import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/migration_guard.dart';
import 'package:asmrshelf/widgets/startup_gate.dart';

void main() {
  const plan = MigrationPlan(
    fromVersion: 9,
    toVersion: 10,
    dbPath: '/data/asmr_shelf.db',
  );
  const backup = MigrationBackup(
    plan: plan,
    backupPath: '/data/backup/db-v9-20261031-120000-000.db',
    bytes: 4096,
  );
  final entries = <BackupEntry>[
    BackupEntry(
      path: '/data/backup/db-v9-20261031-120000-000.db',
      version: 9,
      bytes: 4096,
      modified: DateTime(2026, 10, 31, 12),
    ),
  ];

  testWidgets('确认页写明版本、后果与备份位置', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MigrationConfirmPage(
        backup: backup,
        backups: [],
        onRestore: _restore,
        onResult: _ignore,
      ),
    ));

    expect(find.text('需要重建媒体库'), findsOneWidget);
    expect(find.textContaining('v9 升级到 v10'), findsOneWidget);
    expect(find.textContaining('媒体条目、文件夹、标签、播放记录会清空'), findsOneWidget);
    expect(find.text('/data/backup/db-v9-20261031-120000-000.db'),
        findsOneWidget);
  });

  testWidgets('取消与重建各自回报结果', (tester) async {
    final results = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: MigrationConfirmPage(
        backup: backup,
        backups: [],
        onRestore: _restore,
        onResult: results.add,
      ),
    ));

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.tap(find.text('重建'));
    await tester.pump();

    expect(results, [false, true]);
  });

  testWidgets('取消页说明库未改动并保留备份路径', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MigrationCancelledPage(
        backup: backup,
        backups: [],
        onRestore: _restore,
        onRetry: _retry,
      ),
    ));

    expect(find.text('已取消重建'), findsOneWidget);
    expect(find.textContaining('媒体库未改动'), findsOneWidget);
    expect(find.text('/data/backup/db-v9-20261031-120000-000.db'),
        findsOneWidget);
  });

  testWidgets('取消页点重试会回调', (tester) async {
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
      home: MigrationCancelledPage(
        backup: backup,
        backups: entries,
        onRestore: _restore,
        onRetry: () => retried++,
      ),
    ));

    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('从确认页能进还原列表并完成还原', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MigrationConfirmPage(
        backup: backup,
        backups: entries,
        onRestore: (path) async {
          expect(path, entries.single.path);
          return 9;
        },
        onResult: _ignore,
      ),
    ));

    await tester.tap(find.text('从备份还原'));
    await tester.pumpAndSettle();
    expect(find.text('还原备份'), findsOneWidget);
    expect(find.text(entries.single.name), findsOneWidget);

    await tester.tap(find.text('还原'));
    await tester.pumpAndSettle();

    expect(find.text('已还原 v9 备份'), findsOneWidget);
  });

  testWidgets('没有备份时列表给出说明', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MigrationRestorePage(
        backups: const [],
        onRestore: _restore,
      ),
    ));

    expect(find.text('没有可用备份。'), findsOneWidget);
  });
}

Future<int> _restore(String path) async => 9;

void _retry() {}

void _ignore(bool _) {}
