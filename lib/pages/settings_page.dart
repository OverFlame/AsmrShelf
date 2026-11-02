import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_service.dart';
import '../services/subtitle_style.dart';
import '../services/thumbnail_cache.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/log_util.dart';
import '../widgets/dialogs.dart';
import 'about_page.dart';

/// 设置页
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          // ── 外观 ──
          const _SectionHeader('外观'),
          _themeSelector(context, appState),
          const Divider(height: 1),

          // ── 字幕 ──
          const _SectionHeader('字幕'),
          _subtitleOpacityTile(context, appState),
          _subtitleResumeTile(context, appState),
          const Divider(height: 1),

          // ── 图片网格 ──
          const _SectionHeader('图片网格'),
          _gridColumnsTile(context, appState),
          _viewModeTile(context, appState),
          const Divider(height: 1),

          // ── 界面布局 ──
          const _SectionHeader('界面布局'),
          ListTile(
            key: const ValueKey('reset-layout'),
            leading: const Icon(Icons.dashboard_customize_outlined, size: 18),
            title: const Text('恢复默认布局'),
            subtitle: Text(
              '左栏 ${appState.leftWidth.round()} 像素，作品集 ${appState.libraryHeight.round()} 像素；'
              '恢复为 260 与 200。也可以双击分隔条。',
              style: TextStyle(
                  fontSize: 11, color: AppColors.textSecondaryOf(context)),
            ),
            trailing: const Icon(Icons.restart_alt, size: 18),
            onTap: () async {
              await appState.resetLayoutSizes();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('布局已恢复默认')));
              }
            },
          ),
          const Divider(height: 1),

          // ── 高级筛选 ──
          const _SectionHeader('高级筛选'),
          ListTile(
            leading: const Icon(Icons.history, size: 18),
            title: const Text('清除表达式历史'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () async {
              await SettingsService.instance.clearExpressionHistory();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已清除表达式历史')));
              }
            },
          ),
          const Divider(height: 1),

          // ── 缓存 ──
          const _SectionHeader('缓存'),
          ListTile(
            leading: const Icon(Icons.image_outlined, size: 18),
            title: const Text('内嵌封面缓存'),
            subtitle: FutureBuilder<int>(
              future: appState.getCoverCacheSizeBytes(),
              builder: (context, snap) => Text(
                '${_fmtMB(snap.data ?? 0)} MB',
                style: TextStyle(
                    fontSize: 11, color: AppColors.textSecondaryOf(context)),
              ),
            ),
          ),
          _cacheLimitTile(context, appState),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined, size: 18),
            title: const Text('清理封面缓存'),
            subtitle: const Text('删除内嵌封面缓存（可重新生成），保留自定义封面'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () async {
              final freed = await appState.clearCoverCache();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已清理，释放 ${_fmtMB(freed)} MB')));
              }
            },
          ),
          ListTile(
            key: const ValueKey('clear-thumbnail-cache'),
            leading: const Icon(Icons.photo_library_outlined, size: 18),
            title: const Text('清理缩略图缓存'),
            subtitle: const Text('删除磁盘上的全部缩略图文件，下次浏览时重新生成'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _clearThumbnailCache(context, appState),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              '封面缓存与缩略图缓存共用同一份上限配额，键为 settings.json 的 '
              'cover_cache_mb；0 表示不限制。',
              style: TextStyle(
                  fontSize: 11, color: AppColors.mutedOf(context), height: 1.4),
            ),
          ),
          const Divider(height: 1),

          // ── 数据 ──
          const _SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.folder_outlined, size: 18),
            title: const Text('数据目录'),
            subtitle: FutureBuilder<String>(
              future: appState.getDataDir(),
              builder: (context, snap) => Text(
                snap.data ?? '...',
                style: TextStyle(
                    fontSize: 11, color: AppColors.textSecondaryOf(context)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outlined, size: 18),
            title: const Text('迁移数据目录'),
            subtitle: const Text('把数据库、封面缓存、设置整体迁移到其它位置'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _migrateDataDir(context, appState),
          ),
          const Divider(height: 1),

          // ── 关于 ──
          const _SectionHeader('关于'),
          ListTile(
            key: const ValueKey('about-entry'),
            leading: const Icon(Icons.info_outline, size: 18),
            title: const Text('关于 AsmrShelf'),
            subtitle: const Text('版本、开源许可证、第三方声明、数据与日志目录'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AboutPage()),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── 主题：跟随系统 / 浅色 / 深色 ──
  Widget _themeSelector(BuildContext context, AppState appState) {
    Widget option(String key, String label, IconData icon, ThemeMode mode) {
      final selected = appState.themeMode == mode;
      final color =
          selected ? AppColors.accent : AppColors.mutedLightOf(context);
      return Expanded(
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(8),
          onTap: () => appState.setThemeMode(mode),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            option('theme-system', '跟随系统', Icons.brightness_auto,
                ThemeMode.system),
            option('theme-light', '浅色', Icons.light_mode, ThemeMode.light),
            option('theme-dark', '深色', Icons.dark_mode, ThemeMode.dark),
          ],
        ),
      ),
    );
  }

  // ── 字幕：非当前句的透明度，可以自动，也可以自己定 ──

  Widget _subtitleOpacityTile(BuildContext context, AppState appState) {
    final auto = appState.subtitleOpacityAuto;
    final track = appState.player.currentTrack;
    final cover = track == null ? null : appState.coverForTrack(track);
    final fixed = appState.subtitleInactiveOpacity;
    // 自动模式下列出当前曲目那张封面算出来的值，让用户看见调的是哪个数。
    return FutureBuilder<double?>(
      future: auto && cover != null
          ? SubtitleStyle.luminanceOfCover(cover)
          : Future<double?>.value(),
      builder: (context, snap) {
        final effective =
            auto ? SubtitleStyle.autoInactiveOpacity(snap.data) : fixed;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('非当前句的透明度',
                        style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textPrimaryOf(context))),
                  ),
                  Text(
                    '${(effective * 100).round()}%',
                    key: const ValueKey('subtitle-opacity-value'),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              Row(
                children: [
                  Switch(
                    key: const ValueKey('subtitle-opacity-auto'),
                    value: auto,
                    onChanged: (v) => appState.setSubtitleOpacityAuto(v),
                  ),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('subtitle-opacity-slider'),
                      value: auto ? effective : fixed,
                      min: SubtitleStyle.minInactiveOpacity,
                      max: SubtitleStyle.maxInactiveOpacity,
                      divisions: 14,
                      label: '${(effective * 100).round()}%',
                      onChanged: auto
                          ? null
                          : (v) => appState.setSubtitleInactiveOpacity(v),
                    ),
                  ),
                ],
              ),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceOf(context),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '不在当前句上的歌词就长这样',
                  key: const ValueKey('subtitle-opacity-preview'),
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: effective),
                      fontSize: 14),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                auto
                    ? '自动：按当前音轨封面（加了模糊滤镜的那张）的明暗算。'
                        '封面越亮，字越实；没有封面时用 '
                        '${(SubtitleStyle.defaultInactiveOpacity * 100).round()}%。'
                    : '固定：滑到别的句子上时用这个透明度。',
                style: TextStyle(
                    fontSize: 11,
                    color: AppColors.mutedOf(context),
                    height: 1.4),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── 字幕：滑动之后留在原地的秒数 ──

  Widget _subtitleResumeTile(BuildContext context, AppState appState) {
    final seconds = appState.subtitleResumeSeconds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('滑动后留在原地',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textPrimaryOf(context))),
              ),
              Text(
                '$seconds 秒',
                key: const ValueKey('subtitle-resume-value'),
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          Slider(
            key: const ValueKey('subtitle-resume-slider'),
            value: seconds.toDouble(),
            min: SettingsService.minSubtitleResumeSeconds.toDouble(),
            max: SettingsService.maxSubtitleResumeSeconds.toDouble(),
            divisions: SettingsService.maxSubtitleResumeSeconds -
                SettingsService.minSubtitleResumeSeconds,
            label: '$seconds 秒',
            onChanged: (v) => appState.setSubtitleResumeSeconds(v.round()),
          ),
          Text(
            '这段时间内不会自动回到正在播放的那一句，方便往回看。',
            style: TextStyle(
                fontSize: 11, color: AppColors.mutedOf(context), height: 1.4),
          ),
        ],
      ),
    );
  }

  // ── 网格列数（2..10，带数值与实时预览）──
  Widget _gridColumnsTile(BuildContext context, AppState appState) {
    return ListTile(
      leading: const Icon(Icons.grid_view, size: 18),
      title: Text('网格列数：${appState.gridColumns}'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            for (var i = 0; i < appState.gridColumns; i++)
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.35 + i * 0.05),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 6),
            Text(
              '${appState.gridColumns} 列',
              style: TextStyle(
                  fontSize: 11, color: AppColors.textSecondaryOf(context)),
            ),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('grid-columns-decrease'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            tooltip: '减少列数',
            onPressed: appState.gridColumns > 2
                ? () => appState.setGridColumns(appState.gridColumns - 1)
                : null,
          ),
          Text(
            '${appState.gridColumns}',
            key: const ValueKey('grid-columns-value'),
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600),
          ),
          IconButton(
            key: const ValueKey('grid-columns-increase'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline, size: 20),
            tooltip: '增加列数',
            onPressed: appState.gridColumns < 10
                ? () => appState.setGridColumns(appState.gridColumns + 1)
                : null,
          ),
        ],
      ),
    );
  }

  // ── 视图模式：网格 / 列表 ──
  Widget _viewModeTile(BuildContext context, AppState appState) {
    Widget option(String key, String label, IconData icon, String mode) {
      final selected = appState.viewMode == mode;
      final color = selected
          ? AppColors.accent
          : AppColors.textSecondaryOf(context);
      return Expanded(
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(8),
          onTap: () => appState.setViewMode(mode),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.15)
                  : AppColors.surfaceOf(context),
              border: Border.all(
                color: selected
                    ? AppColors.accent
                    : AppColors.surfaceAltOf(context),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('视图模式',
              style: TextStyle(
                  fontSize: 12, color: AppColors.textSecondaryOf(context))),
          const SizedBox(height: 8),
          Row(
            children: [
              option('view-mode-grid', '网格', Icons.grid_view, 'grid'),
              const SizedBox(width: 8),
              option('view-mode-list', '列表', Icons.view_list, 'list'),
            ],
          ),
        ],
      ),
    );
  }

  // ── 缓存上限（封面 + 缩略图共用 cover_cache_mb）──
  Widget _cacheLimitTile(BuildContext context, AppState appState) {
    final options = _cacheLimitOptions(appState.cacheSizeMB);
    return ListTile(
      leading: const Icon(Icons.tune, size: 18),
      title: const Text('缓存上限（封面 + 缩略图）'),
      subtitle: Text(
        appState.cacheSizeMB == 0 ? '当前不限制' : '当前 ${appState.cacheSizeMB} MB',
        style:
            TextStyle(fontSize: 11, color: AppColors.textSecondaryOf(context)),
      ),
      trailing: DropdownButton<int>(
        key: const ValueKey('cache-limit-dropdown'),
        value: appState.cacheSizeMB,
        underline: const SizedBox.shrink(),
        items: [
          for (final mb in options)
            DropdownMenuItem(value: mb, child: Text(_limitLabel(mb))),
        ],
        onChanged: (v) {
          if (v != null) appState.setCacheSizeMB(v);
        },
      ),
    );
  }

  /// 清空磁盘缩略图缓存 + 内存缓存，并让在屏卡片重新生成缩略图。
  Future<void> _clearThumbnailCache(
      BuildContext context, AppState appState) async {
    final service = ThumbnailService.instance;
    var removed = 0;
    try {
      // maxSizeMB 传 0：把所有文件都当作超限，逐个删掉。
      removed = await service.evictDiskCache(maxSizeMB: 0);
    } catch (e) {
      // 缓存目录没初始化或清理失败时，界面不能装作已经清干净。
      logWarn('Settings', '清理缩略图缓存失败: $e');
    }
    // 磁盘文件删了，内存里还有已经解码的 ui.Image（GPU 纹理）
    service.clearMemoryCache();
    appState.markThumbnailsCleared();
    if (context.mounted) {
      final failed = removed == 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed ? '缩略图缓存已清空（没有可删除的文件）' : '已清理缩略图缓存：$removed 个文件'),
      ));
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(text,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.accent)),
    );
  }
}

