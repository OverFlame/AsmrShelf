import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/dlsite/dlsite_api.dart';
import 'package:asmrshelf/services/dlsite/dlsite_rate_limiter.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 导入后自动排刮削：开关打开才排队，队列用注入的传输层，不联网。
class _RecordingTransport implements DlsiteTransport {
  final List<Uri> calls = [];

  @override
  Future<DlsiteResponse> get(Uri url) async {
    calls.add(url);
    return const DlsiteResponse(404, '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late _RecordingTransport transport;
  late AppState state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService.instance.resetForTest();
    tmp = await Directory.systemTemp.createTemp('asmrshelf_auto_scrape');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    transport = _RecordingTransport();
    state = AppState(
      player: PlayerController(),
      dlsiteApi: DlsiteApi(
        transport: transport,
        limiter: DlsiteRateLimiter(
          minInterval: Duration.zero,
          sleep: (_) async {},
        ),
      ),
    );
    await state.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  test('开关关着时导入完不排队', () async {
    final root = Directory(p.join(tmp.path, '曲库'))..createSync();
    final work = Directory(p.join(root.path, 'RJ123456 作品A'))
      ..createSync(recursive: true);
    File(p.join(work.path, '01.mp3')).writeAsBytesSync(const [0, 1]);

    await state.importWorksFromRoot(root.path);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(state.dlsite.scrapeRunning, isFalse);
    expect(transport.calls, isEmpty);
  });

  test('开关打开后，新导入的作品排队抓一次', () async {
    final root = Directory(p.join(tmp.path, '曲库'))..createSync();
    final work = Directory(p.join(root.path, 'RJ123456 作品A'))
      ..createSync(recursive: true);
    File(p.join(work.path, '01.mp3')).writeAsBytesSync(const [0, 1]);
    await state.setAutoScrapeAfterImport(true);

    await state.importWorksFromRoot(root.path);
    for (var i = 0; i < 100 && state.dlsite.scrapeRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(transport.calls, isNotEmpty);
    expect(transport.calls.first.queryParameters['workno'], 'RJ123456');
    expect(state.dlsite.scrapeTotal, 1);
    expect(state.dlsite.scrapeDone, 1);
  });
}
