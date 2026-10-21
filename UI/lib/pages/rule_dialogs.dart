import 'dart:io';

import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../widgets/password_keyboard.dart';

class RuleListDialog extends StatefulWidget {
  const RuleListDialog({super.key, required this.initial});

  final List<RouteRuleSetting> initial;

  @override
  State<RuleListDialog> createState() => _RuleListDialogState();
}

class _RuleListDialogState extends State<RuleListDialog> {
  late final List<RouteRuleSetting> _rules = [...widget.initial];

  String _typeLabel(String type) => switch (type) {
    'domain_keyword' => '域名关键字',
    'ip_cidr' => 'IP 段',
    _ => '域名后缀',
  };

  String _outboundLabel(String outbound) => switch (outbound) {
    'proxy' => '代理',
    'reject' => '拦截',
    _ => '直连',
  };

  Future<void> _add() async {
    final rule = await showDialog<RouteRuleSetting>(
      context: context,
      builder: (context) => const AddRuleDialog(),
    );
    if (rule != null) setState(() => _rules.add(rule));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('分流规则'),
      content: SizedBox(
        width: 620,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '内置规则始终生效：国内域名/IP 直连，其余走代理。',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.public, size: 18),
              title: Text('geosite-cn'),
              subtitle: Text('国内域名 → 直连'),
              trailing: Text('内置'),
            ),
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.language, size: 18),
              title: Text('geoip-cn'),
              subtitle: Text('国内 IP → 直连'),
              trailing: Text('内置'),
            ),
            const Divider(height: 18),
            Row(
              children: [
                const Text(
                  '自定义规则',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加'),
                ),
              ],
            ),
            Expanded(
              child: _rules.isEmpty
                  ? Center(
                      child: Text(
                        '还没有自定义规则',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _rules.length,
                      itemBuilder: (context, index) {
                        final rule = _rules[index];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(rule.value),
                          subtitle: Text(
                            '${_typeLabel(rule.type)} → ${_outboundLabel(rule.outbound)}',
                          ),
                          trailing: IconButton(
                            tooltip: '删除',
                            onPressed: () =>
                                setState(() => _rules.removeAt(index)),
                            icon: const Icon(Icons.delete_outline, size: 18),
                          ),
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
              Navigator.of(context).pop(List<RouteRuleSetting>.from(_rules)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class AddRuleDialog extends StatefulWidget {
  const AddRuleDialog({super.key});

  @override
  State<AddRuleDialog> createState() => _AddRuleDialogState();
}

class _AddRuleDialogState extends State<AddRuleDialog> {
  final _value = TextEditingController();
  String _type = 'domain_suffix';
  String _outbound = 'direct';
  String? _error;

  static const _types = {
    'domain_suffix': '域名后缀',
    'domain_keyword': '域名关键字',
    'ip_cidr': 'IP 段',
  };

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _value.text.trim();
    if (value.isEmpty) {
      setState(() => _error = '请填写规则内容');
      return;
    }
    if (_type == 'ip_cidr') {
      final parts = value.split('/');
      final address = InternetAddress.tryParse(parts.first);
      final prefix = parts.length == 2 ? int.tryParse(parts[1]) : null;
      final max = address?.type == InternetAddressType.IPv6 ? 128 : 32;
      if (address == null || prefix == null || prefix < 0 || prefix > max) {
        setState(() => _error = 'IP 段格式应为 1.2.3.0/24 或 2001:db8::/32');
        return;
      }
    }
    Navigator.of(context)
        .pop(RouteRuleSetting(type: _type, value: value, outbound: _outbound));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加规则'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: '规则类型'),
              items: [
                for (final entry in _types.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) =>
                  setState(() => _type = value ?? 'domain_suffix'),
            ),
            const SizedBox(height: 12),
            KeyField(
              controller: _value,
              label: '内容',
              hint: switch (_type) {
                'ip_cidr' => '例如 1.2.3.0/24',
                'domain_keyword' => '例如 bilibili',
                _ => '例如 example.com',
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _outbound,
              decoration: const InputDecoration(labelText: '动作'),
              items: const [
                DropdownMenuItem(value: 'direct', child: Text('直连')),
                DropdownMenuItem(value: 'proxy', child: Text('走代理')),
                DropdownMenuItem(value: 'reject', child: Text('拦截')),
              ],
              onChanged: (value) =>
                  setState(() => _outbound = value ?? 'direct'),
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
