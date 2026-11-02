import 'package:asmrshelf/services/subtitle_overlay_bridge.dart';
import 'package:asmrshelf/services/subtitle_overlay_controller.dart';
import 'package:asmrshelf/services/subtitle_parser.dart';
import 'package:asmrshelf/services/subtitle_timing.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlayer extends PlayerController {
  TrackItem? track;
  Duration currentPosition = Duration.zero;

  @override
  TrackItem? get currentTrack => track;

  @override
  Duration get position => currentPosition;

  void tick() => notifyListeners();
}

class _FakeBridge implements SubtitleOverlayBridge {
  bool permission = true;
  bool requestResult = true;
  bool showResult = true;
  bool visible = false;
  bool locked = false;
  String? current;
  String? next;
  final List<String> calls = [];

  @override
  Future<bool> hasPermission() async {
    calls.add('hasPermission');
    return permission;
  }

  @override
  Future<bool> requestPermission() async {
    calls.add('requestPermission');
    return requestResult;
  }

  @override
  Future<bool> show({
    required String current,
    required String next,
    required bool locked,
  }) async {
    calls.add('show');
    this.current = current;
    this.next = next;
    this.locked = locked;
    visible = showResult;
    return showResult;
  }

  @override
  Future<void> update({required String current, required String next}) async {
    calls.add('update');
    this.current = current;
    this.next = next;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
    visible = false;
  }

  @override
  Future<void> setLocked(bool locked) async {
    calls.add('setLocked');
    this.locked = locked;
  }
}

const _track = TrackItem(
  id: 7,
  path: r'D:\ASMR\RJ1\01.mp3',
  filename: '01.mp3',
  addedAt: 0,
);

final _doc = SubtitleDocument(
  hasTiming: true,
  lines: const [
    LyricLine(startMs: 0, endMs: 1000, text: '第一句'),
    LyricLine(startMs: 1000, endMs: 2000, text: '第二句'),
    LyricLine(startMs: 2000, endMs: 3000, text: '第三句'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MethodChannel 桥把当前/下一句和锁定状态按约定传给原生', () async {
    const channel = MethodChannel('asmrshelf/subtitle_overlay.test');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final bridge = MethodChannelSubtitleOverlayBridge(channel: channel);
    expect(await bridge.hasPermission(), isTrue);
    expect(await bridge.show(current: '一', next: '二', locked: true), isTrue);
    await bridge.update(current: '二', next: '三');
    await bridge.setLocked(false);
    await bridge.hide();

    expect(calls.map((call) => call.method), [
      'hasPermission',
      'show',
      'update',
      'setLocked',
      'hide',
    ]);
    expect(calls[1].arguments, {'current': '一', 'next': '二', 'locked': true});
    expect(calls[2].arguments, {'current': '二', 'next': '三'});
    expect(calls[3].arguments, false);
  });

  test('subtitleLineIndex 返回最后一句已开始的行，早于第一句为 -1', () {
    expect(subtitleLineIndex(_doc.lines, Duration.zero), 0);
    expect(
      subtitleLineIndex(_doc.lines, const Duration(milliseconds: 1499)),
      1,
    );
    expect(
      subtitleLineIndex(_doc.lines, const Duration(milliseconds: 2000)),
      2,
    );
    expect(subtitleLineIndex(_doc.lines, const Duration(seconds: -1)), -1);
  });

  test('开启后推送当前/下一句，播放位置变化时更新', () async {
    final player = _FakePlayer()
      ..track = _track
      ..currentPosition = const Duration(milliseconds: 1200);
    final bridge = _FakeBridge();
    final controller = SubtitleOverlayController(
      player: player,
      subtitleFor: (_) => _doc,
      bridge: bridge,
      persistEnabled: (_) async {},
      persistLocked: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.configure(enabled: true, locked: true);
    expect(controller.enabled, isTrue);
    expect(bridge.visible, isTrue);
    expect(bridge.current, '第二句');
    expect(bridge.next, '第三句');
    expect(bridge.locked, isTrue);

    player.currentPosition = const Duration(milliseconds: 2500);
    player.tick();
    await pumpEventQueue();
    expect(bridge.current, '第三句');
    expect(bridge.next, isEmpty);
    expect(bridge.calls.where((call) => call == 'update'), hasLength(1));
  });

  test('无权限时开启失败并持久化关闭', () async {
    final player = _FakePlayer()..track = _track;
    final bridge = _FakeBridge()..requestResult = false;
    var persisted = true;
    final controller = SubtitleOverlayController(
      player: player,
      subtitleFor: (_) => _doc,
      bridge: bridge,
      persistEnabled: (value) async => persisted = value,
      persistLocked: (_) async {},
    );
    addTearDown(controller.dispose);

    final ok = await controller.setEnabled(true);
    expect(ok, isFalse);
    expect(controller.enabled, isFalse);
    expect(controller.error, contains('悬浮窗权限'));
    expect(persisted, isFalse);
    expect(bridge.calls, contains('requestPermission'));
    expect(bridge.calls, isNot(contains('show')));
  });

  test('没有字幕或曲目时隐藏窗口', () async {
    final player = _FakePlayer();
    final bridge = _FakeBridge();
    final controller = SubtitleOverlayController(
      player: player,
      subtitleFor: (_) => SubtitleDocument.empty,
      bridge: bridge,
      persistEnabled: (_) async {},
      persistLocked: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.configure(enabled: true, locked: false);
    expect(controller.enabled, isTrue);
    expect(bridge.visible, isFalse);
    expect(bridge.calls, isNot(contains('show')));
  });

  test('重入同步不会重复 push 同一行', () async {
    final player = _FakePlayer()
      ..track = _track
      ..currentPosition = const Duration(milliseconds: 100);
    final bridge = _FakeBridge();
    final controller = SubtitleOverlayController(
      player: player,
      subtitleFor: (_) => _doc,
      bridge: bridge,
      persistEnabled: (_) async {},
      persistLocked: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.configure(enabled: true, locked: false);
    player.tick();
    player.tick();
    await pumpEventQueue();
    expect(bridge.calls.where((call) => call == 'update'), isEmpty);
    expect(bridge.calls.where((call) => call == 'show'), hasLength(1));
  });
}
