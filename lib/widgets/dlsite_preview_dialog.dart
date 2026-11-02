import 'package:flutter/material.dart';

import '../services/dlsite/dlsite_models.dart';
import '../theme/app_theme.dart';

/// 预览里用户的选择。null 表示取消。
class DlsitePreviewChoice {
  const DlsitePreviewChoice({required this.applyCover});

  /// 是否把远程封面下载下来当作品封面。默认不勾：本地图通常更贴近实物。
  final bool applyCover;
}

/// 展示抓回来的元数据，让用户确认后再落库。
Future<DlsitePreviewChoice?> showDlsitePreviewDialog(
  BuildContext context, {
  required DlsiteWork work,
  bool fromCache = false,
}) {
  return showDialog<DlsitePreviewChoice>(
    context: context,
    builder: (ctx) => _DlsitePreviewDialog(work: work, fromCache: fromCache),
  );
}

class _DlsitePreviewDialog extends StatefulWidget {
  const _DlsitePreviewDialog({required this.work, required this.fromCache});

  final DlsiteWork work;
  final bool fromCache;

  @override
  State<_DlsitePreviewDialog> createState() => _DlsitePreviewDialogState();
}

class _DlsitePreviewDialogState extends State<_DlsitePreviewDialog> {
  bool _applyCover = false;

  @override
  Widget build(BuildContext context) {
    final work = widget.work;
    final rows = <(String, String)>[
      if (work.title.isNotEmpty) ('远程标题', work.title),
      if ((work.titleKana ?? '').isNotEmpty) ('假名', work.titleKana!),
      if ((work.makerName ?? '').isNotEmpty) ('社团', work.makerName!),
      if ((work.seriesName ?? '').isNotEmpty) ('系列', work.seriesName!),
      if ((work.seriesId ?? '').isNotEmpty) ('系列 ID', work.seriesId!),
      if ((work.titleWorkCount ?? 0) > 0) ('系列总数', '共 ${work.titleWorkCount} 部'),
      if ((work.workType ?? '').isNotEmpty) ('类型', work.workType!),
      if ((work.ageCategory ?? '').isNotEmpty) ('年龄分级', work.ageCategory!),
      if ((work.releaseDate ?? '').isNotEmpty) ('发售日', work.releaseDate!),
      if (work.stars != null && (work.ratingCount ?? 0) > 0)
        ('评分', '${work.stars!.toStringAsFixed(1)} / 5（${work.ratingCount} 人）'),
      if (work.genreNames.isNotEmpty) ('分类', work.genreNames.join('、')),
      if (work.voiceActors.isNotEmpty)
        ('声优', work.voiceActors.map((c) => c.name).join('、')),
    ];
    return AlertDialog(
      title: Row(
        children: [
          const Text('DLsite 元数据'),
          const SizedBox(width: 8),
          if (widget.fromCache)
            Text('本地缓存',
                style: TextStyle(
                    fontSize: 11, color: AppColors.mutedLightOf(context))),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _cover(context),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final (label, value) in rows)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text.rich(
                              TextSpan(children: [
                                TextSpan(
                                  text: '$label：',
                                  style: TextStyle(
                                      color: AppColors.mutedLightOf(context),
                                      fontSize: 12),
                                ),
                                TextSpan(
                                  text: value,
                                  style: TextStyle(
                                      color: AppColors.textPrimaryOf(context),
                                      fontSize: 12),
                                ),
                              ]),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if ((work.description ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('简介',
                    style: TextStyle(
                        color: AppColors.mutedLightOf(context), fontSize: 12)),
                const SizedBox(height: 4),
                Container(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Text(
                      work.description ?? '',
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: AppColors.textSecondaryOf(context)),
                    ),
                  ),
                ),
              ],
              if (work.cover != null) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const ValueKey('dlsite-apply-cover'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _applyCover,
                  onChanged: (v) => setState(() => _applyCover = v ?? false),
                  title: Text(
                    '同时把这个封面设成作品封面',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondaryOf(context)),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                '作品名不会被改掉；分类与声优会加进对应标签，简介只存在元数据里。',
                style: TextStyle(
                    fontSize: 11, color: AppColors.mutedLightOf(context)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('dlsite-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('dlsite-apply'),
          onPressed: () =>
              Navigator.pop(context, DlsitePreviewChoice(applyCover: _applyCover)),
          child: const Text('应用'),
        ),
      ],
    );
  }

  Widget _cover(BuildContext context) {
    final cover = widget.work.cover;
    if (cover == null) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 160,
        height: 120,
        child: Image.network(
          cover.url,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            color: AppColors.panelOf(context),
            alignment: Alignment.center,
            child: Text('封面加载失败',
                style: TextStyle(
                    fontSize: 11, color: AppColors.mutedLightOf(context))),
          ),
        ),
      ),
    );
  }
}
