import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/db/work_metadata_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/dlsite/dlsite_api.dart';
import 'package:asmrshelf/services/dlsite/dlsite_cover.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

const String productBody = '''
[{
  "workno": "RJ294126",
  "work_name": "远程标题",
  "intro_s": "远程简介",
  "maker_name": "社团A",
  "series_name": "系列B",
  "regist_date": "2024-05-01 00:00:00",
  "rate_average_star": 48,
  "rate_count": 12,
  "image_main": {"url": "//img.dlsite.jp/main.jpg", "width": 560, "height": 420},
  "image_samples": [],
  "genres": [{"name": "ASMR", "id": 497}],
  "creaters": {"voice_by": [{"id": 1, "name": "逢坂成美"}]}
}]
''';

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

List<int> _png() => [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      ...List<int>.filled(8, 0),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory mediaRoot;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_dlsite_state');
    mediaRoot = Directory(p.join(tmp.path, 'media'));
    final workDir = Directory(p.join(mediaRoot.path, 'RJ294126 作品A'))
      ..createSync(recursive: true);
    File(p.join(workDir.path, '01.mp3'))
        .writeAsBytesSync(List<int>.filled(8, 0));
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    state = AppState(player: PlayerController());
    await state.init();
    await state.importWorksFromRoot(mediaRoot.path);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  test('从目录名认出编号，预览只落缓存不改封面', () async {
    final workId = state.works.single.id!;
    final transport = FakeTransport([DlsiteResponse(200, productBody)]);
    state = AppState(
      player: PlayerController(),
      dlsiteApi: DlsiteApi(transport: transport),
    );
    await state.init();
    await state.enterWork(workId);

    final preview = await state.previewDlsiteMetadata(workId);
    expect(preview.ok, isTrue);
    expect(preview.work!.workNo, 'RJ294126');
    expect(transport.calls.single.toString(), contains('workno=RJ294126'));

    // 预览不挂标签：ASMR 还没进库。
    expect(state.tags.allTags.where((t) => t.name == 'ASMR'), isEmpty);

    final meta = await WorkMetadataDao(DatabaseManager.instance.db)
        .getByWork(workId);
    expect(meta!.circle, '社团A');
    expect(meta.coverSource, isNull);

    // 缓存里的完整信息能反解出发售日与评分。
    final full = await state.cachedDlsiteWork(workId);
    expect(full!.releaseDate, '2024-05-01 00:00:00');
    expect(full.stars, 4.8);
  });

  test('应用预览后挂上分类与声优标签，7 天内再抓走缓存', () async {
    final workId = state.works.single.id!;
    final transport = FakeTransport([DlsiteResponse(200, productBody)]);
    state = AppState(
      player: PlayerController(),
      dlsiteApi: DlsiteApi(transport: transport),
    );
    await state.init();

    final preview = await state.previewDlsiteMetadata(workId);
    final applied = await state.applyDlsiteMetadata(workId, preview.work!);
    expect(applied.grantedTags, 2);

    await state.refresh();
    await state.loadTags();
    final names = state.tags.allTags.map((t) => '${t.namespace}:${t.name}');
    expect(names, containsAll(['dlsite:ASMR', 'voice:逢坂成美']));

    final again = await state.previewDlsiteMetadata(workId);
    expect(again.fromCache, isTrue);
    expect(transport.calls, hasLength(1));
  });

  test('下载远程封面写进缓存目录并记到 works.cover_path', () async {
    final workId = state.works.single.id!;
    final transport = FakeTransport([DlsiteResponse(200, productBody)]);
    state = AppState(
      player: PlayerController(),
      dlsiteApi: DlsiteApi(transport: transport),
      dlsiteCoverDownloader: DlsiteCoverDownloader(
        fetch: (_) async => DlsiteImage(bytes: Uint8List.fromList(_png())),
      ),
    );
    await state.init();

    final preview = await state.previewDlsiteMetadata(workId);
    final url = preview.work!.cover!.url;
    final path = await state.downloadDlsiteCover(workId, url);

    expect(File(path).existsSync(), isTrue);
    expect(p.basename(path), 'work_$workId.png');
    final work = await WorkDao(DatabaseManager.instance.db).getById(workId);
    expect(work!.coverPath, path);
  });

  test('目录名没有编号时直接给提示，不发请求', () async {
    final other = Directory(p.join(mediaRoot.path, '无编号作品'))
      ..createSync(recursive: true);
    File(p.join(other.path, 'a.mp3')).writeAsBytesSync(List<int>.filled(8, 0));
    await state.importWorksFromRoot(mediaRoot.path, nested: false);
    final workId =
        state.works.firstWhere((w) => w.name == '无编号作品').id!;

    final transport = FakeTransport([]);
    state = AppState(
      player: PlayerController(),
      dlsiteApi: DlsiteApi(transport: transport),
    );
    await state.init();
    final result = await state.previewDlsiteMetadata(workId);
    expect(result.ok, isFalse);
    expect(result.message, contains('RJ'));
    expect(transport.calls, isEmpty);
  });
}
