import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// 后台补齐缩略图时的轻量进度提示。
///
/// 一万张图全部生成要很久，没有提示时用户只看到图一张张冒出来。这个浮层
/// 只显示进度，不阻塞操作；补齐结束由 [AppState.backfillingThumbs] 收起。
class ThumbBackfillChip extends StatelessWidget {
  const ThumbBackfillChip({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    if (!appState.backfillingThumbs) return const SizedBox.shrink();
    final total = appState.thumbBackfillTotal;
    final done = appState.thumbBackfillDone;
    return Semantics(
      label: '正在补齐缩略图 $done/$total',
      child: Material(
        color: AppColors.surfaceOf(context),
        elevation: 3,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  value: appState.thumbBackfillProgress,
                  strokeWidth: 2,
                  color: AppColors.accent,
                  backgroundColor: AppColors.surfaceAltOf(context),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                appState.thumbBackfillLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondaryOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
