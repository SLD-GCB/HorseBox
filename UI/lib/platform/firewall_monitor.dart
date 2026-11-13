import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

/// 把 IP 养护目标同步给 Android 原生后台任务。
/// 原生端负责按 15 分钟最小周期检查防火墙和 IP 养护状态。
class FirewallMonitorChannel {
  static const _channel = MethodChannel('horsebox/firewall_monitor');

  static Future<void> sync(List<IpCareTarget> targets) async {
    final config = [
      for (final target in targets)
        {
          'name': target.name,
          'url': target.url,
          'pin': normalizePin(target.pin),
          'token': target.token.trim(),
        },
    ];
    try {
      await _channel.invokeMethod<void>('sync', {
        'config': jsonEncode(config),
      });
    } on MissingPluginException {
      // Windows / 旧系统没有原生后台任务，忽略。
    } catch (_) {
      // 后台任务不可用不应影响客户端主流程。
    }
  }
}
