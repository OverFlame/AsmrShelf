import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/dlsite/dlsite_models.dart';
import 'package:asmrshelf/services/dlsite/dlsite_repository.dart';
import 'package:asmrshelf/state/dlsite_state.dart';
import '../support/test_env.dart';

/// 批量抓取队列：顺序、计数、取消与去重。
///
/// 不联网：子类覆盖 [DlsiteState.fetch]，只记录调用。
class _QueueState extends DlsiteState {
  _QueueState(Database db)
      : super(db: () => db, workDao: () => WorkDao(db));

  final List<int> calls = [];
  int failFor = -1;

  /// 非空时，第一次 fetch 会等它完成再返回（用来测试取消）。
  Completer<void>? holdFirst;

  @override
  Future<DlsiteFetchResult> fetch(int workId, {bool applyCover = false}) async {
    calls.add(workId);
    if (calls.length == 1 && holdFirst != null) await holdFirst!.future;
    if (workId == failFor) {
      return const DlsiteFetchResult(message: '这部作品的目录名里没有 RJ 号');
    }
    return DlsiteFetchResult(
      work: DlsiteWork(
        workNo: 'RJ000000',
        title: '作品$workId',
        rawJson: '{}',
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_dlsite_queue');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// 等队列自己跑完。fetch 是同步返回的假实现，让几轮事件循环即可。
  Future<void> settle(bool Function() cond) async {
    for (var i = 0; i < 100 && !cond(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('按入队顺序逐部处理，记录成功与失败数', () async {
    final state = _QueueState(db)..failFor = 2;
    state.enqueueScrape([1, 2, 3]);
    expect(state.scrapeRunning, isTrue);
    expect(state.scrapeTotal, 3);

    await settle(() => !state.scrapeRunning);
    expect(state.calls, [1, 2, 3]);
    expect(state.scrapeDone, 3);
    expect(state.scrapeFailed, 1);
    expect(state.scrapeRunning, isFalse);
  });

  test('重复排入同一部只抓一次', () async {
    final state = _QueueState(db);
    state.enqueueScrape([1, 2]);
    state.enqueueScrape([2, 3]);
    await settle(() => !state.scrapeRunning);
    expect(state.calls, [1, 2, 3]);
    expect(state.scrapeTotal, 3);
  });

  test('取消后不再取新的作品，正在抓的那部照常完成', () async {
    final state = _QueueState(db);
    final hold = Completer<void>();
    state.holdFirst = hold;
    state.enqueueScrape([1, 2, 3]);
    await settle(() => state.calls.isNotEmpty);
    expect(state.calls, [1]);

    state.cancelScrapeQueue();
    hold.complete();
    await settle(() => !state.scrapeRunning);
    expect(state.calls, [1]);
    expect(state.scrapeRunning, isFalse);
    expect(state.scrapeDone, 1);
  });

  test('空入队不启动队列', () async {
    final state = _QueueState(db);
    state.enqueueScrape(const []);
    expect(state.scrapeRunning, isFalse);
    expect(state.calls, isEmpty);
  });
}
