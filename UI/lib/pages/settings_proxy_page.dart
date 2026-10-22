import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/section.dart';

/// 代理设置：网络、DNS、私有域名映射。
class SettingsProxyPage extends StatefulWidget {
  const SettingsProxyPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsProxyPage> createState() => _SettingsProxyPageState();
}

class _SettingsProxyPageState extends State<SettingsProxyPage> {
  late final TextEditingController _port;
  late final TextEditingController _mtu;
  late final TextEditingController _dnsServers;

  late bool _allowLan;
  late bool _enableTun;
  late bool _enableIpv6;
  late String _stack;
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

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    final s = _state.settings;
    _port = TextEditingController(text: '${s.mixedPort}');
    _mtu = TextEditingController(text: '${s.tunMtu}');
    _dnsServers = TextEditingController(text: s.dnsServers.join('\n'));
    _allowLan = s.allowLan;
    _enableTun = s.enableTun;
    _enableIpv6 = s.enableIpv6;
    _stack = s.tunStack;
    _dnsMode = s.dnsMode;
    _strategy = s.dnsStrategy;
    _hosts = {
      for (final entry in s.hosts.entries)
        entry.key: List<String>.from(entry.value),
    };
  }

  @override
  void dispose() {
    _port.dispose();
    _mtu.dispose();
    _dnsServers.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
    await _state.updateSettings(
      _state.settings.copyWith(
        mixedPort: port,
        allowLan: _allowLan,
        enableTun: _enableTun,
        enableIpv6: _enableIpv6,
        tunStack: _stack,
        tunMtu: mtu,
        dnsMode: _dnsMode,
        dnsServers: servers,
        dnsStrategy: _strategy,
        hosts: _hosts,
      ),
    );
    if (!mounted) return;
    _toast('已保存，网络与 DNS 设置下次连接生效');
  }

  Future<void> _addHost() async {
    final result = await showDialog<(String, List<String>)>(
      context: context,
      builder: (context) => const _HostDialog(),
    );
    if (result == null) return;
    setState(() => _hosts[result.$1] = result.$2);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('代理设置'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
        children: [
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
                    Platform.isAndroid
                        ? '安卓固定开启（VpnService）'
                        : '接管系统全部流量，需要管理员权限',
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
                        DropdownMenuItem(
                          value: 'gvisor',
                          child: Text('gvisor'),
                        ),
                      ],
                      onChanged: (v) => setState(() => _stack = v ?? 'mixed'),
                    ),
                  ],
                ),
                Text(
                  'system 栈在手机和 Windows 上都不稳定，已移除；默认 mixed。',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
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
                  subtitle: const Text(
                    '默认关闭，只用 IPv4；网络没有 IPv6 时开启会出现 network is unreachable',
                  ),
                  value: _enableIpv6,
                  onChanged: (v) => setState(() => _enableIpv6 = v),
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
                          label: Text(
                            entry.key,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onPressed: () {
                            final lines = _dnsServers.text
                                .split(RegExp(r'[\n,]'))
                                .map((item) => item.trim())
                                .where((item) => item.isNotEmpty)
                                .toList();
                            if (!lines.contains(entry.value)) {
                              lines.add(entry.value);
                              setState(
                                () => _dnsServers.text = lines.join('\n'),
                              );
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
                          DropdownMenuItem(
                            value: 'prefer_ipv4',
                            child: Text('prefer_ipv4'),
                          ),
                          DropdownMenuItem(
                            value: 'prefer_ipv6',
                            child: Text('prefer_ipv6'),
                          ),
                          DropdownMenuItem(
                            value: 'ipv4_only',
                            child: Text('ipv4_only'),
                          ),
                          DropdownMenuItem(
                            value: 'ipv6_only',
                            child: Text('ipv6_only'),
                          ),
                        ],
                        onChanged: (v) =>
                            setState(() => _strategy = v ?? 'prefer_ipv4'),
                      ),
                    ],
                  ),
                ] else
                  Text(
                    '使用面板下发的 DNS（DoH 经代理隧道）。',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
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
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
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
                                    Text(
                                      entry.key,
                                      style: HorseBoxTheme.mono(context),
                                    ),
                                    Text(
                                      entry.value.join(', '),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: '删除',
                                onPressed: () =>
                                    setState(() => _hosts.remove(entry.key)),
                                icon: const Icon(Icons.close, size: 18),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 18),
          FilledButton(onPressed: _save, child: const Text('保存代理设置')),
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
            decoration: const InputDecoration(
              labelText: '域名',
              hintText: 'nas.home',
            ),
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
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
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
