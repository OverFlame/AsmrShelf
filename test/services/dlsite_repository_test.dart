import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:asmrshelf/db/tables.dart';
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/db/work_metadata_dao.dart';
import 'package:asmrshelf/services/dlsite/dlsite_api.dart';
import 'package:asmrshelf/services/dlsite/dlsite_models.dart';
import 'package:asmrshelf/services/dlsite/dlsite_rate_limiter.dart';
import 'package:asmrshelf/services/dlsite/dlsite_repository.dart';

const String productBody = '''
[{
  "workno": "RJ294126",
  "work_name": "远程标题",
  "intro_s": "远程简介",
  "maker_name": "社团",
  "series_name": "系列",
  "rate_average_star": 48,
  "image_main": {"url": "//img.dlsite.jp/main.jpg", "width": 560, "height": 420},
  "genres": [{"name": "ASMR", "id": 497}, {"name": "癒し", "id": "056"}],
  "creaters": {"voice_by": [{"id": 1, "name": "逢坂成美"}]}
}]
''';

/// 假传输层：按队列吐响应，同时记录请求地址。
class FakeTransport implements DlsiteTransport {
  FakeTransport(this.queue);

  final List<Object> queue;
  final List<Uri> calls = [];

  @override
  Future<DlsiteResponse> get(Uri url) async {
    calls.add(url);
    final next = queue.removeAt(0);
    if (next is DlsiteException) throw next;
    return next as DlsiteResponse;
  }
}

