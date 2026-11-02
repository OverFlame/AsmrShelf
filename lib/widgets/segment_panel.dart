import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/segment_service.dart';
import '../state/app_state.dart';
import '../state/player_controller.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import 'controller_owner.dart';

/// 收藏选段面板（BUILD_GUIDE 第 24.3 节）。
///
/// 拖两个手柄定范围，松手才生效；段列表支持循环、跳转、重命名与删除。
class SegmentPanel extends StatefulWidget {
  const SegmentPanel({super.key});

  /// 以底部弹层形式打开面板
  static Future<void> show(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panelOf(context),
      builder: (_) =>
          SizedBox(height: height * 0.7, child: const SegmentPanel()),
    );
  }

  @override
  State<SegmentPanel> createState() => _SegmentPanelState();
}

class _SegmentPanelState extends State<SegmentPanel> {
  /// 两个手柄的位置（毫秒）。null 表示还没算过。
  RangeValues? _range;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().reloadSegments();
      _resetRange();
    });
  }

  /// 按当前曲目时长与正在循环的段复位手柄
  void _resetRange() {
    final player = context.read<PlayerController>();
    final total = player.duration.inMilliseconds;
    if (total <= 0) {
      setState(() => _range = null);
      return;
    }
    final seg = player.loopSegment;
    final normalized = seg == null
        ? (startMs: 0, endMs: total)
        : SegmentService.normalizeRange(seg.startMs, seg.endMs, total);
    setState(() {
      _range = RangeValues(
        normalized.startMs.toDouble(),
        normalized.endMs.toDouble(),
      );
    });
  }

  /// 把当前手柄范围包成一段（未落库）
  MediaSegment? _currentSegment(PlayerController player, RangeValues range) {
    final id = player.currentTrack?.id;
    if (id == null) return null;
    return MediaSegment(
      mediaId: id,
      startMs: range.start.round(),
      endMs: range.end.round(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _save(PlayerController player, int totalMs) async {
    final app = context.read<AppState>();
    final range = _range ?? RangeValues(0, totalMs.toDouble());
    final name = await _askName(null);
    if (name == null) return;
    final seg = await app.addSegment(
      startMs: range.start.round(),
      endMs: range.end.round(),
      name: name,
    );
    if (!mounted) return;
    if (seg == null) {
      _toast('没有正在播放的曲目');
      return;
    }
    await app.loopSegment(seg);
    if (!mounted) return;
    _toast('已保存选段');
  }

  Future<void> _rename(MediaSegment seg) async {
    final app = context.read<AppState>();
    final name = await _askName(seg.name);
    if (name == null) return;
    await app.renameSegment(seg, name);
  }

  Future<String?> _askName(String? initial) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => ControllerOwner(
        controllers: [controller],
        child: AlertDialog(
          title: const Text('选段名称'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '例如：副歌'),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              key: const ValueKey('segment-name-ok'),
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final app = context.watch<AppState>();
    final total = player.duration.inMilliseconds;
    final track = player.currentTrack;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Icon(Icons.bookmark_border, size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                '收藏选段',
                style: TextStyle(
                    color: AppColors.textPrimaryOf(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('segment-close'),
                icon: Icon(Icons.close,
                    size: 18, color: AppColors.mutedOf(context)),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: AppColors.surfaceAltOf(context)),
        if (track == null || total <= 0)
          Expanded(
            child: Center(
              child: Text('先播放一首曲目，再拖手柄选区',
                  style: TextStyle(
                      color: AppColors.mutedLightOf(context), fontSize: 13)),
            ),
          )
        else ...[
          _rangeBar(player, total),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                TextButton.icon(
                  key: const ValueKey('segment-save'),
                  icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                  label: const Text('保存选段'),
                  onPressed: () => _save(player, total),
                ),
                TextButton.icon(
                  key: const ValueKey('segment-clear'),
                  icon: const Icon(Icons.close_fullscreen, size: 16),
                  label: const Text('清除选区'),
                  onPressed: player.segmentLoopEnabled
                      ? () => app.loopSegment(null)
                      : null,
                ),
                const Spacer(),
                Text(
                  track.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppColors.mutedOf(context), fontSize: 11),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.surfaceAltOf(context)),
          Expanded(child: _segmentList(app, player, total)),
        ],
      ],
    );
  }

  Widget _rangeBar(PlayerController player, int total) {
    final range = _range ?? RangeValues(0, total.toDouble());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Text(formatDuration(Duration(milliseconds: range.start.round())),
                  style: TextStyle(
                      color: AppColors.textSecondaryOf(context), fontSize: 12)),
              const Spacer(),
              Text('到', style: TextStyle(
                  color: AppColors.mutedOf(context), fontSize: 12)),
              const Spacer(),
              Text(formatDuration(Duration(milliseconds: range.end.round())),
                  style: TextStyle(
                      color: AppColors.textSecondaryOf(context), fontSize: 12)),
            ],
          ),
        ),
        RangeSlider(
          key: const ValueKey('segment-range'),
          min: 0,
          max: total.toDouble(),
          values: range,
          labels: RangeLabels(
            formatDuration(Duration(milliseconds: range.start.round())),
            formatDuration(Duration(milliseconds: range.end.round())),
          ),
          // 拖动过程中只更新手柄，松手才把选区交给播放器
          onChanged: (v) => setState(() => _range = v),
          onChangeEnd: (v) {
            setState(() => _range = v);
            final seg = _currentSegment(player, v);
            if (seg != null) context.read<AppState>().loopSegment(seg);
          },
        ),
      ],
    );
  }

  Widget _segmentList(AppState app, PlayerController player, int total) {
    final segments = app.segments;
    final looping = player.loopSegment;
    if (segments.isEmpty) {
      return Center(
        child: Text('这首曲目还没有选段',
            style:
                TextStyle(color: AppColors.mutedLightOf(context), fontSize: 13)),
      );
    }
    return ListView.builder(
      itemCount: segments.length,
      itemBuilder: (ctx, i) {
        final seg = segments[i];
        final active = looping != null && looping.id != null &&
            looping.id == seg.id;
        return ListTile(
          key: ValueKey('segment-${seg.id}'),
          dense: true,
          leading: Icon(
            active ? Icons.repeat_one : Icons.bookmark_border,
            size: 18,
            color: active ? AppColors.accent : AppColors.mutedOf(context),
          ),
          title: Text(
            seg.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: active
                    ? AppColors.accent
                    : AppColors.textPrimaryOf(context),
                fontSize: 13,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal),
          ),
          subtitle: Text(
            '${formatDuration(seg.start)} - ${formatDuration(seg.end)}'
            '（${formatDuration(seg.length)}）',
            style: TextStyle(
                color: AppColors.textSecondaryOf(context), fontSize: 11),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: ValueKey('segment-loop-${seg.id}'),
                icon: Icon(active ? Icons.repeat_one : Icons.repeat, size: 18),
                tooltip: active ? '停止循环这一段' : '循环这一段',
                onPressed: () => app.loopSegment(active ? null : seg),
              ),
              IconButton(
                key: ValueKey('segment-jump-${seg.id}'),
                icon: const Icon(Icons.play_arrow, size: 18),
                tooltip: '跳到段首',
                onPressed: () => app.jumpToSegment(seg),
              ),
              IconButton(
                key: ValueKey('segment-rename-${seg.id}'),
                icon: const Icon(Icons.edit_outlined, size: 16),
                tooltip: '重命名',
                onPressed: () => _rename(seg),
              ),
              IconButton(
                key: ValueKey('segment-delete-${seg.id}'),
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: '删除',
                onPressed: () => app.deleteSegment(seg),
              ),
            ],
          ),
          onTap: () => app.jumpToSegment(seg),
        );
      },
    );
  }
}
