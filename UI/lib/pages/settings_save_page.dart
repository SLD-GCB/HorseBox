import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/section.dart';

/// 保存设置：把当前所有设置显式写盘一次。
///
/// 平时改任何一项都会立即存盘，这一页是给"想确认一次"的场景用的：
/// 它会把内存里的设置整份刷到 settings.json，并同步给系统输入法。
class SettingsSavePage extends StatefulWidget {
  const SettingsSavePage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsSavePage> createState() => _SettingsSavePageState();
}

class _SettingsSavePageState extends State<SettingsSavePage> {
  bool _saving = false;
  DateTime? _savedAt;

  AppState get state => widget.state;

  String get _themeLabel {
    final mode = switch (state.settings.themeMode) {
      'light' => '浅色',
      'system' => '跟随系统',
      _ => '深色',
    };
    final hex = state.settings.accent.toRadixString(16).padLeft(8, '0');
    return '$mode · #${hex.substring(2).toUpperCase()}';
  }

  String get _keyboardLabel {
    final s = state.settings;
    final lang = s.imeChinese ? '中文' : '英文';
    final layout = s.imeLayout == 'nine' ? '九宫格' : '全键盘';
    final script = s.imeAccentMode == 'system' ? '跟随系统' : '自定义';
    return '$lang · $layout · 配色$script';
  }

  String get _timeLabel {
    final at = _savedAt;
    if (at == null) return '还没有手动保存过';
    String two(int v) => v.toString().padLeft(2, '0');
    return '上次保存：${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await state.updateSettings(state.settings);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _savedAt = DateTime.now();
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('所有设置已保存')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final s = state.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('保存设置')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
            children: [
              const SectionLabel('将要保存的内容'),
              SectionCard(
                child: Column(
                  children: [
                    _row('订阅', '${state.profiles.length} 条'),
                    const Divider(height: 18),
                    _row('SSH 主机', '${state.sshHosts.length} 台'),
                    const Divider(height: 18),
                    _row('密码本', '${state.credentials.length} 条'),
                    const Divider(height: 18),
                    _row('自定义规则', '${s.customRules.length} 条'),
                    const Divider(height: 18),
                    _row('主题', _themeLabel),
                    const Divider(height: 18),
                    _row(
                      '代理',
                      "端口 ${s.mixedPort} · ${s.dnsMode == 'custom' ? '自定义 DNS' : '面板 DNS'}",
                    ),
                    const Divider(height: 18),
                    _row('输入法', _keyboardLabel),
                    const Divider(height: 18),
                    _row('内置键盘', s.imeBuiltin ? '开启' : '关闭'),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '平时改任何一项都会立即写盘；这里是强制再刷一次，'
                      '把内存里的设置整份写进 settings.json，并同步给系统输入法。',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _timeLabel,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_outlined, size: 18),
                        label: Text(_saving ? '保存中…' : '保存所有设置'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SectionLabel('数据目录'),
              SectionCard(
                child: SelectableText(
                  state.dataDir,
                  style: HorseBoxTheme.mono(context, size: 11.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ),
        Text(value, style: const TextStyle(fontSize: 12.5)),
      ],
    );
  }
}
