import 'package:flutter/material.dart';

import '../services/video_launcher.dart';

/// 外链播放结果的统一提示
void showLaunchResult(BuildContext context, LaunchResult result) {
  final msg = switch (result) {
    LaunchResult.ok => '已交给系统默认播放器',
    LaunchResult.unsupportedPlatform => '当前平台不支持外链播放',
    LaunchResult.failed => '外链播放失败，详情见 logs 目录',
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(fontSize: 13)),
    duration: const Duration(seconds: 3),
  ));
}
