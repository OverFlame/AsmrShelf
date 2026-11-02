import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/video_cover_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 多媒体栏里视频封面的取图与内存缓存（回退链在 video_cover_service_test 里）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late MediaDao mediaDao;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_video_cover');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    mediaDao = MediaDao(DatabaseManager.instance.db);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  MediaItem videoItem(String path) => MediaItem(
        path: path,
        filename: p.basename(path),
        mediaType: MediaType.video,
        addedAt: 0,
      );

  test('视频封面走取图服务，同一路径第二次直接吃内存缓存', () async {
    final video = File(p.join(tmp.path, 'a.mp4'))..writeAsStringSync('v');
    final thumb = File(p.join(tmp.path, 'sys.png'))..writeAsStringSync('一级图');
    final covers = p.join(tmp.path, 'covers');
    var calls = 0;
    final app = AppState(
      player: PlayerController(),
      videoCovers: VideoCoverService(
        os: 'linux',
        outputDir: covers,
        systemCover: (String path) async {
          calls++;
          return thumb.path;
        },
      ),
    );
    await app.init();

    final want = p.join(covers,
        '${VideoCoverService.cacheNamePrefix}${VideoCoverService.thumbnailKeyFor(video.path)}.png');
    expect(await app.videoCoverFor(videoItem(video.path)), want);
    expect(File(want).readAsStringSync(), '一级图',
        reason: '取到的封面要落到缓存目录里');
    expect(await app.videoCoverFor(videoItem(video.path)), want);
    expect(calls, 1, reason: '同一个路径只问服务一次');
  });

  test('行自己的封面优先；手选封面后会清掉取图缓存', () async {
    final video = File(p.join(tmp.path, 'b.mp4'))..writeAsStringSync('v');
    final first = File(p.join(tmp.path, 'first.png'))..writeAsStringSync('第一版');
    final second = File(p.join(tmp.path, 'second.png'))..writeAsStringSync('第二版');
    final own = File(p.join(tmp.path, 'own.png'))..writeAsStringSync('手选版');
    final covers = p.join(tmp.path, 'covers2');
    var calls = 0;
    final app = AppState(
      player: PlayerController(),
      videoCovers: VideoCoverService(
        os: 'linux',
        outputDir: covers,
        systemCover: (String path) async {
          calls++;
          return calls == 1 ? first.path : second.path;
        },
      ),
    );
    await app.init();
    final id = await mediaDao.insertRow(videoItem(video.path).toMap());

    final want = p.join(covers,
        '${VideoCoverService.cacheNamePrefix}${VideoCoverService.thumbnailKeyFor(video.path)}.png');

    // 库里还没有手选封面，取图服务的话算数
    final before = (await mediaDao.getById(id))!;
    expect(await app.videoCoverFor(before), want);
    expect(File(want).readAsStringSync(), '第一版');

    await app.setMediaCover(id, own.path);
    // 把源文件改新一点，让服务磁盘上那张缓存也过期；这样「重新取图」这件事
    // 才会真的发生，内存缓存有没有被清掉就看得出来。
    video.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));

    // 同一个（还带着空 coverPath 的）对象再问一次：缓存被清掉了，会重新取图
    expect(await app.videoCoverFor(before), want);
    expect(File(want).readAsStringSync(), '第二版',
        reason: '手选封面要立刻生效，所以清空了内存缓存');
    expect(calls, 2, reason: '内存缓存清掉后会再问一次取图服务');
    // 而库里重新读出来的行带着手选封面，直接赢过取图服务
    final after = (await mediaDao.getById(id))!;
    expect(after.coverPath, own.path);
    expect(await app.videoCoverFor(after), own.path);
    expect(calls, 2, reason: '有手选封面时不再问取图服务');
  });

  test('三级都取不到时返回 null，不往外抛', () async {
    final video = File(p.join(tmp.path, 'c.mkv'))..writeAsStringSync('v');
    final app = AppState(
      player: PlayerController(),
      videoCovers: VideoCoverService(
        os: 'linux',
        systemCover: (String path) async => null,
        embeddedCover: (String path) async => null,
        start: (String exe, List<String> args) async =>
            throw StateError('机器上没有 ffmpeg'),
      ),
    );
    await app.init();

    expect(await app.videoCoverFor(videoItem(video.path)), isNull);
  });
}
