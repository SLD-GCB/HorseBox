import 'dart:async';

import 'package:flutter/services.dart';

/// Android VpnService 通道。
class VpnChannel {
  static const _method = MethodChannel('horsebox/vpn');
  static const _event = EventChannel('horsebox/vpn/state');

  /// 应用私有目录（Android 上不能靠环境变量拿）。
  Future<String> filesDir() async {
    final dir = await _method.invokeMethod<String>('filesDir');
    if (dir == null || dir.isEmpty) {
      throw PlatformException(code: 'no_dir', message: '无法获取应用私有目录');
    }
    return dir;
  }

  /// 申请 VPN 授权；用户拒绝返回 false。
  Future<bool> prepare() async {
    final granted = await _method.invokeMethod<bool>('prepare');
    return granted ?? false;
  }

  /// 申请通知权限；Android 13 以下或已授权直接返回 true。
  Future<bool> ensureNotificationPermission() async {
    final granted = await _method.invokeMethod<bool>('ensureNotification');
    return granted ?? false;
  }

  Future<void> openNotificationSettings() =>
      _method.invokeMethod<void>('openNotificationSettings');

  Future<bool> isIgnoringBattery() async {
    final value = await _method.invokeMethod<bool>('isIgnoringBattery');
    return value ?? false;
  }

  Future<void> openBatterySettings() =>
      _method.invokeMethod<void>('openBatterySettings');

  Future<void> start({
    required String config,
    required int clashPort,
    List<String> allowedPackages = const [],
    List<String> directPackages = const [],
  }) {
    return _method.invokeMethod<void>('start', {
      'config': config,
      'clashPort': clashPort,
      'allowedPackages': allowedPackages,
      'directPackages': directPackages,
    });
  }

  /// 用户安装的应用（系统应用不在列表里）。
  Future<List<AppEntry>> listUserApps() async {
    final raw = await _method.invokeMethod<List<dynamic>>('listUserApps');
    if (raw == null) return const [];
    return raw
        .whereType<Map>()
        .map(
          (item) => AppEntry(
            package: item['package'] as String? ?? '',
            label: item['label'] as String? ?? '',
          ),
        )
        .where((item) => item.package.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> stop() => _method.invokeMethod<void>('stop');

  /// 服务运行状态，异常停止时会推送 false。
  Stream<bool> get state => _event
      .receiveBroadcastStream()
      .map((event) => event == true)
      .handleError((Object _) {});
}

/// 一个用户安装的应用。
class AppEntry {
  const AppEntry({required this.package, required this.label});

  final String package;
  final String label;
}
