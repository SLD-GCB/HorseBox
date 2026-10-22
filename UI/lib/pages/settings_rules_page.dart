import 'dart:io';

import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../platform/vpn_channel.dart';
import '../state/app_state.dart';
import '../widgets/section.dart';
import 'rule_dialogs.dart';

/// 代理规则：分流规则 + 分应用代理（仅安卓）。
class SettingsRulesPage extends StatefulWidget {
  const SettingsRulesPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsRulesPage> createState() => _SettingsRulesPageState();
}

class _SettingsRulesPageState extends State<SettingsRulesPage> {
  AppState get _state => widget.state;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _manageRules() async {
    final rules = await showDialog<List<RouteRuleSetting>>(
      context: context,
      builder: (context) =>
          RuleListDialog(initial: _state.settings.customRules),
    );
    if (rules == null) return;
    await _state.updateSettings(_state.settings.copyWith(customRules: rules));
    if (mounted) _toast('规则已保存，重新连接后生效');
  }

  Future<void> _selectApps({required bool direct}) async {
    if (!Platform.isAndroid) return;
    try {
      final apps = await VpnChannel().listUserApps();
      if (!mounted) return;
      if (apps.isEmpty) {
        _toast('没有读取到已安装应用，请检查应用列表权限');
        return;
      }
      final settings = _state.settings;
      final current = direct ? settings.directApps : settings.proxyApps;
      final initial = direct
          ? current.toSet()
          : (current.isEmpty
                ? apps.map((item) => item.package).toSet()
                : current.toSet());
      final selected = await showDialog<Set<String>>(
        context: context,
        builder: (context) => _AppPickerDialog(
          apps: apps,
          initial: initial,
          title: direct ? '选择强制直连的应用' : '选择要代理的应用',
          emptyHint: direct ? '不选表示没有额外直连应用' : '不选表示代理全部用户应用',
        ),
      );
      if (selected == null) return;
      await _state.updateSettings(
        direct
            ? settings.copyWith(directApps: selected.toList())
            : settings.copyWith(proxyApps: selected.toList()),
      );
      if (!mounted) return;
      _toast(
        selected.isEmpty
            ? (direct ? '已清空直连应用' : '未选择代理应用，默认代理全部用户应用')
            : '已保存 ${selected.length} 个应用',
      );
    } catch (e) {
      _toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        final settings = _state.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('代理规则')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
            children: [
              const SectionLabel('分流规则'),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '内置：geosite-cn / geoip-cn → 直连\n国外流量 → 代理节点',
                      style: TextStyle(fontSize: 12.5, height: 1.5),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      settings.customRules.isEmpty
                          ? '还没有自定义规则'
                          : '自定义规则 ${settings.customRules.length} 条',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _manageRules,
                      icon: const Icon(Icons.rule, size: 18),
                      label: const Text('管理规则集'),
                    ),
                  ],
                ),
              ),

              if (Platform.isAndroid) ...[
                const SectionLabel('分应用代理'),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              settings.proxyApps.isEmpty
                                  ? '代理应用：全部用户应用'
                                  : '代理应用：已选 ${settings.proxyApps.length} 个',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                          TextButton(
                            onPressed: () => _selectApps(direct: false),
                            child: const Text('选择'),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              settings.directApps.isEmpty
                                  ? '直连应用：无（可留空）'
                                  : '直连应用：已选 ${settings.directApps.length} 个',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                          TextButton(
                            onPressed: () => _selectApps(direct: true),
                            child: const Text('选择'),
                          ),
                        ],
                      ),
                      Text(
                        '直连应用强制不进入 VPN；系统应用始终直连。两个列表都可以不选。',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _AppPickerDialog extends StatefulWidget {
  const _AppPickerDialog({
    required this.apps,
    required this.initial,
    required this.title,
    required this.emptyHint,
  });

  final List<AppEntry> apps;
  final Set<String> initial;
  final String title;
  final String emptyHint;

  @override
  State<_AppPickerDialog> createState() => _AppPickerDialogState();
}

class _AppPickerDialogState extends State<_AppPickerDialog> {
  late final Set<String> _selected = {...widget.initial};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final visible = widget.apps
        .where((app) {
          if (query.isEmpty) return true;
          return app.label.toLowerCase().contains(query) ||
              app.package.toLowerCase().contains(query);
        })
        .toList(growable: false);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: 520,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                hintText: '搜索应用名称或包名',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.emptyHint,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '已选 ${_selected.length} / ${widget.apps.length}',
                  style: const TextStyle(fontSize: 12),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    _selected.addAll(visible.map((item) => item.package));
                  }),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _selected.removeAll(visible.map((item) => item.package));
                  }),
                  child: const Text('清空'),
                ),
              ],
            ),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final app = visible[index];
                  return CheckboxListTile(
                    dense: true,
                    value: _selected.contains(app.package),
                    title: Text(
                      app.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      app.package,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5),
                    ),
                    onChanged: (checked) => setState(() {
                      if (checked == true) {
                        _selected.add(app.package);
                      } else {
                        _selected.remove(app.package);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(Set<String>.from(_selected)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
