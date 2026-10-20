import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/masked_field.dart';
import '../widgets/section.dart';

/// 密码本：一个面板一条记录，登录面板时在「面板」页一键填入。
class CredentialsPage extends StatelessWidget {
  const CredentialsPage({super.key, required this.state});

  final AppState state;

  Future<void> _edit(BuildContext context, {PanelCredential? item}) async {
    final result = await showDialog<_CredentialInput>(
      context: context,
      builder: (context) => _CredentialDialog(initial: item),
    );
    if (result == null) return;
    final error = await state.saveCredential(
      id: item?.id,
      panel: result.panel,
      username: result.username,
      password: result.password,
    );
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _remove(BuildContext context, PanelCredential item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除记录'),
        content: Text('确认删除「${item.panel}」的登录信息？'),
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
    if (confirmed == true) await state.removeCredential(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final items = state.credentials;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  const Text(
                    '密码本',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () => _edit(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.vpn_key_outlined,
                              size: 46,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 14),
                            const Text('密码本还是空的'),
                            const SizedBox(height: 6),
                            Text(
                              '存好面板地址、账号和密码，在「面板」页右上角点钥匙就能一键填入，不用每次手打。',
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
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return SectionCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 2,
                          ),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.vpn_key_outlined,
                              color: scheme.brightness == Brightness.dark
                                  ? Colors.white
                                  : scheme.primary,
                            ),
                            title: Text(
                              item.username,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5),
                            ),
                            subtitle: Text(
                              item.panel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HorseBoxTheme.mono(context, size: 10.5),
                            ),
                            trailing: PopupMenuButton<String>(
                              tooltip: '更多',
                              onSelected: (value) {
                                if (value == 'edit') {
                                  _edit(context, item: item);
                                } else if (value == 'delete') {
                                  _remove(context, item);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(value: 'edit', child: Text('编辑')),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除'),
                                ),
                              ],
                            ),
                            onTap: () => _edit(context, item: item),
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

class _CredentialInput {
  const _CredentialInput({
    required this.panel,
    required this.username,
    required this.password,
  });

  final String panel;
  final String username;
  final String password;
}

class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog({this.initial});

  final PanelCredential? initial;

  @override
  State<_CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<_CredentialDialog> {
  final _panel = TextEditingController();
  final _user = TextEditingController();
  final _password = MaskedTextController();
  String? _error;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _panel.text = initial.panel;
      _user.text = initial.username;
      _password.text = initial.password;
    }
  }

  @override
  void dispose() {
    _panel.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final panel = AppState.normalizePanel(_panel.text);
    if (panel.isEmpty) {
      setState(() => _error = '请填写面板地址');
      return;
    }
    if (_user.text.trim().isEmpty) {
      setState(() => _error = '请填写用户名');
      return;
    }
    Navigator.of(context).pop(
      _CredentialInput(
        panel: panel,
        username: _user.text.trim(),
        password: _password.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_editing ? '编辑记录' : '添加面板账号'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _panel,
              autofocus: !_editing,
              decoration: const InputDecoration(
                labelText: '面板地址',
                hintText: '1.2.3.4:8443',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: '用户名'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            MaskedTextField(
              controller: _password,
              label: '密码',
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
