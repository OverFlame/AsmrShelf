import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/play_position.dart';
import 'package:asmrshelf/services/segment_service.dart';
import 'package:asmrshelf/state/playback_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 播放状态里不碰引擎的那几条路：续播位置、播放历史、选段去重。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late PlaybackState state;
  late PlayerController player;
  late List<TrackItem> tracks;
  late List<String?> rememberedCovers;
  var notified = 0;

  TrackItem track(int id, {int position = 0, int? duration}) => TrackItem(
        id: id,
        path: '/media/$id.mp3',
        filename: '$id.mp3',
        durationMs: duration,
        addedAt: 0,
        playPositionMs: position,
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_playback_state');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    tracks = [track(1), track(2)];
    rememberedCovers = [];
    player = PlayerController();
    state = PlaybackState(
      player: player,
      trackDao: () => TrackDao(DatabaseManager.instance.db),
      mediaDao: () => MediaDao(DatabaseManager.instance.db),
      segmentService: () => SegmentService(DatabaseManager.instance.db),
      currentTracks: () => tracks,
      onTracksChanged: (next) => tracks = next,
      rememberQueueCover: rememberedCovers.add,
      queueCoverPath: () => 'work_1.jpg',
    )..addListener(() => notified++);
    notified = 0;
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  test('续播位置按 PlayPositionRules 取舍', () {
    expect(state.resumeOf(track(1, position: 0)), Duration.zero);
    expect(state.resumeOf(track(1, position: 2000)), Duration.zero);
    expect(
      state.resumeOf(track(1, position: 30000, duration: 600000)),
      const Duration(seconds: 30),
    );
    expect(
      state.resumeOf(track(1, position: 598000, duration: 600000)),
      Duration.zero,
    );
  });

  test('播放中报位置要过 5 秒节流，写库后同步进当前列表', () async {
    state.onPosition(track(1), const Duration(seconds: 3));
    expect(state.player.position, Duration.zero);
    expect(notified, 0);

    state.onPosition(track(1, position: 10000), const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(tracks.first.playPositionMs, 10000);

    state.onTrackCompleted(track(1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(tracks.first.playPositionMs, 0);
  });

  test('切歌写播放历史并刷新最近播放', () async {
    final id = await MediaDao(DatabaseManager.instance.db).insertRow({
      'path': '/media/1.mp3',
      'filename': '1.mp3',
      'media_type': 'audio',
      'added_at': 0,
    });
    state.onTrackStarted(track(id));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(state.recentTracks.map((t) => t.filename), ['1.mp3']);
  });

  test('选段同一份列表不重复通知', () {
    final seg = MediaSegment(
      id: 1,
      mediaId: 1,
      startMs: 0,
      endMs: 1000,
      createdAt: 0,
    );
    state.assignSegments([seg]);
    state.assignSegments([seg]);
    expect(state.segments, [seg]);
    expect(notified, 1);
  });

  test('最近播放不发请求，队列为空时直接返回', () async {
    await state.playRecent(0);
    expect(rememberedCovers, isEmpty);
    expect(player.queueLength, 0);
  });

  test('节流器本身的行为保持不变', () {
    final throttle = PlayPositionThrottle();
    expect(throttle.shouldSave(const Duration(seconds: 4)), isFalse);
    expect(throttle.shouldSave(const Duration(seconds: 5)), isTrue);
    expect(throttle.shouldSave(const Duration(seconds: 6)), isFalse);
    expect(throttle.shouldSave(const Duration(seconds: 1)), isFalse,
        reason: '往回拖清掉基准，但前进量还不够一个步长');
    expect(throttle.shouldSave(const Duration(seconds: 6)), isTrue);
  });
}
