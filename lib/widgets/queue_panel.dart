import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/player_controller.dart';
import '../theme/app_theme.dart';

/// 播放队列面板。
///
/// 支持拖动排序、点击跳到某首、移除某一首。
class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key});

  /// 以底部弹层形式打开队列面板
  static Future<void> show(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panelOf(context),
      builder: (_) => SizedBox(height: height * 0.6, child: const QueuePanel()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final queue = player.queue;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Icon(Icons.queue_music, size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                '播放队列（${queue.length}）',
                style: TextStyle(
                    color: AppColors.textPrimaryOf(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.close,
                    size: 18, color: AppColors.mutedOf(context)),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: AppColors.surfaceAltOf(context)),
        Expanded(
          child: queue.isEmpty
              ? Center(
                  child: Text('队列为空',
                      style: TextStyle(
                          color: AppColors.mutedLightOf(context),
                          fontSize: 13)),
                )
              : ReorderableListView.builder(
                  itemCount: queue.length,
                  onReorderItem: (oldIndex, newIndex) =>
                      player.reorder(oldIndex, newIndex),
                  itemBuilder: (ctx, i) {
                    final track = queue[i];
                    final playing = i == player.index;
                    return ListTile(
                      // 队列里可能有同路径的重复项，键里带上下标
                      key: ValueKey('${track.path}#$i'),
                      dense: true,
                      leading: Icon(
                        playing ? Icons.volume_up : Icons.drag_handle,
                        size: 18,
                        color: playing
                            ? AppColors.accent
                            : AppColors.mutedOf(context),
                      ),
                      title: Text(
                        track.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: playing
                                ? AppColors.accent
                                : AppColors.textPrimaryOf(context),
                            fontSize: 13,
                            fontWeight:
                                playing ? FontWeight.w600 : FontWeight.normal),
                      ),
                      subtitle: Text(
                        track.artist ?? track.album ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppColors.textSecondaryOf(context),
                            fontSize: 11),
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.remove_circle_outline,
                            size: 18, color: AppColors.mutedOf(context)),
                        tooltip: '从队列移除',
                        onPressed: () => player.removeAt(i),
                      ),
                      onTap: () => player.jumpTo(i),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
