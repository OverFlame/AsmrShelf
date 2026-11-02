import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/media_bridge.dart';
import 'package:asmrshelf/widgets/scan_access_snack.dart';

/// 导入前的「所有文件访问」核对：Android 没授权时提示用户去系统设置。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final bridge = MediaBridge.instance;

  tearDown(() {
    bridge.resetForTest();
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(MediaBridge.channel, null);
  });

  void mockChannel({required bool granted}) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MediaBridge.channel,
      (call) async => call.method == 'checkAllFilesAccess' ? granted : null,
    );
  }

  /// 点一下按钮，等权限检查跑完，返回助手的结果
  Future<bool?> tapImport(WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await ensureScanAccessOrPrompt(context);
            },
            child: const Text('导入'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('导入'));
    for (var i = 0; i < 10 && result == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // 提示是在返回值之前挂上去的，还要一帧才会出现在树上
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return result;
  }

  testWidgets('Android 没授权：弹提示并返回 false', (tester) async {
    bridge.forceAndroid = true;
    mockChannel(granted: false);

    expect(await tapImport(tester), isFalse);
    expect(find.text('请在系统设置中授予「所有文件访问」权限后重试'), findsOneWidget);
  });

  testWidgets('Android 已授权：不弹提示并返回 true', (tester) async {
    bridge.forceAndroid = true;
    mockChannel(granted: true);

    expect(await tapImport(tester), isTrue);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('桌面端：不弹提示也不看授权状态', (tester) async {
    bridge.forceAndroid = false;
    mockChannel(granted: false);

    expect(await tapImport(tester), isTrue);
    expect(find.byType(SnackBar), findsNothing);
  });
}
