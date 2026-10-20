import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/masked_field.dart';
import '../widgets/section.dart';
import 'ssh_terminal_page.dart';

/// 配置页：管理要直接登录的服务器（SSH），点进去就是终端。
class SshPage extends StatelessWidget {
  const SshPage({super.key, required this.state});

  final AppState state;

  Future<void> _add(BuildContext context) async {
    final result = await showDialog<_HostInput>(
      context: context,
      builder: (context) => const _HostDialog(),
    );
    if (result == null) return;
    await state.addSshHost(
      host: result.host,
      username: result.username,
      password: result.password,
      name: result.name,
      port: result.port,
    );
  }

  Future<void> _edit(BuildContext context, SshHost item) async {
    final result = await showDialog<_HostInput>(
      context: context,
      builder: (context) => _HostDialog(initial: item),
    );
    if (result == null) return;
    await state.updateSshHost(
      item,
      host: result.host,
      username: result.username,
      password: result.password,
      name: result.name,
      port: result.port,
    );
  }

  Future<void> _remove(BuildContext context, SshHost item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除主机'),
        content: Text('确认删除「${item.label}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await state.removeSshHost(item.id);
  }

  Future<void> _resetFingerprint(BuildContext context, SshHost item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置主机指纹'),
        content: const Text('重置后下次连接会重新信任这台主机的密钥。只有在你确认换过机器或重装过系统时才这么做。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.saveSshFingerprint(item.id, '');
    }
  }

  void _open(BuildContext context, SshHost item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SshTerminalPage(state: state, host: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final hosts = state.sshHosts;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  const Text(
                    '配置',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加主机'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: hosts.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.build_outlined,
                              size: 46,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 14),
                            const Text('还没有主机'),
                            const SizedBox(height: 6),
                            Text(
                              '填好 IP、用户名和密码就能直接在这里开终端、传文件，不用再另装工具。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                      itemCount: hosts.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final item = hosts[index];
                        return SectionCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 2,
                          ),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.dns_outlined,
                              color: scheme.brightness == Brightness.dark
                                  ? Colors.white
                                  : scheme.primary,
                            ),
                            title: Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5),
                            ),
                            subtitle: Text(
                              item.endpoint,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HorseBoxTheme.mono(context, size: 10.5),
                            ),
                            trailing: PopupMenuButton<String>(
                              tooltip: '更多',
                              onSelected: (value) {
                                if (value == 'edit') {
                                  _edit(context, item);
                                } else if (value == 'fingerprint') {
                                  _resetFingerprint(context, item);
                                } else if (value == 'delete') {
                                  _remove(context, item);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(value: 'edit', child: Text('编辑')),
                                PopupMenuItem(
                                  value: 'fingerprint',
                                  child: Text('重置主机指纹'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除'),
                                ),
                              ],
                            ),
                            onTap: () => _open(context, item),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// 对话框返回值。
class _HostInput {
  const _HostInput({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.name,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String name;
}

class _HostDialog extends StatefulWidget {
  const _HostDialog({this.initial});

  final SshHost? initial;

  @override
  State<_HostDialog> createState() => _HostDialogState();
}

class _HostDialogState extends State<_HostDialog> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _password = MaskedTextController();
  String? _error;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _name.text = initial.name;
      _host.text = initial.host;
      _port.text = initial.port.toString();
      _user.text = initial.username;
      _password.text = initial.password;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final host = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 22;
    if (host.isEmpty) {
      setState(() => _error = '请填写主机地址');
      return;
    }
    if (user.isEmpty) {
      setState(() => _error = '请填写用户名');
      return;
    }
    if (port <= 0 || port > 65535) {
      setState(() => _error = '端口应在 1-65535 之间');
      return;
    }
    Navigator.of(context).pop(
      _HostInput(
        host: host,
        port: port,
        username: user,
        password: _password.text,
        name: _name.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_editing ? '编辑主机' : '添加主机'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _host,
              autofocus: !_editing,
              decoration: const InputDecoration(
                labelText: '主机 / IP',
                hintText: '1.2.3.4 或 example.com',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _user,
                    decoration: const InputDecoration(labelText: '用户名'),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '端口'),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            MaskedTextField(
              controller: _password,
              label: '密码',
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '备注名（可选）',
                hintText: '留空则显示 用户名@主机',
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
        FilledButton(onPressed: _submit, child: Text(_editing ? '保存' : '添加')),
      ],
    );
  }
}
