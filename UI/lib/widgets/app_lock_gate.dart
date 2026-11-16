import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/app_lock.dart';
import '../security/app_pin.dart';

/// App 级锁屏：启动、回前台或超时后，用系统验证或应用 PIN 解锁。
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.enabled,
    required this.timeoutSeconds,
    required this.method,
    required this.pinHash,
    required this.pinSalt,
    required this.child,
  });

  final bool enabled;
  final int timeoutSeconds;
  final String method;
  final String pinHash;
  final String pinSalt;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
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
    if (state == AppLifecycleState.inactive && Platform.isWindows) {
      // Windows 切到别的窗口通常只发 inactive，不发 paused。
      if (!_prompting) _pausedAt ??= DateTime.now();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (!_prompting) _pausedAt ??= DateTime.now();
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
    if (Platform.isWindows) return;
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
      if (ok && mounted) {
        _pausedAt = null;
        setState(() => _locked = false);
      }
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
              child: Platform.isWindows
                  ? _PinLockScreen(
                      pinHash: widget.pinHash,
                      pinSalt: widget.pinSalt,
                      onUnlocked: () {
                        _pausedAt = null;
                        setState(() => _locked = false);
                      },
                    )
                  : _LockScreen(onUnlock: () => _prompt(force: true)),
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
                  '使用系统指纹、人脸或密码解锁',
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

class _PinLockScreen extends StatefulWidget {
  const _PinLockScreen({
    required this.pinHash,
    required this.pinSalt,
    required this.onUnlocked,
  });

  final String pinHash;
  final String pinSalt;
  final VoidCallback onUnlocked;

  @override
  State<_PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<_PinLockScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _controller.text.trim();
    if (pin.length != AppPin.length) {
      setState(() => _error = '请输入 ${AppPin.length} 位 PIN');
      _focus.requestFocus();
      return;
    }
    if (AppPin.verify(pin, widget.pinSalt, widget.pinHash)) {
      widget.onUnlocked();
      return;
    }
    _controller.clear();
    setState(() => _error = 'PIN 错误');
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 52, color: scheme.primary),
                  const SizedBox(height: 16),
                  const Text(
                    'HorseBox 已锁定',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '输入应用 PIN',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _controller,
                    focusNode: _focus,
                    autofocus: true,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    maxLength: AppPin.length,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 22, letterSpacing: 10),
                    decoration: InputDecoration(
                      hintText: '● ● ● ● ● ●',
                      counterText: '',
                      errorText: _error,
                    ),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _submit,
                      child: const Text('解锁'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
