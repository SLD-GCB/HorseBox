import 'package:flutter/material.dart';

import '../platform/app_lock.dart';
import '../state/app_state.dart';
import '../widgets/section.dart';

/// 应用锁：用系统指纹或设备密码保护 HorseBox 界面。
class SettingsSecurityPage extends StatefulWidget {
  const SettingsSecurityPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsSecurityPage> createState() => _SettingsSecurityPageState();
}

class _SettingsSecurityPageState extends State<SettingsSecurityPage> {
  AppLockMethods _methods = const AppLockMethods();
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    AppLockService.methods().then((value) {
      if (mounted) {
        setState(() {
          _methods = value;
          _loaded = true;
        });
      }
    });
  }

  bool get _available => _methods.any;

  Future<void> _setEnabled(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await AppLockService.authenticate(
        method: widget.state.settings.appLockMethod,
      );
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('没有通过验证，应用锁未修改')));
        }
        return;
      }
      await widget.state.updateSettings(
        widget.state.settings.copyWith(appLock: enabled),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setMethod(String method) async {
    await widget.state.updateSettings(
      widget.state.settings.copyWith(appLockMethod: method),
    );
  }

  Future<void> _setTimeout(int seconds) async {
    await widget.state.updateSettings(
      widget.state.settings.copyWith(appLockTimeout: seconds),
    );
  }

  String _methodLabel(String method) {
    return switch (method) {
      'biometric' => '仅指纹 / 人脸',
      'credential' => '仅设备密码',
      _ => '指纹 / 人脸 + 设备密码',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final settings = widget.state.settings;
        final options = <String>[];
        if (_methods.biometric && _methods.credential) options.add('both');
        if (_methods.biometric) options.add('biometric');
        if (_methods.credential) options.add('credential');
        final selected = options.contains(settings.appLockMethod)
            ? settings.appLockMethod
            : options.isEmpty
            ? ''
            : options.first;
        final biometricLabel = _methods.fingerprint && _methods.face
            ? '指纹 / 人脸'
            : _methods.fingerprint
            ? '指纹'
            : _methods.face
            ? '人脸'
            : '生物识别';
        return Scaffold(
          appBar: AppBar(title: const Text('应用锁')),
          body: DefaultTextStyle.merge(
            style: const TextStyle(
              decoration: TextDecoration.none,
              decorationColor: Colors.transparent,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - 48).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionCard(
                        child: Column(
                          children: [
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              value: settings.appLock,
                              onChanged: _loaded && _available && !_busy
                                  ? _setEnabled
                                  : null,
                              title: const Text('应用锁'),
                              subtitle: Text(
                                !_loaded
                                    ? '正在检测设备解锁方式…'
                                    : !_available
                                    ? '这台手机没有设置锁屏密码，无法启用应用锁'
                                    : '打开或回到前台时，用下面选择的方式解锁',
                              ),
                            ),
                            const Divider(height: 20),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '设备支持的解锁方式',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (!_loaded)
                                    Text(
                                      '正在检测…',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    )
                                  else if (options.isEmpty)
                                    Text(
                                      '没有可用的解锁方式',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.error,
                                      ),
                                    )
                                  else ...[
                                    if (_methods.biometric)
                                      Text(
                                        '· $biometricLabel',
                                        style: const TextStyle(fontSize: 12.5),
                                      ),
                                    if (_methods.credential)
                                      const Text(
                                        '· 设备密码 / PIN / 图案',
                                        style: TextStyle(fontSize: 12.5),
                                      ),
                                  ],
                                  const SizedBox(height: 14),
                                  const Text(
                                    '选择解锁方式',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: scheme.outlineVariant,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        isExpanded: true,
                                        value: selected.isEmpty
                                            ? null
                                            : selected,
                                        hint: const Text('请选择'),
                                        items: [
                                          for (final item in options)
                                            DropdownMenuItem(
                                              value: item,
                                              child: Text(_methodLabel(item)),
                                            ),
                                        ],
                                        onChanged: options.isNotEmpty && !_busy
                                            ? (value) {
                                                if (value != null)
                                                  _setMethod(value);
                                              }
                                            : null,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 20),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('自动锁定'),
                              subtitle: const Text('离开 App 超过这个时间后重新锁定'),
                              trailing: DropdownButton<int>(
                                value: settings.appLockTimeout,
                                underline: const SizedBox.shrink(),
                                items: const [
                                  DropdownMenuItem(value: 0, child: Text('立即')),
                                  DropdownMenuItem(
                                    value: 30,
                                    child: Text('30 秒'),
                                  ),
                                  DropdownMenuItem(
                                    value: 60,
                                    child: Text('1 分钟'),
                                  ),
                                  DropdownMenuItem(
                                    value: 300,
                                    child: Text('5 分钟'),
                                  ),
                                ],
                                onChanged: settings.appLock && !_busy
                                    ? (value) {
                                        if (value != null) _setTimeout(value);
                                      }
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '应用锁只保护 HorseBox 界面，不影响 VPN、后台代理和通知。'
                        'Root、调试或系统级木马不受此限制。',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
