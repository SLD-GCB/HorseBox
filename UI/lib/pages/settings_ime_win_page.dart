import 'package:flutter/material.dart';

import '../platform/ime_win.dart';
import '../widgets/section.dart';

/// Windows 输入法：安装/启停 + Windows 专用选项。
class SettingsImeWinPage extends StatefulWidget {
  const SettingsImeWinPage({super.key});

  @override
  State<SettingsImeWinPage> createState() => _SettingsImeWinPageState();
}

class _SettingsImeWinPageState extends State<SettingsImeWinPage> {
  ImeWinStatus _status = ImeWinStatus.unavailable;
  ImeWinConfig _config = const ImeWinConfig();
  bool _busy = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _config = ImeWin.readConfig();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await ImeWin.status();
    if (!mounted) return;
    setState(() {
      _status = s;
    });
  }

  Future<void> _act(Future<bool> Function() fn, String ok, String fail) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    final r = await fn();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msg = r ? ok : fail;
    });
    await _refresh();
  }

  Future<void> _saveConfig(ImeWinConfig c) async {
    setState(() => _config = c);
    await ImeWin.writeConfig(c);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存，切换一次输入法后生效')),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Text(value,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final packaged = _status.packaged;
    final installText = !packaged
        ? '输入法文件缺失'
        : (_status.registered ? '已安装' : '未注册');
    return Scaffold(
      appBar: AppBar(title: const Text('内置输入法（Windows）')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          const SectionLabel('系统输入法'),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _row('文件', packaged ? '已随程序分发' : '缺少 ime 目录'),
                _row('安装', installText),
                _row('启用', _status.enabled ? '已启用（语言列表）' : '未启用'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy || !packaged
                          ? null
                          : () => _act(ImeWin.install, '注册成功',
                              '注册失败（需要管理员确认）'),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('安装 / 修复'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !packaged
                          ? null
                          : () => _act(ImeWin.uninstall, '已卸载', '卸载失败'),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('卸载'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !packaged
                          ? null
                          : () => _act(ImeWin.enable, '已启用', '启用失败'),
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('启用'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !packaged
                          ? null
                          : () => _act(ImeWin.disable, '已禁用', '禁用失败'),
                      icon: const Icon(Icons.cancel_outlined, size: 18),
                      label: const Text('禁用'),
                    ),
                    TextButton.icon(
                      onPressed: ImeWin.openLanguageSettings,
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      label: const Text('系统语言设置'),
                    ),
                  ],
                ),
                if (_msg != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_msg!,
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
              ],
            ),
          ),
          const SectionLabel('Windows 专用选项'),
          SectionCard(
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('候选数量'),
                  subtitle: const Text('候选窗最多显示几个词'),
                  trailing: DropdownButton<int>(
                    value: _config.candidates.clamp(3, 9),
                    items: [
                      for (var i = 3; i <= 9; i++)
                        DropdownMenuItem(value: i, child: Text('$i')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      _saveConfig(ImeWinConfig(
                        candidates: v,
                        traditional: _config.traditional,
                        theme: _config.theme,
                      ));
                    },
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('繁体输出'),
                  subtitle: const Text('候选与上屏转成繁体'),
                  value: _config.traditional,
                  onChanged: (v) => _saveConfig(ImeWinConfig(
                    candidates: _config.candidates,
                    traditional: v,
                    theme: _config.theme,
                  )),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('候选窗主题'),
                  trailing: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'light', label: Text('浅色')),
                      ButtonSegment(value: 'dark', label: Text('深色')),
                    ],
                    selected: {_config.theme},
                    onSelectionChanged: (s) => _saveConfig(ImeWinConfig(
                      candidates: _config.candidates,
                      traditional: _config.traditional,
                      theme: s.first,
                    )),
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('数据'),
          SectionCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('清空学习记录'),
              subtitle: const Text('删除词频记忆，候选恢复默认排序'),
              trailing: TextButton(
                onPressed: () async {
                  await ImeWin.clearLearning();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已清空学习记录')),
                  );
                },
                child: const Text('清空'),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 4, 0),
            child: Text(
              '提示：选项保存后，切换到别的输入法再切回来（或重开当前程序）才会生效。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
