import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/services/media_bridge.dart';

/// 后台通知的发送顺序、去重与超时（报告第 26 项）。
///
/// 旧实现：`_startService()` 没有 await，而 `_updateNotification()` 自己在开头
/// 检查 `_serviceStarted`，所以首次通知必被丢掉；去重键又在发送之前就写上，
/// 丢掉的那次永远不会重试；平台通道调用也全部没有超时。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bridge = MediaBridge.instance;
  final calls = <String>[];
  bool handlerInstalled = false;

  TrackItem track(String path) =>
      TrackItem(path: path, filename: path, addedAt: 0);

  void mock(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MediaBridge.channel, handler);
    handlerInstalled = true;
  }

  setUp(() {
    calls.clear();
    bridge.resetForTest();
    bridge.forceAndroid = true;
  });

  tearDown(() {
    if (handlerInstalled) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MediaBridge.channel, null);
      handlerInstalled = false;
    }
    bridge.resetForTest();
  });

  test('首次通知等服务起来之后再发', () async {
    mock((call) async {
      if (call.method == 'startPlaybackService') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        calls.add('start');
      } else if (call.method == 'updateNotification') {
        calls.add('update');
      }
      return null;
    });

    await bridge.debugSync(track('/m/1.mp3'), playing: true);

    expect(calls, ['start', 'update'],
        reason: '服务没起来就发通知，原生侧收不到');
  });

  test('服务起不来时不记去重键，下次状态变化重试', () async {
    var startFailed = false;
    mock((call) async {
      if (call.method == 'startPlaybackService') {
        if (!startFailed) {
          startFailed = true;
          throw PlatformException(code: 'boom');
        }
        calls.add('start');
      } else if (call.method == 'updateNotification') {
        calls.add('update');
      }
      return null;
    });

    await bridge.debugSync(track('/m/1.mp3'), playing: true);
    expect(calls, isEmpty, reason: '服务没起来，这次通知发不出去');

    await bridge.debugSync(track('/m/1.mp3'), playing: true);
    expect(calls, ['start', 'update'], reason: '同一个状态也要补发');
  });

  test('状态没变时不重复调用原生', () async {
    mock((call) async {
      if (call.method == 'startPlaybackService') {
        calls.add('start');
      } else if (call.method == 'updateNotification') {
        calls.add('update');
      }
      return null;
    });

    final item = track('/m/1.mp3');
    await bridge.debugSync(item, playing: true);
    await bridge.debugSync(item, playing: true);

    expect(calls, ['start', 'update']);
  });

  test('同步期间来的连续状态变化合并成一次原生调用', () async {
    mock((call) async {
      if (call.method == 'startPlaybackService') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        calls.add('start');
      } else if (call.method == 'updateNotification') {
        calls.add('update');
      }
      return null;
    });

    final item = track('/m/1.mp3');
    final first = bridge.debugSync(item, playing: true);
    final second = bridge.debugSync(item, playing: false);
    final third = bridge.debugSync(item, playing: true);
    await Future.wait([first, second, third]);

    expect(calls.where((c) => c == 'update').length, 1,
        reason: '中间那次被最后一次覆盖，键又和第一次相同');
  });

  test('平台通道挂死时会超时，不会永远卡住同步', () async {
    bridge.callTimeout = const Duration(milliseconds: 50);
    var hanging = true;
    mock((call) async {
      if (call.method == 'startPlaybackService') {
        if (hanging) return Completer<Object?>().future;
        calls.add('start');
      } else if (call.method == 'updateNotification') {
        calls.add('update');
      }
      return null;
    });

    await bridge.debugSync(track('/m/1.mp3'));
    expect(calls, isEmpty, reason: '起服务超时，通知不该发');

    hanging = false;
    await bridge.debugSync(track('/m/1.mp3'));
    expect(calls, ['start', 'update']);
  });

  test('ensureScanAccess：没授权就跳设置页并返回 false', () async {
    final seen = <String>[];
    mock((call) async {
      seen.add(call.method);
      if (call.method == 'checkAllFilesAccess') return false;
      return null;
    });

    expect(await bridge.ensureScanAccess(), isFalse);
    expect(seen, [
      'checkAllFilesAccess',
      'requestAllFilesAccess',
      'checkAllFilesAccess',
    ]);
  });

  test('ensureScanAccess：授权已在就直接放行，不跳设置页', () async {
    final seen = <String>[];
    mock((call) async {
      seen.add(call.method);
      return true;
    });

    expect(await bridge.ensureScanAccess(), isTrue);
    expect(seen, ['checkAllFilesAccess']);
  });

  test('ensureScanAccess：桌面端不碰平台通道', () async {
    bridge.forceAndroid = false;
    mock((call) async => fail('桌面端不该调通道：${call.method}'));

    expect(await bridge.ensureScanAccess(), isTrue);
  });
}
