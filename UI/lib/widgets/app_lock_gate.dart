import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/app_lock.dart';

/// App 级锁屏：启动、回前台或超时后，用系统指纹/设备密码解锁。
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.enabled,
    required this.timeoutSeconds,
    required this.method,
    required this.child,
  });

  final bool enabled;
  final int timeoutSeconds;
  final String method;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  bool _locked = false;
  bool _prompting = false;
  DateTime? _pausedAt;
  DateTime? _lastPromptAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _locked = widget.enabled;
    if (_locked) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _prompt());
    }
  }

  @override
  void didUpdateWidget(covariant AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _locked = false;
      return;
    }
    if (!oldWidget.enabled && widget.enabled) {
      // 开启时刚刚验证过一次，本次会话不再重复要求验证。
      _locked = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.enabled) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pausedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null) return;
    final elapsed = DateTime.now().difference(pausedAt).inSeconds;
    if (_locked || elapsed >= widget.timeoutSeconds) {
      setState(() => _locked = true);
      unawaited(_prompt());
    }
  }

  Future<void> _prompt({bool force = false}) async {
    if (!widget.enabled || !_locked || _prompting) return;
    final last = _lastPromptAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _prompting = true;
    _lastPromptAt = DateTime.now();
    try {
      final ok = await AppLockService.authenticate(method: widget.method);
      if (ok && mounted) setState(() => _locked = false);
    } finally {
      _prompting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_locked,
      child: Stack(
        children: [
          widget.child,
          if (_locked)
            Positioned.fill(
              child: _LockScreen(
                onUnlock: () => _prompt(force: true),
              ),
            ),
        ],
      ),
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 56, color: scheme.primary),
                const SizedBox(height: 18),
                const Text(
                  'HorseBox 已锁定',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  '使用手机指纹或设备密码解锁',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 26),
                FilledButton.icon(
                  onPressed: onUnlock,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('解锁'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
