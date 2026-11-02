import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/data_dir_service.dart';
import '../services/video_launcher.dart';
import '../theme/app_theme.dart';

/// 关于页。
///
/// 内容从 PictureViewer2 的 about_page.dart 并入，配色改成本仓库的
/// [AppColors]，并补上许可证、第三方声明与数据/日志目录入口。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.launcher});

  /// 打开目录用的启动器。测试注入假实现，避免真的拉起文件管理器。
  final VideoLauncher? launcher;

  static const String appName = 'AsmrShelf';

  /// 版本号与 pubspec.yaml 的 `version:` 手工保持同步。
  ///
  /// 本仓库没有引入 package_info_plus（不加依赖），也没有把 pubspec.yaml 打进
  /// 资源，运行时读不到它，所以这里写死常量。改 pubspec.yaml 的 version 时，
  /// 必须同步改这一行。
  /// pubspec.yaml:19 → `version: 0.1.0+1`
  static const String appVersion = '0.1.0';
  static const String appBuildNumber = '1';

  /// 第三方开源声明文件名（仓库根目录，不随应用包分发）。
  static const String noticesFileName = 'THIRD_PARTY_NOTICES.md';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          _header(context),
          const SizedBox(height: 8),
          _description(context),
          const SizedBox(height: 12),
          _dlsiteNotice(context),
          const SizedBox(height: 20),
          const Divider(height: 1),
          _infoRow(context, '应用', appName),
          _infoRow(context, '版本', 'v$appVersion+$appBuildNumber'),
          _infoRow(context, '框架', 'Flutter'),
          _infoRow(context, '数据库', 'SQLite (sqflite)'),
          _infoRow(context, '开发语言', 'Dart'),
          _infoRow(context, '平台', 'Windows / Linux / Android'),
          const Divider(height: 1),

          // ── 许可证与声明 ──
          ListTile(
            key: const ValueKey('about-licenses'),
            leading: const Icon(Icons.article_outlined, size: 18),
            title: const Text('开源许可证'),
            subtitle: const Text('查看 Flutter 与所有依赖包的许可证全文'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => showLicensePage(
              context: context,
              applicationName: appName,
              applicationVersion: 'v$appVersion+$appBuildNumber',
              applicationLegalese: 'AsmrShelf — 本地媒体库',
            ),
          ),
          ListTile(
            key: const ValueKey('about-third-party'),
            leading: const Icon(Icons.verified_outlined, size: 18),
            title: const Text('第三方开源声明'),
            subtitle: const Text('THIRD_PARTY_NOTICES.md'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _showThirdPartyNotices(context),
          ),
          const Divider(height: 1),

          // ── 目录 ──
          _dirTile(
            context,
            key: 'about-data-dir',
            icon: Icons.folder_outlined,
            title: '数据目录',
            hint: '数据库、封面、缩略图与设置文件',
          ),
          _dirTile(
            context,
            key: 'about-log-dir',
            icon: Icons.description_outlined,
            title: '日志目录',
            hint: '运行日志导出的落点',
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(
            Icons.perm_media_outlined,
            size: 36,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          appName,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimaryOf(context),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'v$appVersion+$appBuildNumber',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.mutedLightOf(context),
          ),
        ),
      ],
    );
  }

  Widget _description(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        '本地音声库：以作品为单位管理音频，\n'
        '支持导入、标签、续播、DLsite 元数据与数据目录迁移。',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          color: AppColors.textSecondaryOf(context),
          height: 1.5,
        ),
      ),
    );
  }

  /// DLsite 元数据来自非官方接口，这一条按剥离指南放在关于页，别删。
  Widget _dlsiteNotice(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Text(
        'DLsite 元数据来自公开网页的非官方接口，不保证长期可用；'
        '应用不打包 DLsite 图片，也不抓取付费内容。',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          color: AppColors.mutedLightOf(context),
          height: 1.5,
        ),
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.mutedLightOf(context),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textPrimaryOf(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 目录条目：先解析出真实路径，再交给系统文件管理器打开。
  Widget _dirTile(
    BuildContext context, {
    required String key,
    required IconData icon,
    required String title,
    required String hint,
  }) {
    final isLog = key == 'about-log-dir';
    return ListTile(
      key: ValueKey(key),
      leading: Icon(icon, size: 18),
      title: Text(title),
      subtitle: FutureBuilder<String>(
        future: _resolveDir(context, log: isLog),
        builder: (context, snap) => Text(
          snap.data == null ? '$hint\n...' : '$hint\n${snap.data}',
          style: TextStyle(
            fontSize: 11,
            color: AppColors.textSecondaryOf(context),
          ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => _openDir(context, log: isLog),
    );
  }

  /// 数据目录来自 [DataDirService]；日志目录是数据目录下的 `logs/`。
  ///
  /// 运行期日志由 [LogUtil.attachFileSink] 落到 `logs/app-<日期>.log`，
  /// 目录在启动流程里已建好；这里再建一次只是防用户手删后打不开。
  Future<String> _resolveDir(BuildContext context, {required bool log}) async {
    final dataDir = await DataDirService.instance.dataDir;
    if (!log) return dataDir;
    final logDir = p.join(dataDir, 'logs');
    await Directory(logDir).create(recursive: true);
    return logDir;
  }

  Future<void> _openDir(BuildContext context, {required bool log}) async {
    final String dir;
    try {
      dir = await _resolveDir(context, log: log);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('目录不可用：$e')));
      }
      return;
    }
    final result = await (launcher ?? VideoLauncher()).open(dir);
    if (!context.mounted) return;
    final msg = switch (result) {
      LaunchResult.ok => '已用系统文件管理器打开：$dir',
      LaunchResult.unsupportedPlatform => '当前平台不支持打开目录：$dir',
      LaunchResult.failed => '打开目录失败：$dir',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 第三方声明：仓库根目录的 [noticesFileName] 不随应用包分发，所以先给出
  /// 指向说明，能在磁盘上找到时才提供「打开文件」。
  Future<void> _showThirdPartyNotices(BuildContext context) async {
    final file = _locateNoticesFile();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('第三方开源声明'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本应用使用的第三方开源组件及其许可证与版权声明，收录在源码根目录的 '
              '$noticesFileName。',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondaryOf(ctx),
                height: 1.4,
              ),
            ),
            if (file != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                file.path,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.mutedLightOf(ctx),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          if (file != null)
            FilledButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(ctx);
                final result = await (launcher ?? VideoLauncher()).open(
                  file.path,
                );
                final msg = result == LaunchResult.ok
                    ? '已用系统默认程序打开 $noticesFileName'
                    : '打开 $noticesFileName 失败';
                messenger.showSnackBar(SnackBar(content: Text(msg)));
              },
              child: const Text('打开文件'),
            ),
        ],
      ),
    );
  }

  /// 找 [noticesFileName]：先看当前工作目录，再看可执行文件所在目录。
  File? _locateNoticesFile() {
    final candidates = <String>[
      p.join(Directory.current.path, noticesFileName),
      p.join(File(Platform.resolvedExecutable).parent.path, noticesFileName),
    ];
    for (final path in candidates) {
      final f = File(path);
      if (f.existsSync()) return f;
    }
    return null;
  }
}