void main() {
  sqfliteFfiInit();

  late Database db;
  late Directory dbDir;
  late int workId;

  setUp(() async {
    dbDir = await Directory.systemTemp.createTemp('asmrshelf_dlsite_');
    db = await databaseFactoryFfi.openDatabase(
      p.join(dbDir.path, 'test.db'),
      options: OpenDatabaseOptions(
        version: Tables.version,
        onCreate: (db, v) async {
          for (final s in Tables.createStatements) {
            await db.execute(s);
          }
        },
      ),
    );
    final work = await WorkDao(db).create('本地作品名', library: 'audio');
    workId = work.id!;
  });

  tearDown(() async {
    await db.close();
    await dbDir.delete(recursive: true);
  });

  DlsiteRepository repoWith(FakeTransport transport, {DateTime? now}) =>
      DlsiteRepository(
        db,
        api: DlsiteApi(
          transport: transport,
          limiter: DlsiteRateLimiter(
            sleep: (d) async {},
            now: () => DateTime(2026, 1, 1),
          ),
          retry: const DlsiteRetryPolicy(
              maxAttempts: 3, baseDelay: Duration(milliseconds: 1)),
        ),
        now: () => now ?? DateTime(2026, 1, 1, 12),
      );

  test('抓到元数据后写库：远程标题进 metadata，本地作品名不动', () async {
    final transport = FakeTransport([
      const DlsiteResponse(200, productBody),
    ]);
    final result = await repoWith(transport).fetchForWork(workId, 'rj294126');

    expect(result.ok, isTrue);
    expect(result.work!.title, '远程标题');
    expect(transport.calls.single.queryParameters['workno'], 'RJ294126');

    final stored = await WorkMetadataDao(db).getByWork(workId);
    expect(stored!.rjCode, 'RJ294126');
    expect(stored.title, '远程标题');
    expect(stored.circle, '社团');
    expect(stored.description, '远程简介');
    expect(stored.rawJson, productBody);
    expect(stored.fetchedAt, isNotNull);

    final work = await WorkDao(db).getById(workId);
    expect(work!.name, '本地作品名');
  });

  test('分类与声优分别挂到 dlsite 与 voice 命名空间', () async {
    final transport = FakeTransport([
      const DlsiteResponse(200, productBody),
    ]);
    final result = await repoWith(transport).fetchForWork(workId, 'RJ294126');
    expect(result.grantedTags, 3);

    final tags = await TagDao(db).tagsForWork(workId);
    expect([for (final t in tags) '${t.namespace}:${t.name}'],
        ['dlsite:ASMR', 'dlsite:癒し', 'voice:逢坂成美']);
  });

  test('重复抓同一部作品不会重复挂标签', () async {
    final transport = FakeTransport([
      const DlsiteResponse(200, productBody),
      const DlsiteResponse(200, productBody),
    ]);
    final repo = repoWith(transport);
    await repo.fetchForWork(workId, 'RJ294126');
    final again = await repo.fetchForWork(workId, 'RJ294126');
    expect(again.grantedTags, 0);
    expect((await TagDao(db).tagsForWork(workId)).length, 3);
  });

  test('7 天缓存内不再发请求', () async {
    final transport = FakeTransport([
      const DlsiteResponse(200, productBody),
    ]);
    final repo = repoWith(transport);
    await repo.fetchForWork(workId, 'RJ294126');
    final second = await repo.fetchForWork(workId, 'RJ294126');
    expect(second.fromCache, isTrue);
    expect(second.work!.title, '远程标题');
    expect(transport.calls.length, 1);
  });

  test('过了 7 天会重新抓', () async {
    final transport = FakeTransport([
      const DlsiteResponse(200, productBody),
      const DlsiteResponse(200, productBody),
    ]);
    var now = DateTime(2026, 1, 1, 12);
    final repo = DlsiteRepository(
      db,
      api: DlsiteApi(
        transport: transport,
        limiter: DlsiteRateLimiter(
            sleep: (d) async {}, now: () => DateTime(2026, 1, 1)),
        retry: const DlsiteRetryPolicy(baseDelay: Duration(milliseconds: 1)),
      ),
      now: () => now,
    );
    await repo.fetchForWork(workId, 'RJ294126');
    now = now.add(const Duration(days: 8));
    final second = await repo.fetchForWork(workId, 'RJ294126');
    expect(second.fromCache, isFalse);
    expect(transport.calls.length, 2);
  });

  test('403 不重试，返回可读提示', () async {
    final transport = FakeTransport([
      const DlsiteResponse(403, 'forbidden'),
    ]);
    final result = await repoWith(transport).fetchForWork(workId, 'RJ294126');
    expect(result.ok, isFalse);
    expect(result.message, contains('403'));
    expect(transport.calls.length, 1);
    expect(await WorkMetadataDao(db).getByWork(workId), isNull);
  });

  test('503 退避重试后成功', () async {
    final transport = FakeTransport([
      const DlsiteResponse(503, 'busy'),
      const DlsiteResponse(200, productBody),
    ]);
    final result = await repoWith(transport).fetchForWork(workId, 'RJ294126');
    expect(result.ok, isTrue);
    expect(transport.calls.length, 2);
  });

  test('接口返回空数组时提示没有这部作品', () async {
    final transport = FakeTransport([
      const DlsiteResponse(200, '[]'),
    ]);
    final result = await repoWith(transport).fetchForWork(workId, 'RJ999999');
    expect(result.ok, isFalse);
    expect(result.message, contains('空数据'));
  });

  test('联网失败返回提示而不是抛异常', () async {
    final transport = FakeTransport([
      const DlsiteException(message: '连不上 DLsite：timeout'),
    ]);
    final result = await repoWith(transport).fetchForWork(workId, 'RJ294126');
    expect(result.ok, isFalse);
    expect(result.message, contains('连不上'));
  });

  test('本地已有封面且未勾选时，不写远程封面地址', () async {
    final transport = FakeTransport([
      const DlsiteResponse(200, productBody),
    ]);
    await repoWith(transport).fetchForWork(workId, 'RJ294126');
    final stored = await WorkMetadataDao(db).getByWork(workId);
    expect(stored!.coverSource, isNull);
    expect(stored.coverFetchedAt, isNull);

    final transport2 = FakeTransport([
      const DlsiteResponse(200, productBody),
    ]);
    await DlsiteRepository(
      db,
      api: DlsiteApi(
        transport: transport2,
        limiter: DlsiteRateLimiter(
            sleep: (d) async {}, now: () => DateTime(2026, 1, 1)),
        retry: const DlsiteRetryPolicy(baseDelay: Duration(milliseconds: 1)),
      ),
      now: () => DateTime(2026, 2, 1),
    ).fetchForWork(workId, 'RJ294126', applyCover: true);

    final updated = await WorkMetadataDao(db).getByWork(workId);
    expect(updated!.coverSource, 'dlsite');
    expect(updated.coverFetchedAt, isNotNull);
    expect(updated.coverUrl, 'https://img.dlsite.jp/main.jpg');
  });

  test('解析结果与模型口径一致：评分除 10', () async {
    final work = parseProductJson(productBody)!;
    expect(work.stars, 4.8);
  });
}
