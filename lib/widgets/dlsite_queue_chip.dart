import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// DLsite 批量抓取时的进度浮层。
///
/// 队列在后台跑，限速器让每部作品之间至少隔几秒；没有提示时用户不知道
/// 还在工作。只显示进度与取消，不阻塞别的操作。
class DlsiteQueueChip extends StatelessWidget {
  const DlsiteQueueChip({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>().dlsite;
    if (!state.scrapeRunning) return const SizedBox.shrink();
    final total = state.scrapeTotal;
    final done = state.scrapeDone;
    final failed = state.scrapeFailed;
    return Semantics(
      label: '正在抓取 DLsite 元数据 $done/$total',
      child: Material(
        key: const ValueKey('dlsite-queue-chip'),
        color: AppColors.surfaceOf(context),
        elevation: 3,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  value: total == 0 ? null : done / total,
                  strokeWidth: 2,
                  color: AppColors.accent,
                  backgroundColor: AppColors.surfaceAltOf(context),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'DLsite $done/$total${failed > 0 ? '（失败 $failed）' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondaryOf(context),
                ),
              ),
              IconButton(
                key: const ValueKey('dlsite-queue-cancel'),
                tooltip: '取消剩余抓取',
                icon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: state.cancelScrapeQueue,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
