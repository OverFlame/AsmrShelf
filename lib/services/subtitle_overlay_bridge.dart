import 'package:flutter/services.dart';

/// 系统级常驻字幕窗口的桥。
///
/// Dart 只负责算出「当前一句 / 下一句」，窗口怎么画由 Windows runner 与
/// Android 的 overlay service 各自实现。
abstract class SubtitleOverlayBridge {
  Future<bool> hasPermission();

  /// Android 会跳到「显示在其他应用上层」授权页；授权后需要用户再点一次开关。
  Future<bool> requestPermission();

  Future<bool> show({
    required String current,
    required String next,
    required bool locked,
  });

  Future<void> update({required String current, required String next});

  Future<void> hide();

  Future<void> setLocked(bool locked);
}

/// 通过 MethodChannel 调原生窗口。
///
/// 桌面 Linux 没有实现这个通道，返回 false 即可，界面会提示当前平台不支持。
class MethodChannelSubtitleOverlayBridge implements SubtitleOverlayBridge {
  MethodChannelSubtitleOverlayBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('asmrshelf/subtitle_overlay');

  final MethodChannel _channel;

  Future<bool> _bool(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> hasPermission() => _bool('hasPermission');

  @override
  Future<bool> requestPermission() => _bool('requestPermission');

  @override
  Future<bool> show({
    required String current,
    required String next,
    required bool locked,
  }) => _bool('show', {'current': current, 'next': next, 'locked': locked});

  @override
  Future<void> update({required String current, required String next}) async {
    try {
      await _channel.invokeMethod<void>('update', {
        'current': current,
        'next': next,
      });
    } on MissingPluginException {
      // 当前平台没有实现，开关本身会先失败。
    } on PlatformException {
      // 窗口被系统回收时忽略，下一次 show 会重建。
    }
  }

  @override
  Future<void> hide() async {
    try {
      await _channel.invokeMethod<void>('hide');
    } on MissingPluginException {
      // 同上。
    } on PlatformException {
      // 同上。
    }
  }

  @override
  Future<void> setLocked(bool locked) async {
    try {
      await _channel.invokeMethod<void>('setLocked', locked);
    } on MissingPluginException {
      // 同上。
    } on PlatformException {
      // 同上。
    }
  }
}
