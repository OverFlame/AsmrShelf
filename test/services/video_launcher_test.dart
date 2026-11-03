import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/services/media_rules.dart';
import 'package:asmrshelf/services/video_launcher.dart';

/// 假进程。测试只读 exitCode，其余成员一碰就炸。
class _FakeProcess implements Process {
  _FakeProcess({this.code = 0, this.exitCodeFuture});

  final int code;
  final Future<int>? exitCodeFuture;

  @override
  Future<int> get exitCode => exitCodeFuture ?? Future<int>.value(code);

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test('平台分派表：Windows 用 explorer，Linux 用 xdg-open，其他不执行', () {
    final win = VideoLauncher.commandFor('/m/列表.m3u8', 'windows');
    expect(win, isNotNull);
    expect(win!.$1, 'explorer.exe');
    expect(win.$2, ['/m/列表.m3u8']);

    final linux = VideoLauncher.commandFor('/m/列表.m3u8', 'linux');
    expect(linux, isNotNull);
    expect(linux!.$1, 'xdg-open');
    expect(linux.$2, ['/m/列表.m3u8']);

    expect(VideoLauncher.commandFor('/m/列表.m3u8', 'other'), isNull);
  });


  test('Windows 路径作为独立参数交给 explorer，不经 shell 解析', () async {
    final calls = <List<String>>[];
    final launcher = VideoLauncher(
      os: 'windows',
      start: (exe, args) async {
        calls.add([exe, ...args]);
        // explorer.exe 打开成功也常返回 1；不能据此报失败。
        return _FakeProcess(code: 1);
      },
    );

    const path = r'D:\ASMR\A&B^C%TEMP%\列表.m3u8';
    expect(await launcher.open(path), LaunchResult.ok);
    expect(calls, [
      ['explorer.exe', path]
    ]);
  });

  test('Linux 下把路径交给 xdg-open 并返回 ok', () async {
    final calls = <List<String>>[];
    final launcher = VideoLauncher(
      os: 'linux',
      start: (exe, args) async {
        calls.add([exe, ...args]);
        return _FakeProcess();
      },
    );

    expect(await launcher.open('/m/播放 列表.m3u8'), LaunchResult.ok);
    expect(calls, [
      ['xdg-open', '/m/播放 列表.m3u8']
    ]);
  });

  test('不支持的平台不执行进程', () async {
    var called = false;
    final launcher = VideoLauncher(
      os: 'other',
      start: (exe, args) async {
        called = true;
        return _FakeProcess();
      },
    );

    expect(await launcher.open('/m/a.m3u8'), LaunchResult.unsupportedPlatform);
    expect(called, isFalse);
  });

  test('进程起不来时返回 failed', () async {
    final launcher = VideoLauncher(
      os: 'linux',
      start: (exe, args) async => throw ProcessException('xdg-open', const []),
    );

    expect(await launcher.open('/m/a.m3u8'), LaunchResult.failed);
  });

  test('桌面进程立刻非 0 退出时返回 failed', () async {
    final launcher = VideoLauncher(
      os: 'linux',
      start: (exe, args) async => _FakeProcess(code: 3),
    );

    // xdg-open 没有处理器时就是这样：起得来、立刻带非 0 退出码收工。
    // 旧实现把 Process 丢掉直接报 ok，用户只看到「已交给系统默认播放器」。
    expect(await launcher.open('/m/a.m3u8'), LaunchResult.failed);
  });

  test('桌面处理器挂在后台（不退出）时仍算成功', () async {
    final never = Completer<int>();
    final launcher = VideoLauncher(
      os: 'linux',
      exitCodeGrace: const Duration(milliseconds: 30),
      start: (exe, args) async => _FakeProcess(exitCodeFuture: never.future),
    );

    expect(await launcher.open('/m/a.m3u8'), LaunchResult.ok);
  });

  test('detectOs 只认 Windows、Linux 与 Android', () {
    expect(VideoLauncher.detectOs(),
        anyOf('windows', 'linux', 'android', 'other'));
  });

  test('MIME 表覆盖全部视频扩展名，认不出时给 video/*', () {
    for (final ext in videoExtensions) {
      expect(VideoLauncher.mimeByExtension[ext], isNotNull,
          reason: '$ext 没有对应的 MIME');
    }
    expect(VideoLauncher.mimeTypeFor('/m/片子.MP4'), 'video/mp4');
    expect(VideoLauncher.mimeTypeFor('/m/播放 列表.m3u8'), 'application/x-mpegurl');
    expect(VideoLauncher.mimeTypeFor('/m/没有扩展名'), 'video/*');
    expect(VideoLauncher.mimeTypeFor('/m/奇怪.xyz'), 'video/*');
  });

  test('Android 把路径与 MIME 交给 Intent 桥，成功返回 ok', () async {
    final calls = <(String, String)>[];
    final launcher = VideoLauncher(
      os: 'android',
      openWithSystem: (path, mime) async {
        calls.add((path, mime));
        return true;
      },
    );

    expect(await launcher.open('/storage/emulated/0/Movies/a.mkv'),
        LaunchResult.ok);
    expect(calls, [('/storage/emulated/0/Movies/a.mkv', 'video/x-matroska')]);
  });

  test('Android 没有应用接手或抛异常都返回 failed', () async {
    final noApp = VideoLauncher(os: 'android', openWithSystem: (p, m) async => false);
    expect(await noApp.open('/m/a.mp4'), LaunchResult.failed);

    final boom = VideoLauncher(
      os: 'android',
      openWithSystem: (p, m) async => throw MissingPluginException('no impl'),
    );
    expect(await boom.open('/m/a.mp4'), LaunchResult.failed);
  });

  test('Android 桥迟迟不回时按超时算失败', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      VideoLauncher.channel,
      (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return true;
      },
    );
    addTearDown(() => binding.defaultBinaryMessenger
        .setMockMethodCallHandler(VideoLauncher.channel, null));

    final launcher = VideoLauncher(
        os: 'android', openTimeout: const Duration(milliseconds: 30));

    // 旧实现没有 timeout：通道不回话，这个 await 就一直挂着，
    // 界面停在点击那一刻，也没有任何日志。
    expect(await launcher.open('/m/a.mp4'), LaunchResult.failed);
  });

  test('Android 默认实现走 asmrshelf/playback 的 openVideo', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      VideoLauncher.channel,
      (call) async {
        calls.add(call);
        return true;
      },
    );
    addTearDown(() => binding.defaultBinaryMessenger
        .setMockMethodCallHandler(VideoLauncher.channel, null));

    final launcher = VideoLauncher(os: 'android');
    expect(await launcher.open('/storage/emulated/0/Movies/a.webm'),
        LaunchResult.ok);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'openVideo');
    expect(calls.single.arguments, <String, Object>{
      'path': '/storage/emulated/0/Movies/a.webm',
      'mimeType': 'video/webm',
    });
  });
}
