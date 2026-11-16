import 'package:flutter/services.dart';

/// Android 窗口安全标志：禁止截图和最近任务缩略图。
class SecureWindow {
  static const _channel = MethodChannel('horsebox/secure_window');

  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // 非 Android 平台没有这个通道。
    } catch (_) {
      // 安全标志失败不应影响主流程。
    }
  }
}
