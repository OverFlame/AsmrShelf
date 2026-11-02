import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/work_metadata_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/dlsite/dlsite_api.dart';
import 'package:asmrshelf/services/dlsite/dlsite_rate_limiter.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

const String body = '''
[{"workno":"RJ294126","work_name":"远程标题","intro_s":"简介",
  "genres":[{"name":"ASMR","id":497}],
  "creaters":{"voice_by":[{"id":1,"name":"声优"}]}}]
''';

class StubTransport implements DlsiteTransport {
  StubTransport(this.response);
  final Object response;
  int calls = 0;

  @override
  Future<DlsiteResponse> get(Uri url) async {
    calls++;
    if (response is DlsiteException) throw response;
    return response as DlsiteResponse;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late StubTransport transport;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_dlsite_state');
    PathProviderPlatform.instance = FakePathProvider(p.join(tmp.path, 'sup'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    transport = StubTransport(const DlsiteResponse(200, body));
    state = AppState(
      player: PlayerController(),
      dlsiteApi: DlsiteApi(
        transport: transport,
        limiter: DlsiteRateLimiter(
            sleep: (d) async {}, now: () => DateTime(2026)),
        retry: const DlsiteRetryPolicy(baseDelay: Duration(milliseconds: 1)),
      ),
    );
    await state.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  test('从作品目录名取编号，抓到后写元数据与标签', () async {
    final dir = Directory(p.join(tmp.path, 'media', 'RJ294126 作品A'))
      ..createSync(recursive: true);
    File(p.join(dir.path, '01.mp3')).writeAsBytesSync(List<int>.filled(8, 0));
    final outcome = await state.importWorksFromRoot(p.join(tmp.path, 'media'));
    expect(outcome!.worksCreated, 1);

    final workId = state.works.single.id!;
    final result = await state.fetchDlsiteMetadata(workId);
    expect(result.ok, isTrue);
    expect(result.work!.title, '远程标题');
    expect(transport.calls, 1);

    final stored = await WorkMetadataDao(DatabaseManager.instance.db)
        .getByWork(workId);
    expect(stored!.rjCode, 'RJ294126');
    expect(stored.description, '简介');
  });

  test('目录名没有编号也没有旧记录时给出可读提示，不发请求', () async {
    final dir = Directory(p.join(tmp.path, 'media', '普通作品'))
      ..createSync(recursive: true);
    File(p.join(dir.path, '01.mp3')).writeAsBytesSync(List<int>.filled(8, 0));
    await state.importWorksFromRoot(p.join(tmp.path, 'media'));

    final result = await state.fetchDlsiteMetadata(state.works.single.id!);
    expect(result.ok, isFalse);
    expect(result.message, contains('没有 RJ 号'));
    expect(transport.calls, 0);
  });

  test('二次抓取命中缓存，不再发请求', () async {
    final dir = Directory(p.join(tmp.path, 'media', 'RJ294126 作品A'))
      ..createSync(recursive: true);
    File(p.join(dir.path, '01.mp3')).writeAsBytesSync(List<int>.filled(8, 0));
    await state.importWorksFromRoot(p.join(tmp.path, 'media'));
    final workId = state.works.single.id!;

    await state.fetchDlsiteMetadata(workId);
    final second = await state.fetchDlsiteMetadata(workId);
    expect(second.fromCache, isTrue);
    expect(transport.calls, 1);
  });
}
