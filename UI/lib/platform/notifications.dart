import 'package:flutter/services.dart';

/// 系统通知：Android 走原生 NotificationManager；其他平台静默忽略。
class AppNotifications {
  static const _channel = MethodChannel('horsebox/notify');

  static Future<void> show(String title, String body) async {
    try {
      await _channel.invokeMethod('show', {'title': title, 'body': body});
    } catch (_) {
      // 桌面/旧系统没有通道时不影响业务。
    }
  }
}
