import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/dlsite/dlsite_cover.dart';
import '../state/app_state.dart';
import 'dlsite_preview_dialog.dart';

/// 作品级的两个动作：抓 DLsite 元数据、从文件里找封面。
///
/// 放在独立文件里是因为两个工具条都要用：作品层（[FolderBrowser]）与
/// 首页工具条。以前它们只写在首页工具条里，而首页工具条只在「没进作品」
/// 时渲染，条件互斥，按钮实际点不到。

/// 从作品目录里找一张图作为封面，并把结果说清楚。
Future<void> findLocalCoverForCurrentWork(BuildContext context) async {
  final appState = context.read<AppState>();
  final workId = appState.currentWork?.id;
  if (workId == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final message = await appState.findLocalCoverForWork(workId);
  if (!context.mounted) return;
  messenger.showSnackBar(SnackBar(content: Text(message ?? '封面已写入作品目录')));
}

/// 按作品目录名里的编号抓一次 DLsite 元数据。
///
/// 抓不到时把原因原样弹给用户（没有编号、被限制、网络不通），不做静默失败。
Future<void> fetchDlsiteForCurrentWork(BuildContext context) async {
  final appState = context.read<AppState>();
  final workId = appState.currentWork?.id;
  if (workId == null) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
      content: Text('正在抓取 DLsite 元数据…'),
      duration: Duration(minutes: 1),
    ),
  );
  final result = await appState.previewDlsiteMetadata(workId);
  messenger.hideCurrentSnackBar();
  if (!context.mounted) return;
  final work = result.work;
  if (work == null) {
    messenger.showSnackBar(SnackBar(content: Text(result.message)));
    return;
  }
  final choice = await showDlsitePreviewDialog(
    context,
    work: work,
    fromCache: result.fromCache,
  );
  if (choice == null || !context.mounted) return;
  final applied = await appState.applyDlsiteMetadata(
    workId,
    work,
    applyCover: choice.applyCover,
  );
  var coverNote = '';
  if (choice.applyCover && work.cover != null) {
    try {
      await appState.downloadDlsiteCover(workId, work.cover!.url);
    } on DlsiteImageException catch (e) {
      coverNote = '；封面没换：${e.message}';
    }
  }
  if (!context.mounted) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        '已应用 ${work.workNo} 的元数据'
        '${applied.grantedTags > 0 ? '，新增 ${applied.grantedTags} 个标签' : ''}'
        '$coverNote',
      ),
    ),
  );
}
