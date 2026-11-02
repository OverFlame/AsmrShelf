import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';


/// 阅读进度服务的生命周期：换库实例与关库前都要落盘。
///
/// 服务自己带节流窗口（默认一秒），攒着的进度只在 flush / dispose 时写库，
/// 所以「谁来 dispose」决定了最后一页会不会丢。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_reading');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    state = AppState(player: PlayerController());
    await state.init();
  });

  tearDown(() async {
    await state.disposeReadingService();
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// 阅读进度挂在卷上（= folders 行），外键开着，得先有这条。
  Future<int> addVolume() => DatabaseManager.instance.db.insert(
        'folders',
        <String, Object?>{'name': 'vol', 'library': 'media'},
      );

  test('换库实例后旧服务被 dispose，再用它会抛 StateError', () async {
    final volume = await addVolume();
    final first = state.readingService;
    await first.record(volume, pageIndex: 3);

    // 关库再开：DatabaseManager 给的是新的 db 实例
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();

    final second = state.readingService;
    expect(identical(first, second), isFalse,
        reason: '换了库实例就该换服务实例');
    await expectLater(
      first.record(volume, pageIndex: 4),
      throwsStateError,
      reason: '旧服务要连同攒着的进度一起收掉，不能再让它写',
    );
  });

  test('关库前 disposeReadingService 会把攒着的进度写进库', () async {
    final volume = await addVolume();
    await state.readingService.record(volume, pageIndex: 5);

    // 节流窗口内直接关库，这一页就丢了；先落盘再关
    await state.disposeReadingService();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();

    final saved = await state.readingService.get(volume);
    expect(saved?.pageIndex, 5);
  });
}
