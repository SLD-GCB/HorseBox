import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../ssh/ssh_forwarder.dart';
import '../state/app_state.dart';

/// 端口转发面板：本地端口 -> 远端主机，开关即时生效，重连后自动恢复。
class SshForwardSheet extends StatefulWidget {
  const SshForwardSheet({
    super.key,
    required this.state,
    required this.host,
    required this.forwarder,
  });

  final AppState state;
  final SshHost host;
  final SshForwarder forwarder;

  @override
  State<SshForwardSheet> createState() => _SshForwardSheetState();
}

class _SshForwardSheetState extends State<SshForwardSheet> {
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggle(SshForward rule, bool value) async {
    try {
      if (value) {
        await widget.forwarder.start(
          rule,
          onChange: () {
            if (mounted) setState(() {});
          },
        );
      } else {
        await widget.forwarder.stop(rule.id);
      }
    } catch (e) {
      _toast('启动失败：$e');
    }
    if (mounted) setState(() {});
    await widget.state.saveSshForwards(widget.host);
  }

  Future<void> _add() async {
    final result = await showDialog<SshForward>(
      context: context,
      builder: (context) => const _ForwardDialog(),
    );
    if (result == null) return;
    widget.host.forwards.add(result);
    await widget.state.saveSshForwards(widget.host);
    if (mounted) setState(() {});
  }

  Future<void> _remove(SshForward rule) async {
    await widget.forwarder.stop(rule.id);
    widget.host.forwards.removeWhere((item) => item.id == rule.id);
    await widget.state.saveSshForwards(widget.host);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rules = widget.host.forwards;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text(
                  '端口转发',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: _add,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '本地 127.0.0.1:端口 转发到远端地址，只在当前连接期间生效。',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: rules.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Text(
                        '还没有规则，点右上角添加。',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: rules.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final rule = rules[index];
                        final running = widget.forwarder.isRunning(rule.id);
                        final count = widget.forwarder.connectionCount(rule.id);
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            rule.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                          subtitle: Text(
                            running
                                ? '${rule.summary}  ·  连接 $count'
                                : rule.summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: running
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: running,
                                onChanged: (value) => _toggle(rule, value),
                              ),
                              IconButton(
                                tooltip: '删除',
                                onPressed: () => _remove(rule),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ForwardDialog extends StatefulWidget {
  const _ForwardDialog();

  @override
  State<_ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<_ForwardDialog> {
  final _local = TextEditingController();
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController();
  final _label = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _local.dispose();
    _host.dispose();
    _port.dispose();
    _label.dispose();
    super.dispose();
  }

  void _submit() {
    final local = int.tryParse(_local.text.trim()) ?? 0;
    final port = int.tryParse(_port.text.trim()) ?? 0;
    final host = _host.text.trim();
    if (local <= 0 || local > 65535) {
      setState(() => _error = '本地端口应在 1-65535 之间');
      return;
    }
    if (host.isEmpty) {
      setState(() => _error = '请填写目标主机');
      return;
    }
    if (port <= 0 || port > 65535) {
      setState(() => _error = '目标端口应在 1-65535 之间');
      return;
    }
    Navigator.of(context).pop(
      SshForward(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        label: _label.text.trim(),
        localPort: local,
        host: host,
        port: port,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加端口转发'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _local,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '本地端口',
                hintText: '例如 8080',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _host,
                    decoration: const InputDecoration(
                      labelText: '目标主机',
                      hintText: '127.0.0.1',
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '目标端口',
                      hintText: '80',
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              decoration: const InputDecoration(
                labelText: '备注（可选）',
                hintText: '例如 面板 8443',
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
