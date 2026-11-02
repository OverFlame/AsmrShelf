import 'package:flutter/material.dart' hide RepeatMode;
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/player_controller.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../pages/subtitle_page.dart';
import 'cover_image.dart';
import 'queue_panel.dart';
import 'segment_panel.dart';

/// 底部播放栏
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final appState = context.watch<AppState>();
    final track = player.currentTrack;
    final isWide = MediaQuery.of(context).size.width >= 600;

    if (track == null) {
      return Container(
        height: 72,
        color: AppColors.panelOf(context),
        child: Center(
          child: Text('未在播放',
              style:
                  TextStyle(color: AppColors.mutedLightOf(context), fontSize: 13)),
        ),
      );
    }

    final maxMs = player.duration.inMilliseconds;
    final posMs =
        player.position.inMilliseconds.clamp(0, maxMs > 0 ? maxMs : 0);
    final cover = appState.coverForTrack(track);

    return Container(
      height: 84,
      decoration: BoxDecoration(
        color: AppColors.panelOf(context),
        border: Border(
            top: BorderSide(
                color: AppColors.surfaceAltOf(context), width: 0.5)),
      ),
      child: Column(
        children: [
          // 进度条
          SizedBox(
            height: 18,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              ),
              child: Slider(
                value: maxMs > 0 ? posMs.toDouble() : 0,
                max: maxMs > 0 ? maxMs.toDouble() : 1,
                activeColor: AppColors.accent,
                inactiveColor: AppColors.surfaceAltOf(context),
                onChanged: (v) => player.seek(Duration(milliseconds: v.round())),
              ),
            ),
          ),
          // 信息 + 控制
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  CoverImage(path: cover, width: 48, height: 48, borderRadius: 6),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppColors.textPrimaryOf(context),
                              fontSize: 14,
                              fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist ?? track.album ?? track.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppColors.textSecondaryOf(context),
                              fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${formatDuration(player.position)} / ${formatDuration(player.duration)}',
                    style: TextStyle(
                        color: AppColors.mutedLightOf(context), fontSize: 11),
                  ),
                  const SizedBox(width: 6),
                  if (isWide) ...[
                    // 音量
                    IconButton(
                      icon: Icon(_volumeIcon(player.volume),
                          size: 18, color: AppColors.mutedLightOf(context)),
                      tooltip: '音量',
                      onPressed: () => _showVolumeDialog(context, player),
                    ),
                    IconButton(
                      icon: Icon(
                        player.shuffle ? Icons.shuffle : Icons.shuffle_on_outlined,
                        size: 18,
                        color: player.shuffle
                            ? AppColors.accent
                            : AppColors.mutedLightOf(context),
                      ),
                      tooltip: '随机播放',
                      onPressed: player.toggleShuffle,
                    ),
                  ],
                  IconButton(
                    icon: Icon(Icons.skip_previous,
                        size: 26, color: AppColors.textPrimaryOf(context)),
                    tooltip: '上一首',
                    onPressed: () => player.previous(),
                  ),
                  IconButton(
                    icon: Icon(
                      player.playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                      size: 38,
                      color: AppColors.accent,
                    ),
                    tooltip: player.playing ? '暂停' : '播放',
                    onPressed: () => player.togglePlay(),
                  ),
                  IconButton(
                    icon: Icon(Icons.skip_next,
                        size: 26, color: AppColors.textPrimaryOf(context)),
                    tooltip: '下一首',
                    onPressed: () => player.next(),
                  ),
                  if (isWide)
                    IconButton(
                      icon: Icon(
                        _repeatIcon(player.repeatMode),
                        size: 18,
                        color: player.repeatMode != RepeatMode.off
                            ? AppColors.accent
                            : AppColors.mutedLightOf(context),
                      ),
                      tooltip: '循环模式',
                      onPressed: () => _cycleRepeat(player),
                    ),
                  if (isWide) ...[
                    TextButton(
                      onPressed: () => _showSpeedDialog(context, player),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      child: Text(
                        '${_speedLabel(player.speed)}x',
                        style: TextStyle(
                            color: player.speed != 1.0
                                ? AppColors.accent
                                : AppColors.mutedLightOf(context),
                            fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.queue_music,
                          size: 18, color: AppColors.mutedLightOf(context)),
                      tooltip: '播放队列',
                      onPressed: () => QueuePanel.show(context),
                    ),
                    TextButton(
                      key: const ValueKey('player-segment-button'),
                      onPressed: () => SegmentPanel.show(context),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      child: Text(
                        '选区',
                        style: TextStyle(
                            color: player.segmentLoopEnabled
                                ? AppColors.accent
                                : AppColors.mutedLightOf(context),
                            fontSize: 12),
                      ),
                    ),
                  ],
                  IconButton(
                    icon: const Icon(Icons.subtitles_outlined,
                        size: 20, color: AppColors.teal),
                    tooltip: '字幕模式',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SubtitlePage()),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _volumeIcon(double v) {
    if (v <= 0) return Icons.volume_off;
    if (v < 0.5) return Icons.volume_down;
    return Icons.volume_up;
  }

  Future<void> _showVolumeDialog(
      BuildContext context, PlayerController player) {
    return showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('音量'),
          content: SizedBox(
            width: 240,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.volume_down, size: 18),
                Expanded(
                  child: Slider(
                    value: player.volume,
                    min: 0,
                    max: 1,
                    onChanged: (v) {
                      setLocal(() {});
                      player.setVolume(v);
                    },
                  ),
                ),
                const Icon(Icons.volume_up, size: 18),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  IconData _repeatIcon(RepeatMode m) => switch (m) {
        RepeatMode.off => Icons.repeat,
        RepeatMode.all => Icons.repeat,
        RepeatMode.one => Icons.repeat_one,
      };

  void _cycleRepeat(PlayerController player) {
    final next = switch (player.repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    player.setRepeatMode(next);
  }

  /// 速度标签：整数不带小数点，其余按原值显示
  String _speedLabel(double speed) {
    if (speed == speed.roundToDouble()) return speed.toStringAsFixed(0);
    return speed.toString();
  }

  /// 播放速度对话框：滑杆、常用档位与恢复 1x
  Future<void> _showSpeedDialog(
      BuildContext context, PlayerController player) {
    const presets = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final divisions = ((PlayerController.maxSpeed - PlayerController.minSpeed) /
            PlayerController.speedStep)
        .round();
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('播放速度'),
        content: ListenableBuilder(
          listenable: player,
          builder: (ctx, _) => SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Slider(
                  value: player.speed,
                  min: PlayerController.minSpeed,
                  max: PlayerController.maxSpeed,
                  divisions: divisions,
                  activeColor: AppColors.accent,
                  label: '${_speedLabel(player.speed)}x',
                  onChanged: (v) => player.setSpeed(v),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final s in presets)
                      ChoiceChip(
                        label: Text('${_speedLabel(s)}x',
                            style: const TextStyle(fontSize: 12)),
                        selected: player.speed == s,
                        onSelected: (_) => player.setSpeed(s),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => player.setSpeed(1.0),
            child: const Text('恢复 1x'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