String _fmtMB(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);

/// 缓存上限下拉可选的 MB 值。
///
/// 基础档位保持原来的 128 / 256 / 512 / 1 GB / 2 GB / 不限制；历史设置里可能
/// 存着别的值（例如滑块写进来的 768），一并列出来，否则 DropdownButton 会因为
/// `value` 不在 items 里直接抛异常。
List<int> _cacheLimitOptions(int current) {
  final values = <int>[128, 256, 512, 1024, 2048];
  if (current != 0 && !values.contains(current)) values.add(current);
  values.sort();
  return [...values, 0];
}

String _limitLabel(int mb) {
  if (mb == 0) return '不限制';
  if (mb % 1024 == 0) return '${mb ~/ 1024} GB';
  return '$mb MB';
}

/// 迁移数据目录：选择新目录 → 确认 → 整体迁移 → 提示
Future<void> _migrateDataDir(BuildContext context, AppState appState) async {
  final dir = await pickDirectory(title: '选择新的数据目录');
  if (dir == null) return;
  if (!context.mounted) return;
  final ok = await confirmDialog(
    context,
    title: '迁移数据目录',
    content: '将把数据库、封面缓存、设置整体迁移到：\n$dir\n\n原目录会保留，不会删除。',
  );
  if (ok != true) return;
  try {
    await appState.migrateDataDir(dir);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('迁移失败：$e')));
    }
    return;
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('数据已迁移到：$dir')));
  }
}
