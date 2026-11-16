import 'package:flutter/services.dart';

/// 当前设备可用的解锁方式。
class AppLockMethods {
  const AppLockMethods({
    this.biometric = false,
    this.fingerprint = false,
    this.face = false,
    this.credential = false,
  });

  final bool biometric;
  final bool fingerprint;
  final bool face;
  final bool credential;

  bool get any => biometric || credential;

  factory AppLockMethods.fromJson(Object? raw) {
    if (raw is! Map) return const AppLockMethods();
    return AppLockMethods(
      biometric: raw['biometric'] == true,
      fingerprint: raw['fingerprint'] == true,
      face: raw['face'] == true,
      credential: raw['credential'] == true,
    );
  }
}

/// Android 系统指纹/人脸/设备密码验证（AndroidX Biometric）。
class AppLockService {
  static const _channel = MethodChannel('horsebox/app_lock');

  static Future<AppLockMethods> methods() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('available');
      if (raw is bool) {
        return AppLockMethods(biometric: raw, credential: raw);
      }
      return AppLockMethods.fromJson(raw);
    } on MissingPluginException {
      return const AppLockMethods();
    } catch (_) {
      return const AppLockMethods();
    }
  }

  static Future<bool> authenticate({String method = 'both'}) async {
    try {
      return await _channel.invokeMethod<bool>('authenticate', {
            'method': method,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
