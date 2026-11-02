import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:asmrshelf/services/thumbnail_cache.dart';
import 'package:asmrshelf/services/video_cover_service.dart';
import 'package:path/path.dart' as p;

/// 假进程。首帧链路只读 stdout / stderr / exitCode，超时用例还读 kill。
class _FakeProcess implements Process {
  _FakeProcess({this.code = 0, this.exitCodeFuture});

  final int code;
  final Future<int>? exitCodeFuture;

  /// 被 kill 过几次。超时用例靠它验证进程真的被收掉了。
  int killCount = 0;

  @override
  Future<int> get exitCode => exitCodeFuture ?? Future<int>.value(code);

  @override
  Stream<List<int>> get stdout => Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stderr => Stream<List<int>>.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCount++;
    return true;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 假封面字节。服务不解码，只写盘，所以内容随便给，长度非 0 就够。
final Uint8List coverBytes =
    Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);

void main() {
  late Directory tmp;
  late Directory cacheDir;
  late String videoPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('video_cover_test');
    cacheDir = Directory(p.join(tmp.path, 'thumbnails'))..createSync();
    final src = Directory(p.join(tmp.path, '影片'))..createSync();
    videoPath = p.join(src.path, '片子.mp4');
    File(videoPath).writeAsBytesSync(List<int>.filled(64, 7));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('一级命中：不再问内嵌封面，也不起进程', () async {
    final systemFile = File(p.join(tmp.path, 'system.png'))
      ..writeAsBytesSync(coverBytes);
    final asked = <String>[];
    var embeddedCalls = 0;
    var startCalls = 0;
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      systemCover: (path) async {
        asked.add(path);
        return systemFile.path;
      },
      embeddedCover: (path) async {
        embeddedCalls++;
        return coverBytes;
      },
      start: (exe, args) async {
        startCalls++;
        return _FakeProcess();
      },
    );

    final cover = await service.coverFor(videoPath);

    expect(asked, <String>[videoPath]);
    expect(cover, isNotNull);
    expect(p.dirname(cover!), cacheDir.path);
    expect(p.basename(cover), startsWith(VideoCoverService.cacheNamePrefix));
    expect(File(cover).readAsBytesSync(), coverBytes);
    expect(embeddedCalls, 0);
    expect(startCalls, 0);
  });

  test('一级落空：问二级，内嵌封面写进缓存', () async {
    var embeddedCalls = 0;
    var startCalls = 0;
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      systemCover: (path) async => null,
      embeddedCover: (path) async {
        embeddedCalls++;
        return coverBytes;
      },
      start: (exe, args) async {
        startCalls++;
        return _FakeProcess();
      },
    );

    final cover = await service.coverFor(videoPath);

    expect(embeddedCalls, 1);
    expect(startCalls, 0);
    expect(cover, isNotNull);
    expect(File(cover!).readAsBytesSync(), coverBytes);
  });

  test('前两级都落空才起 ffmpeg，参数与输出路径正确', () async {
    final calls = <List<String>>[];
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      systemCover: (path) async => null,
      embeddedCover: (path) async => null,
      start: (exe, args) async {
        calls.add(<String>[exe, ...args]);
        if (exe == 'which') return _FakeProcess();
        // 首帧替身：在输出路径上写出文件，模拟 ffmpeg 出了一张 png
        File(args.last).writeAsBytesSync(coverBytes);
        return _FakeProcess();
      },
    );

    final cover = await service.coverFor(videoPath);

    expect(calls.first, <String>['which', 'ffmpeg']);
    final ffmpeg = calls.last;
    expect(ffmpeg.first, 'ffmpeg');
    expect(ffmpeg, containsAll(<String>['-y', '-ss', '0', '-frames:v', '1']));
    expect(ffmpeg[ffmpeg.indexOf('-i') + 1], videoPath);
    expect(ffmpeg[ffmpeg.indexOf('-vf') + 1], 'scale=300:-1');
    // ffmpeg 写的是 .tmp.png，服务改名成稳定文件名后才返回
    expect(p.basename(ffmpeg.last), endsWith('.tmp.png'));
    expect(cover, isNotNull);
    expect(cover, p.join(cacheDir.path,
        '${VideoCoverService.cacheNamePrefix}'
        '${VideoCoverService.thumbnailKeyFor(videoPath)}.png'));
    expect(File(cover!).readAsBytesSync(), coverBytes);
  });

  test('系统里没有 ffmpeg 就不起首帧', () async {
    final calls = <String>[];
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      systemCover: (path) async => null,
      embeddedCover: (path) async => null,
      start: (exe, args) async {
        calls.add(exe);
        return _FakeProcess(code: 1); // which 找不到 ffmpeg 就是这个退出码
      },
    );

    expect(await service.coverFor(videoPath), isNull);
    expect(calls, <String>['which']);
  });

  test('三级都失败返回 null，不抛异常，也不留半张图', () async {
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      systemCover: (path) async => null,
      embeddedCover: (path) async => null,
      start: (exe, args) async => _FakeProcess(code: exe == 'which' ? 0 : 1),
    );

    expect(await service.coverFor(videoPath), isNull);
    expect(cacheDir.listSync(), isEmpty);
  });

  test('替身抛异常也不往外抛，返回 null', () async {
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      systemCover: (path) async => throw StateError('system boom'),
      embeddedCover: (path) async => throw StateError('embedded boom'),
      start: (exe, args) async => throw ProcessException(exe, args),
    );

    expect(await service.coverFor(videoPath), isNull);
  });

  test('ffmpeg 超时按失败算，进程被 kill', () async {
    final never = Completer<int>();
    late _FakeProcess ffmpegProc;
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      timeout: const Duration(milliseconds: 40),
      systemCover: (path) async => null,
      embeddedCover: (path) async => null,
      start: (exe, args) async {
        if (exe == 'which') return _FakeProcess();
        ffmpegProc = _FakeProcess(exitCodeFuture: never.future);
        return ffmpegProc;
      },
    );

    expect(await service.coverFor(videoPath), isNull);
    expect(ffmpegProc.killCount, 1);
  });

  test('第二次调用命中缓存，替身不再被问', () async {
    var systemCalls = 0;
    var embeddedCalls = 0;
    var startCalls = 0;
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      systemCover: (path) async {
        systemCalls++;
        return null;
      },
      embeddedCover: (path) async {
        embeddedCalls++;
        return coverBytes;
      },
      start: (exe, args) async {
        startCalls++;
        return _FakeProcess();
      },
    );

    final first = await service.coverFor(videoPath);
    final second = await service.coverFor(videoPath);

    expect(second, first);
    expect(systemCalls, 1);
    expect(embeddedCalls, 1);
    expect(startCalls, 0);
  });

  test('源文件比缓存新就重取，不吃过期封面', () async {
    var embeddedCalls = 0;
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      systemCover: (path) async => null,
      embeddedCover: (path) async {
        embeddedCalls++;
        return coverBytes;
      },
    );

    expect(await service.coverFor(videoPath), isNotNull);
    expect(embeddedCalls, 1);

    // 同一个路径换了内容：mtime 比缓存新，缓存必须作废
    File(videoPath).writeAsBytesSync(List<int>.filled(128, 9));
    File(videoPath)
        .setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));

    expect(await service.coverFor(videoPath), isNotNull);
    expect(embeddedCalls, 2);
  });

  test('Windows 不做系统缩略图，也不做首帧', () async {
    var systemCalls = 0;
    var embeddedCalls = 0;
    var startCalls = 0;
    final service = VideoCoverService(
      os: 'windows',
      outputDir: cacheDir.path,
      systemCover: (path) async {
        systemCalls++;
        return p.join(tmp.path, 'system.png');
      },
      embeddedCover: (path) async {
        embeddedCalls++;
        return null;
      },
      start: (exe, args) async {
        startCalls++;
        return _FakeProcess();
      },
    );

    expect(await service.coverFor(videoPath), isNull);
    expect(systemCalls, 0);
    expect(startCalls, 0);
    // 内嵌封面不依赖平台，Windows 上照跑
    expect(embeddedCalls, 1);
  });

  test('缓存目录不可用时降级：系统封面按原路径返回', () async {
    final systemFile = File(p.join(tmp.path, 'system.png'))
      ..writeAsBytesSync(coverBytes);
    // 不注入 outputDir 且 ThumbnailService 没 init，此时没有缓存目录可用
    ThumbnailService.instance.resetForTest();
    addTearDown(ThumbnailService.instance.resetForTest);
    final service = VideoCoverService(
      os: 'linux',
      systemCover: (path) async => systemFile.path,
    );

    expect(await service.coverFor(videoPath), systemFile.path);
  });

  test('源文件不存在直接返回 null，不走三级链', () async {
    var systemCalls = 0;
    final service = VideoCoverService(
      os: 'linux',
      outputDir: cacheDir.path,
      systemCover: (path) async {
        systemCalls++;
        return null;
      },
    );

    expect(await service.coverFor(p.join(tmp.path, '没有这个文件.mp4')), isNull);
    expect(systemCalls, 0);
  });

  test('系统缩略图键是文件 URI 的 md5，路径按 URI 编码', () {
    // 真值来自独立实现：
    // python3 -c "import hashlib,urllib.parse; \
    //   print(hashlib.md5(('file://'+urllib.parse.quote(p)).encode()).hexdigest())"
    expect(
      VideoCoverService.thumbnailKeyFor('/tmp/asmrshelf 视频/video one.mp4'),
      'fbb964ccfdf21b4510504d160f9f1a57',
    );
    expect(
      VideoCoverService.thumbnailKeyFor('/home/hoshi/videos/a.mp4'),
      '13a6fc6c45676ecc9d670085ddd1caf5',
    );
  });
}
