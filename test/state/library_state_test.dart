import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/dlsite/series_index.dart';
import 'package:asmrshelf/state/library_state.dart';
import 'package:asmrshelf/state/tag_filter.dart';
import '../support/test_env.dart';

/// 作品库状态自己的逻辑：导航状态、选中收窄、代际丢弃、版本号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late LibraryState state;
  var notified = 0;

  LibraryState build() => LibraryState(
    trackDao: () => TrackDao(DatabaseManager.instance.db),
    workDao: () => WorkDao(DatabaseManager.instance.db),
    folderDao: () => FolderDao(DatabaseManager.instance.db),
    mediaDao: () => MediaDao(DatabaseManager.instance.db),
    tagDao: () => TagDao(DatabaseManager.instance.db),
    hasAdvancedFilter: () => false,
    tagFilter: () => const TagFilter(),
    matchingIds: (_) async => <int>{},
    filterFolders: (folders, _) async => folders,
    sortTracks: (tracks) => tracks,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_library_state');
    PathProviderPlatform.instance = FakePathProvider(
      p.join(tmp.path, 'support'),
    );
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    state = build()..addListener(() => notified++);
    notified = 0;
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  test('refresh 把作品集读进来', () async {
    await WorkDao(DatabaseManager.instance.db).create('作品A');
    await state.refresh();
    expect(state.works.map((w) => w.name), ['作品A']);
    expect(state.loading, isFalse);
    expect(notified, greaterThan(0));
  });

  test('resetToHome 清掉作品与文件夹状态', () async {
    final db = DatabaseManager.instance.db;
    final work = await WorkDao(db).create('作品A');
    state.showWork(work);
    state.breadcrumb = const [];
    state.resetToHome();
    expect(state.currentWork, isNull);
    expect(state.currentFolderId, isNull);
    expect(state.breadcrumb, isEmpty);
  });

  test('showWork 把面包屑首项换成全部作品加作品名', () async {
    final work = await WorkDao(DatabaseManager.instance.db).create('作品A');
    state.showWork(work);
    expect(state.breadcrumb, hasLength(2));
    expect(state.breadcrumb.first.id, -2);
    expect(state.breadcrumb.last.name, '作品A');
  });

  test('showSeries 清掉作品状态，面包屑是全部作品加系列', () {
    final series = DlsiteSeries(
      key: 'id:100',
      id: '100',
      name: '雨の日',
      total: 3,
      workIds: const [1, 2],
    );
    state.currentWork = Work(
      id: 1,
      name: '旧作品',
      library: 'audio',
      sortOrder: 0,
      createdAt: 0,
    );
    state.showSeries(series);
    expect(state.currentSeries?.key, 'id:100');
    expect(state.currentWork, isNull);
    expect(state.breadcrumb.map((c) => c.id), [-2, -3]);
    expect(state.breadcrumb.last.name, '雨の日');
  });

  test('从系列进作品时面包屑保留系列节点', () async {
    final work = await WorkDao(DatabaseManager.instance.db).create('作品A');
    final series = DlsiteSeries(
      key: 'id:100',
      id: '100',
      name: '雨の日',
      workIds: [work.id!],
    );
    state.showWork(work, series: series);
    expect(state.breadcrumb.map((c) => c.id), [-2, -3, -1]);
    expect(state.currentSeries, isNotNull);
  });

  test('系列页全选只选系列成员，不把散作品带上', () async {
    final db = DatabaseManager.instance.db;
    final a = await WorkDao(db).create('系列A');
    final b = await WorkDao(db).create('系列B');
    final loose = await WorkDao(db).create('散作品');
    await state.refresh();
    final series = DlsiteSeries(
      key: 'id:100',
      id: '100',
      name: '雨の日',
      workIds: [a.id!, b.id!],
    );
    state.showSeries(series);
    state.selectAllWorks();
    expect(state.selectedWorkIds, {a.id, b.id});
    expect(state.selectedWorkIds, isNot(contains(loose.id)));
  });

  test('切上下文后选中集合只保留可见曲目', () async {
    final db = DatabaseManager.instance.db;
    final work = await WorkDao(db).create('作品A');
    final folder = await FolderDao(db).create('卷一', workId: work.id);
    await FolderDao(db).addPath(folder.id!, p.join(tmp.path, 'media', 'v1'));
    final dir = Directory(p.join(tmp.path, 'media', 'v1'))
      ..createSync(recursive: true);
    File(p.join(dir.path, '01.mp3')).writeAsBytesSync(List<int>.filled(8, 0));
    await TrackDao(db).insert(
      TrackItem(
        path: p.join(dir.path, '01.mp3'),
        filename: '01.mp3',
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    state.showWork(work);
    await state.refresh();
    state.showFolder(folder, path: dir.path);
    await state.refresh();
    final trackId = state.tracks.single.id!;
    state.toggleSelect(trackId);

    // 回到作品层，曲目不在中间栏了，选中要被收窄掉。
    state.showWork(work);
    await state.refresh();
    expect(state.selectedTrackIds, isEmpty);
    expect(state.selectionMode, isFalse);
  });

  test('bumpFolderVersion 递增并通知', () {
    final before = state.folderVersion;
    state.bumpFolderVersion();
    expect(state.folderVersion, before + 1);
    expect(notified, greaterThan(0));
  });

  test('搜索结果只留命中的曲目', () async {
    final db = DatabaseManager.instance.db;
    final work = await WorkDao(db).create('作品A');
    final folder = await FolderDao(db).create('卷一', workId: work.id);
    await FolderDao(db).addPath(folder.id!, p.join(tmp.path, 'media', 'v1'));
    final dir = Directory(p.join(tmp.path, 'media', 'v1'))
      ..createSync(recursive: true);
    for (final name in ['睡眠導入.mp3', '杂谈.mp3']) {
      File(p.join(dir.path, name)).writeAsBytesSync(List<int>.filled(8, 0));
      await TrackDao(db).insert(
        TrackItem(
          path: p.join(dir.path, name),
          filename: name,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    state.showWork(work);
    await state.refresh();
    state.applySearch('睡眠');
    await state.refresh();
    expect(state.tracks.map((t) => t.filename), ['睡眠導入.mp3']);
  });

  test('作品多选：进入、切换、全选与清空', () async {
    final db = DatabaseManager.instance.db;
    final a = await WorkDao(db).create('作品A');
    final b = await WorkDao(db).create('作品B');
    await state.refresh();

    state.enterWorkSelectionMode();
    state.toggleWorkSelect(a.id!);
    state.toggleWorkSelect(b.id!);
    expect(state.workSelectionMode, isTrue);
    expect(state.selectedWorkIds, {a.id, b.id});

    state.toggleWorkSelect(a.id!);
    expect(state.selectedWorkIds, {b.id});

    state.selectAllWorks();
    expect(state.selectedWorkIds, {a.id, b.id});
    expect(state.isWorkSelected(a.id!), isTrue);

    state.clearWorkSelection();
    expect(state.workSelectionMode, isFalse);
    expect(state.selectedWorkIds, isEmpty);
  });

  test('refresh 把已删除的作品从选中集合里去掉', () async {
    final db = DatabaseManager.instance.db;
    final a = await WorkDao(db).create('作品A');
    final b = await WorkDao(db).create('作品B');
    await state.refresh();
    state.enterWorkSelectionMode();
    state.toggleWorkSelect(a.id!);
    state.toggleWorkSelect(b.id!);

    await WorkDao(db).delete(b.id!);
    await state.refresh();
    expect(state.selectedWorkIds, {a.id});
  });
}
