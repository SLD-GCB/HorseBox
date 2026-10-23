import 'dart:io';

import 'package:flutter/services.dart';

/// 系统输入法的状态。
class SystemImeStatus {
  const SystemImeStatus({required this.enabled, required this.current});

  /// 用户有没有在系统设置里勾选 HorseBox 输入法。
  final bool enabled;

  /// 当前正在使用的输入法是不是它。
  final bool current;

  static const unavailable = SystemImeStatus(enabled: false, current: false);
}

/// 输入法本地的统计（剪贴板条数、学习条目数）。
class ImeStats {
  const ImeStats({
    required this.clipboard,
    required this.learned,
    this.hasVibrator = true,
    this.globalHaptic = true,
    this.amplitudeControl = false,
  });

  final int clipboard;
  final int learned;

  /// 设备诊断：有没有马达、系统触感是否开启、是否支持振幅控制。
  final bool hasVibrator;
  final bool globalHaptic;
  final bool amplitudeControl;

  static const empty = ImeStats(clipboard: 0, learned: 0);
}

/// 原生输入法（Kotlin）的桥：查询状态、跳转设置、同步偏好。
///
/// 输入法本身跑在系统的 IME 窗口里，拿不到 Flutter 的 AppState，
/// 所以设置页在保存时把配置推给原生，由 SharedPreferences 落盘。
class SystemIme {
  SystemIme._();

  static const _channel = MethodChannel('horsebox/ime');

  static bool get _supported => Platform.isAndroid;

  static Future<SystemImeStatus> status() async {
    if (!_supported) return SystemImeStatus.unavailable;
    try {
      final raw = await _channel.invokeMapMethod<String, bool>('status');
      return SystemImeStatus(
        enabled: raw?['enabled'] ?? false,
        current: raw?['current'] ?? false,
      );
    } catch (_) {
      return SystemImeStatus.unavailable;
    }
  }

  /// 跳到系统的「语言和输入法」页面，用户在那里勾选。
  static Future<void> openSettings() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('openSettings');
    } catch (_) {}
  }

  /// 弹出输入法选择器，用来切到/切走 HorseBox。
  static Future<void> showPicker() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('showPicker');
    } catch (_) {}
  }

  static Future<ImeStats> stats() async {
    if (!_supported) return ImeStats.empty;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('stats');
      return ImeStats(
        clipboard: (raw?['clipboard'] as num?)?.toInt() ?? 0,
        learned: (raw?['learned'] as num?)?.toInt() ?? 0,
        hasVibrator: raw?['hasVibrator'] as bool? ?? true,
        globalHaptic: raw?['globalHaptic'] as bool? ?? true,
        amplitudeControl: raw?['amplitudeControl'] as bool? ?? false,
      );
    } catch (_) {
      return ImeStats.empty;
    }
  }

  static Future<void> clearClipboard() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('clearClipboard');
    } catch (_) {}
  }

  /// 试一下当前的按键音 / 震动强度。
  static Future<void> preview() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('preview');
    } catch (_) {}
  }

  /// 打开系统的「触感反馈」开关；没授权时会跳到授权页并返回 false。
  static Future<bool> enableSystemHaptic() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('enableHaptic') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// App 内置键盘按键时调用，复用同一套声音/震动。
  static void tap() {
    if (!_supported) return;
    _channel.invokeMethod<void>('tap').catchError((Object _) {});
  }

  static Future<void> clearLearning() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('clearLearning');
    } catch (_) {}
  }

  static Future<void> configure({
    required bool chinese,
    required String layout,
    required bool fuzzy,
    required bool sentence,
    required int candidates,
    required int height,
    required double scale,
    required bool learn,
    required bool clipboard,
    required int accent,
    required String accentMode,
    required int accentColor,
    required String darkMode,
    required String themeMode,
    required bool sound,
    required bool vibrate,
    required int vibrateAmplitude,
    required bool autocorrect,
    required bool customPalette,
    required int bgColor,
    required int keyColor,
    required int textColor,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('configure', {
        'chinese': chinese,
        'layout': layout,
        'fuzzy': fuzzy,
        'sentence': sentence,
        'candidates': candidates,
        'height': height,
        'scale': scale,
        'learn': learn,
        'clipboard': clipboard,
        'accent': accent,
        'accentMode': accentMode,
        'accentColor': accentColor,
        'darkMode': darkMode,
        'themeMode': themeMode,
        'sound': sound,
        'vibrate': vibrate,
        'vibrateAmplitude': vibrateAmplitude,
        'autocorrect': autocorrect,
        'customPalette': customPalette,
        'paletteBg': bgColor,
        'paletteKey': keyColor,
        'paletteText': textColor,
      });
    } catch (_) {}
  }
}
