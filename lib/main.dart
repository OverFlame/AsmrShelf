import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'db/database.dart';
import 'pages/home_page.dart';
import 'services/data_dir_service.dart';
import 'services/media_bridge.dart';
import 'services/migration_guard.dart';
import 'services/settings_service.dart';
import 'state/app_state.dart';
import 'state/player_controller.dart';
import 'theme/app_theme.dart';
import 'utils/log_util.dart';
import 'widgets/startup_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 捕获未处理异常，避免启动失败时直接白屏
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    logError('FlutterError', details.exceptionAsString(), details.stack?.toString());
  };

  try {
    await DataDirService.instance.init();
    // 界面提示「详情见 logs 目录」，启动时就把文件 sink 挂上，
    // 否则用户按提示去找，目录永远是空的。
    LogUtil.attachFileSink(
        p.join(await DataDirService.instance.dataDir, 'logs'));
    await SettingsService.instance.init();

    // 结构升级会删表重建。先备份，再让用户确认；没确认就不开库。
    final plan = await MigrationGuard.instance.inspect();
    if (plan != null) {
      final backup = await MigrationGuard.instance.backup(plan);
      await _resolveUpgrade(backup);
    }

    await DatabaseManager.instance.init();

    final player = PlayerController();
    final appState = AppState(player: player);
    await appState.init();

    await MediaBridge.instance.init(player, appState);
    unawaited(MediaBridge.instance.ensureNotificationPermission());

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: appState),
          ChangeNotifierProvider.value(value: player),
        ],
        child: const AsmrShelfApp(),
      ),
    );
  } catch (e, st) {
    logError('Main', '启动失败', '$e\n$st');
    runApp(_ErrorApp(message: '$e'));
  }
}

/// 升级确认循环：确认后继续启动；取消后停在取消页，点「重试」回到确认页。
Future<void> _resolveUpgrade(MigrationBackup backup) async {
  final backups = await MigrationGuard.instance.listBackups();
  while (true) {
    final confirmed = await _confirmRebuild(backup, backups);
    if (confirmed) return;
    await _waitForRetry(backup, backups);
  }
}

/// 用确认页承接用户选择：确认后返回 true，取消返回 false。
///
/// 这里先 runApp 一个临时页面，等用户点完再决定是否继续启动。
Future<bool> _confirmRebuild(
    MigrationBackup backup, List<BackupEntry> backups) {
  final result = Completer<bool>();
  runApp(_gateApp(MigrationConfirmPage(
    backup: backup,
    backups: backups,
    onRestore: MigrationGuard.instance.restore,
    onResult: (value) {
      if (!result.isCompleted) result.complete(value);
    },
  )));
  return result.future;
}

/// 停在取消页，等用户点「重试」。
Future<void> _waitForRetry(
    MigrationBackup backup, List<BackupEntry> backups) {
  final retry = Completer<void>();
  runApp(_gateApp(MigrationCancelledPage(
    backup: backup,
    backups: backups,
    onRestore: MigrationGuard.instance.restore,
    onRetry: () {
      if (!retry.isCompleted) retry.complete();
    },
  )));
  return retry.future;
}

/// 守卫页的外壳：主题与本地化跟主界面一致。
MaterialApp _gateApp(Widget home) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppColors.lightThemeData,
    darkTheme: AppColors.darkThemeData,
    themeMode: ThemeMode.system,
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: appSupportedLocales,
    home: home,
  );
}

/// 系统自带文案（返回、复制、取消等）的本地化配置，[AsmrShelfApp] 用这套。
const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates =
    <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// 界面文案以中文为主，英文兜底。
const List<Locale> appSupportedLocales = <Locale>[Locale('zh'), Locale('en')];

class AsmrShelfApp extends StatelessWidget {
  const AsmrShelfApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<AppState>().themeMode;
    return MaterialApp(
      title: 'AsmrShelf',
      debugShowCheckedModeBanner: false,
      theme: AppColors.lightThemeData,
      darkTheme: AppColors.darkThemeData,
      themeMode: themeMode,
      // 不加这段的话，返回、复制、取消这些系统自带的提示一律是英文
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: appSupportedLocales,
      home: const HomePage(),
    );
  }
}

/// 启动失败时显示的页面，替代白屏，便于定位问题
class _ErrorApp extends StatelessWidget {
  final String message;
  const _ErrorApp({required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(
              '启动失败：\n\n$message\n\n'
              '详情见应用数据目录下的 logs/ 文件夹'
              '（启动失败发生在数据目录就绪之前时，只有控制台输出）。',
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
