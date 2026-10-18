import 'dart:io';

import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../platform/vpn_channel.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/section.dart';
import 'rule_dialogs.dart';

/// 设置：网络、DNS、外观、内核。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _port;
  late final TextEditingController _mtu;
  late final TextEditingController _dnsServers;

  late bool _allowLan;
  late bool _enableTun;
  late bool _enableIpv6;
  late bool _autoConnect;
  late String _stack;
  late String _logLevel;
  late String _theme;
  late String _dnsMode;
  late String _strategy;
  late Map<String, List<String>> _hosts;

  static const _presets = <String, String>{
    '阿里': '223.5.5.5',
    '腾讯': '119.29.29.29',
    '114': '114.114.114.114',
    '百度': '180.76.76.76',
    '阿里 DoH': 'https://dns.alidns.com/dns-query',
    'DNSPod DoH': 'https://doh.pub/dns-query',
  };

  @override
  void initState() {
    super.initState();
    final s = widget.state.settings;
    _port = TextEditingController(text: '${s.mixedPort}');
    _mtu = TextEditingController(text: '${s.tunMtu}');
    _dnsServers = TextEditingController(text: s.dnsServers.join('\n'));
    _allowLan = s.allowLan;
    _enableTun = s.enableTun;
    _enableIpv6 = s.enableIpv6;
    _autoConnect = s.autoConnect;
    _stack = s.tunStack;
    _logLevel = s.logLevel;
    _theme = s.themeMode;
    _dnsMode = s.dnsMode;
    _strategy = s.dnsStrategy;
    _hosts = {
      for (final entry in s.hosts.entries) entry.key: List<String>.from(entry.value),
    };
  }

  @override
  void dispose() {
    _port.dispose();
    _mtu.dispose();
    _dnsServers.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _toast('混合端口需在 1-65535 之间');
      return;
    }
    final mtu = int.tryParse(_mtu.text.trim());
    if (mtu == null || mtu < 1280 || mtu > 9000) {
      _toast('MTU 需在 1280-9000 之间');
      return;
    }
    final servers = _dnsServers.text
        .split(RegExp(r'[\n,]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (_dnsMode == 'custom' && servers.isEmpty) {
      _toast('自定义 DNS 至少要填写一个服务器');
      return;
    }

    await widget.state.updateSettings(
      widget.state.settings.copyWith(
        mixedPort: port,
        allowLan: _allowLan,
        enableTun: _enableTun,
        enableIpv6: _enableIpv6,
        tunStack: _stack,
        tunMtu: mtu,
        logLevel: _logLevel,
        dnsMode: _dnsMode,
        dnsServers: servers,
        dnsStrategy: _strategy,
        hosts: _hosts,
        themeMode: _theme,
        autoConnect: _autoConnect,
      ),
    );
    if (!mounted) return;
    _toast('已保存，网络/DNS/内核设置下次连接生效');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addHost() async {
    final result = await showDialog<(String, List<String>)>(
      context: context,
      builder: (context) => const _HostDialog(),
    );
    if (result == null) return;
    setState(() => _hosts[result.$1] = result.$2);
  }

  Future<void> _manageRules() async {
    final rules = await showDialog<List<RouteRuleSetting>>(
      context: context,
      builder: (context) => RuleListDialog(initial: widget.state.settings.customRules),
    );
    if (rules == null) return;
    await widget.state.updateSettings(
      widget.state.settings.copyWith(customRules: rules),
    );
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
      final settings = widget.state.settings;
      final current = direct ? settings.directApps : settings.proxyApps;
      final initial = direct
          ? current.toSet()
          : (current.isEmpty ? apps.map((item) => item.package).toSet() : current.toSet());
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
      await widget.state.updateSettings(
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
      if (mounted) _toast('$e');
    }
  }

  Future<void> _changeDataDir() async {
    final controller = TextEditingController(text: widget.state.dataDir);
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('更改数据目录'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '新的数据目录',
                  hintText: r'例如 D:\HorseBoxData',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '会复制当前订阅、设置和内核配置到新目录；更改前请先断开代理。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.of(context).pop(value);
            },
            child: const Text('迁移'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (path == null) return;
    try {
      await widget.state.changeDataDir(path);
      _toast('数据目录已切换');
    } catch (e) {
      _toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
          children: [
            Row(
              children: [
                const Text(
                  '设置',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _save,
                  child: const Text('保存'),
                ),
              ],
            ),

            const SectionLabel('网络'),
            SectionCard(
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('混合端口')),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _port,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 22),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许局域网连接'),
                    subtitle: const Text('监听 0.0.0.0，其它设备可用本机代理'),
                    value: _allowLan,
                    onChanged: (v) => setState(() => _allowLan = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('TUN 模式'),
                    subtitle: Text(
                      Platform.isAndroid ? '安卓固定开启（VpnService）' : '接管系统全部流量，需要管理员权限',
                    ),
                    value: Platform.isAndroid ? true : _enableTun,
                    onChanged: Platform.isAndroid
                        ? null
                        : (v) => setState(() => _enableTun = v),
                  ),
                  Row(
                    children: [
                      const Expanded(child: Text('TUN 栈')),
                      DropdownButton<String>(
                        value: _stack == 'gvisor' ? 'gvisor' : 'mixed',
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 'mixed', child: Text('mixed')),
                          DropdownMenuItem(value: 'gvisor', child: Text('gvisor')),
                        ],
                        onChanged: (v) => setState(() => _stack = v ?? 'mixed'),
                      ),
                    ],
                  ),
                  Text(
                    'system 栈在手机和 Windows 上都不稳定，已移除；默认 mixed。',
                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const Divider(height: 22),
                  Row(
                    children: [
                      const Expanded(child: Text('TUN MTU')),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _mtu,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 22),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用 IPv6'),
                    subtitle: const Text('默认关闭，只用 IPv4；网络没有 IPv6 时开启会出现 network is unreachable'),
                    value: _enableIpv6,
                    onChanged: (v) => setState(() => _enableIpv6 = v),
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
                            widget.state.settings.proxyApps.isEmpty
                                ? '代理应用：全部用户应用'
                                : '代理应用：已选 ${widget.state.settings.proxyApps.length} 个',
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
                            widget.state.settings.directApps.isEmpty
                                ? '直连应用：无（可留空）'
                                : '直连应用：已选 ${widget.state.settings.directApps.length} 个',
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
                    widget.state.settings.customRules.isEmpty
                        ? '还没有自定义规则'
                        : '自定义规则 ${widget.state.settings.customRules.length} 条',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
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

            const SectionLabel('DNS'),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'panel', label: Text('沿用面板')),
                      ButtonSegment(value: 'custom', label: Text('自定义')),
                    ],
                    selected: {_dnsMode},
                    onSelectionChanged: (value) =>
                        setState(() => _dnsMode = value.first),
                  ),
                  const SizedBox(height: 14),
                  if (_dnsMode == 'custom') ...[
                    TextField(
                      controller: _dnsServers,
                      minLines: 2,
                      maxLines: 4,
                      style: HorseBoxTheme.mono(context),
                      decoration: const InputDecoration(
                        labelText: 'DNS 服务器（每行一个）',
                        hintText: '223.5.5.5\nhttps://dns.alidns.com/dns-query',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final entry in _presets.entries)
                          ActionChip(
                            label: Text(entry.key, style: const TextStyle(fontSize: 11)),
                            onPressed: () {
                              final lines = _dnsServers.text
                                  .split(RegExp(r'[\n,]'))
                                  .map((item) => item.trim())
                                  .where((item) => item.isNotEmpty)
                                  .toList();
                              if (!lines.contains(entry.value)) {
                                lines.add(entry.value);
                                setState(() => _dnsServers.text = lines.join('\n'));
                              }
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Expanded(child: Text('解析策略')),
                        DropdownButton<String>(
                          value: _strategy,
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(value: 'prefer_ipv4', child: Text('prefer_ipv4')),
                            DropdownMenuItem(value: 'prefer_ipv6', child: Text('prefer_ipv6')),
                            DropdownMenuItem(value: 'ipv4_only', child: Text('ipv4_only')),
                            DropdownMenuItem(value: 'ipv6_only', child: Text('ipv6_only')),
                          ],
                          onChanged: (v) => setState(() => _strategy = v ?? 'prefer_ipv4'),
                        ),
                      ],
                    ),
                  ] else
                    Text(
                      '使用面板下发的 DNS（DoH 经代理隧道）。',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),

            SectionLabel(
              '私有域名映射',
              trailing: TextButton.icon(
                onPressed: _addHost,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加'),
              ),
            ),
            SectionCard(
              child: _hosts.isEmpty
                  ? Text(
                      '把域名固定解析到指定 IP，例如 nas.home → 192.168.1.10。',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    )
                  : Column(
                      children: [
                        for (final entry in _hosts.entries)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(entry.key, style: HorseBoxTheme.mono(context)),
                                      Text(
                                        entry.value.join(', '),
                                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: '删除',
                                  onPressed: () => setState(() => _hosts.remove(entry.key)),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),

            const SectionLabel('外观'),
            SectionCard(
              child: Row(
                children: [
                  const Expanded(child: Text('主题')),
                  DropdownButton<String>(
                    value: _theme,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 'system', child: Text('跟随系统')),
                      DropdownMenuItem(value: 'dark', child: Text('深色')),
                      DropdownMenuItem(value: 'light', child: Text('浅色')),
                    ],
                    onChanged: (v) => setState(() => _theme = v ?? 'dark'),
                  ),
                ],
              ),
            ),

            const SectionLabel('内核'),
            SectionCard(
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('日志级别')),
                      DropdownButton<String>(
                        value: _logLevel,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 'warn', child: Text('warn')),
                          DropdownMenuItem(value: 'info', child: Text('info')),
                          DropdownMenuItem(value: 'debug', child: Text('debug')),
                        ],
                        onChanged: (v) => setState(() => _logLevel = v ?? 'info'),
                      ),
                    ],
                  ),
                  const Divider(height: 22),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启动后自动连接'),
                    subtitle: const Text('仅 Windows 生效'),
                    value: _autoConnect,
                    onChanged: Platform.isAndroid ? null : (v) => setState(() => _autoConnect = v),
                  ),
                  const Divider(height: 22),
                  _InfoRow(label: '内核版本', value: widget.state.coreVersion.isEmpty ? '未运行' : widget.state.coreVersion),
                  _InfoRow(label: '数据目录', value: widget.state.dataDir),
                ],
              ),
            ),

            if (Platform.isWindows) ...[
              const SectionLabel('数据目录'),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      widget.state.dataDir,
                      style: HorseBoxTheme.mono(context, size: 11.5),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _changeDataDir,
                      icon: const Icon(Icons.drive_file_move_outline, size: 18),
                      label: const Text('更改数据目录'),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '更改后订阅、设置和 core 配置会复制到新目录；之前连接的内核需要重连。',
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

            if (Platform.isAndroid) ...[
              const SectionLabel('后台驻留'),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '代理运行时会在通知栏显示常驻通知。Android 13+ 需要通知权限；国产 ROM 还需要允许后台运行和关闭电池优化。',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => VpnChannel().openNotificationSettings(),
                          icon: const Icon(Icons.notifications_outlined, size: 18),
                          label: const Text('通知设置'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => VpnChannel().openBatterySettings(),
                          icon: const Icon(Icons.battery_saver_outlined, size: 18),
                          label: const Text('电池优化'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            const SectionLabel('关于'),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('HorseBox', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(
                    'HorseUI 专用双端客户端 · Flutter + Dart + sing-box',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: HorseBoxTheme.mono(context, size: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostDialog extends StatefulWidget {
  const _HostDialog();

  @override
  State<_HostDialog> createState() => _HostDialogState();
}

class _HostDialogState extends State<_HostDialog> {
  final _domain = TextEditingController();
  final _ips = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _domain.dispose();
    _ips.dispose();
    super.dispose();
  }

  void _submit() {
    final domain = _domain.text.trim();
    final ips = _ips.text
        .split(RegExp(r'[\s,]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (domain.isEmpty || ips.isEmpty) {
      setState(() => _error = '域名和 IP 都要填');
      return;
    }
    for (final ip in ips) {
      if (InternetAddress.tryParse(ip) == null) {
        setState(() => _error = '$ip 不是合法 IP');
        return;
      }
    }
    Navigator.of(context).pop((domain, ips));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加域名映射'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _domain,
            autofocus: true,
            decoration: const InputDecoration(labelText: '域名', hintText: 'nas.home'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ips,
            decoration: const InputDecoration(
              labelText: 'IP 地址',
              hintText: '192.168.1.10（多个用逗号分隔）',
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
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
    final visible = widget.apps.where((app) {
      if (query.isEmpty) return true;
      return app.label.toLowerCase().contains(query) ||
          app.package.toLowerCase().contains(query);
    }).toList(growable: false);

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
                Text('已选 ${_selected.length} / ${widget.apps.length}',
                    style: const TextStyle(fontSize: 12)),
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
                    title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
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
          onPressed: () => Navigator.of(context).pop(Set<String>.from(_selected)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
