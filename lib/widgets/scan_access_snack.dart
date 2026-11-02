import 'package:flutter/material.dart';

import '../services/media_bridge.dart';

/// 导入前核对「所有文件访问」（BUILD_GUIDE 第 6.4 节）。
///
/// Android 11 以上要拿到这个授权才能遍历本地目录。没有授权时跳到系统设置页，
/// 弹一句提示并返回 false，调用方直接收手。桌面端恒为 true，不弹任何东西。
///
/// 返回 false 表示这次导入不该继续：
/// ```dart
/// if (!await ensureScanAccessOrPrompt(context)) return;
/// ```
Future<bool> ensureScanAccessOrPrompt(BuildContext context) async {
  if (await MediaBridge.instance.ensureScanAccess()) return true;
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('请在系统设置中授予「所有文件访问」权限后重试',
          style: TextStyle(fontSize: 13)),
      duration: Duration(seconds: 4),
    ));
  }
  return false;
}
