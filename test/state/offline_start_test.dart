import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/dlsite/dlsite_api.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 没网也能启动：启动链路不碰 DLsite；坏库启动不会静默通过。
class _OfflineTransport implements DlsiteTransport {
  int calls = 0;

  @override
  Future<DlsiteResponse> get(Uri url) async {
    calls++;
    throw const SocketException('offline');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory dataDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService.instance.resetForTest();
    tmp = await Directory.systemTemp.createTemp('asmrshelf_offline');
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

  test('启动不联网：注入永远失败的传输层也能初始化', () async {
    final transport = _OfflineTransport();
    final state = AppState(
      player: PlayerController(),
      dlsiteApi: DlsiteApi(transport: transport),
    );
    await state.init();

    expect(transport.calls, 0, reason: '启动链路不该抓 DLsite');
    expect(state.works, isEmpty);
  });

  test('坏库启动会抛错，交给启动页处理，不静默成功', () async {
    final dbPath = DatabaseManager.instance.db.path;
    await DatabaseManager.instance.close();
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (await f.exists()) await f.delete();
    }
    File(dbPath).writeAsBytesSync(List<int>.filled(4096, 0x41));

    await expectLater(
      DatabaseManager.instance.init(),
      throwsA(anything),
      reason: '把坏文件当库打开必须失败',
    );
  });
}
