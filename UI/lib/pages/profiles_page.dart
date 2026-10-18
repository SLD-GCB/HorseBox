import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/section.dart';

/// 订阅管理：展开后可填证书指纹、查看节点。
class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key, required this.state});

  final AppState state;

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  bool _adding = false;
  String? _expandedId;
  final Map<String, List<SubscriptionNode>> _nodes = {};
  final Set<String> _loading = {};
  final Map<String, String> _errors = {};

  /// key = profileId::tag，value = 延迟毫秒，-1 表示失败。
  final Map<String, int> _delays = {};
  final Set<String> _testing = {};

  String _delayKey(Profile profile, String tag) => '${profile.id}::$tag';

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _add() async {
    final result = await showDialog<(String, String, String)>(
      context: context,
      builder: (context) => const _ProfileDialog(),
    );
    if (result == null) return;
    setState(() => _adding = true);
    try {
      await widget.state.addProfile(
        result.$1,
        name: result.$2,
        certPin: result.$3,
      );
      final profile = widget.state.profiles.last;
      _expandedId = profile.id;
      await _load(profile);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('订阅已添加，共 ${_nodes[profile.id]?.length ?? 0} 个节点')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _toggle(Profile profile) async {
    if (_expandedId == profile.id) {
      setState(() => _expandedId = null);
      return;
    }
    setState(() {
      _expandedId = profile.id;
    });
    if (!_nodes.containsKey(profile.id) && !_loading.contains(profile.id)) {
      await _load(profile);
    }
  }

  Future<void> _load(Profile profile) async {
    setState(() {
      _loading.add(profile.id);
      _errors.remove(profile.id);
      _delays.removeWhere((key, _) => key.startsWith('${profile.id}::'));
    });
    try {
      final nodes = await widget.state.fetchNodes(profile);
      if (!mounted) return;
      setState(() => _nodes[profile.id] = nodes);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errors[profile.id] = '$e');
    } finally {
      if (mounted) setState(() => _loading.remove(profile.id));
    }
  }

  Future<void> _selectNode(Profile profile, String tag) async {
    final applied = await widget.state.selectNode(profile, tag);
    if (!mounted) return;
    final name = tag.isEmpty ? '自动选择' : tag;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(applied ? '已切换到 $name' : '$name 已保存，重新连接后生效'),
      ),
    );
  }

  Future<void> _testNode(Profile profile, String tag, {bool silent = false}) async {
    if (!widget.state.isConnected || profile.id != widget.state.activeId) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先切换到该订阅并连接')),
        );
      }
      return;
    }
    final key = _delayKey(profile, tag);
    if (_testing.contains(key)) return;
    setState(() => _testing.add(key));
    try {
      final delay = await widget.state.testNode(tag);
      if (!mounted) return;
      setState(() => _delays[key] = delay);
    } catch (e) {
      if (!mounted) return;
      setState(() => _delays[key] = -1);
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _testing.remove(key));
    }
  }

  Future<void> _testAll(Profile profile, List<SubscriptionNode> nodes) async {
    if (!widget.state.isConnected || profile.id != widget.state.activeId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先切换到该订阅并连接后再测速')),
      );
      return;
    }
    await Future.wait(nodes.map((node) => _testNode(profile, node.tag, silent: true)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('测速完成')),
      );
    }
  }

  Future<void> _remove(Profile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除订阅'),
        content: Text('确认删除「${profile.name}」？'),
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
    if (confirmed != true) return;
    await widget.state.removeProfile(profile.id);
    _nodes.remove(profile.id);
    _errors.remove(profile.id);
    _delays.removeWhere((key, _) => key.startsWith('${profile.id}::'));
    if (_expandedId == profile.id) _expandedId = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final profiles = widget.state.profiles;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  const Text(
                    '订阅',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _adding ? null : _add,
                    icon: _adding
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add, size: 18),
                    label: const Text('添加'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: profiles.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.cloud_off_outlined, size: 46, color: scheme.onSurfaceVariant),
                            const SizedBox(height: 14),
                            const Text('还没有订阅'),
                            const SizedBox(height: 6),
                            Text(
                              '在面板「用户 → 链接」里复制 sing-box 订阅地址，粘贴到这里。',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, height: 1.5, color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                      itemCount: profiles.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final profile = profiles[index];
                        return _ProfileCard(
                          profile: profile,
                          active: profile.id == widget.state.activeId,
                          expanded: profile.id == _expandedId,
                          loading: _loading.contains(profile.id),
                          nodes: _nodes[profile.id],
                          error: _errors[profile.id],
                          onSelect: () => widget.state.setActive(profile.id),
                          onToggle: () => _toggle(profile),
                          onReload: () => _load(profile),
                          onRemove: () => _remove(profile),
                          delayFor: (tag) => _delays[_delayKey(profile, tag)],
                          isTesting: (tag) => _testing.contains(_delayKey(profile, tag)),
                          onSelectNode: (tag) => _selectNode(profile, tag),
                          onTestNode: (tag) => _testNode(profile, tag),
                          onTestAll: () => _testAll(profile, _nodes[profile.id] ?? const []),
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

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.active,
    required this.expanded,
    required this.loading,
    required this.nodes,
    required this.error,
    required this.onSelect,
    required this.onToggle,
    required this.onReload,
    required this.onRemove,
    required this.delayFor,
    required this.isTesting,
    required this.onSelectNode,
    required this.onTestNode,
    required this.onTestAll,
  });

  final Profile profile;
  final bool active;
  final bool expanded;
  final bool loading;
  final List<SubscriptionNode>? nodes;
  final String? error;
  final VoidCallback onSelect;
  final VoidCallback onToggle;
  final VoidCallback onReload;
  final VoidCallback onRemove;
  final int? Function(String tag) delayFor;
  final bool Function(String tag) isTesting;
  final ValueChanged<String> onSelectNode;
  final ValueChanged<String> onTestNode;
  final VoidCallback onTestAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onSelect,
            borderRadius: BorderRadius.circular(10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.cloud_outlined, size: 20, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              profile.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (active) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '当前',
                                style: TextStyle(fontSize: 10, color: scheme.primary),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        profile.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: expanded ? '收起' : '查看节点',
                  onPressed: onToggle,
                  icon: AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.expand_more),
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: '刷新节点',
                  onPressed: loading ? null : onReload,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 8),
            const Divider(height: 12),
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '节点',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        loading ? '加载中…' : '${nodes?.length ?? 0}',
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                      const Spacer(),
                      if (nodes != null && nodes!.isNotEmpty)
                        TextButton(
                          onPressed: loading ? null : onTestAll,
                          child: const Text('全部测速', style: TextStyle(fontSize: 11)),
                        ),
                    ],
                  ),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    )
                  else if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        error!,
                        style: TextStyle(fontSize: 11.5, height: 1.5, color: scheme.error),
                      ),
                    )
                  else if (nodes == null || nodes!.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '没有解析到节点',
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    )
                  else ...[
                    if (nodes!.length > 1)
                      _NodeRow(
                        title: '自动选择',
                        subtitle: 'urltest 自动测速，选延迟最低的节点',
                        type: 'auto',
                        selected: profile.selectedNode.isEmpty,
                        delay: null,
                        testing: false,
                        onTap: () => onSelectNode(''),
                      ),
                    for (final node in nodes!)
                      _NodeRow(
                        title: node.tag,
                        subtitle: node.endpoint,
                        type: node.type,
                        selected: nodes!.length > 1 && profile.selectedNode == node.tag,
                        delay: delayFor(node.tag),
                        testing: isTesting(node.tag),
                        onTap: nodes!.length > 1 ? () => onSelectNode(node.tag) : null,
                        onTest: () => onTestNode(node.tag),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.title,
    required this.subtitle,
    required this.type,
    required this.selected,
    required this.delay,
    required this.testing,
    this.onTap,
    this.onTest,
  });

  final String title;
  final String subtitle;
  final String type;
  final bool selected;
  final int? delay;
  final bool testing;
  final VoidCallback? onTap;
  final VoidCallback? onTest;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final delayColor = delay == null
        ? scheme.onSurfaceVariant
        : delay == -1
            ? scheme.error
            : delay! < 200
                ? const Color(0xFF4CAF7D)
                : delay! < 500
                    ? const Color(0xFFD9A441)
                    : scheme.error;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.08) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: onTap == null
                  ? null
                  : Icon(
                      selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      size: 17,
                      color: selected ? scheme.primary : scheme.onSurfaceVariant,
                    ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type == 'auto'
                        ? TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)
                        : HorseBoxTheme.mono(context, size: 10.5),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                type,
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 4),
            if (onTest != null) ...[
              SizedBox(
                width: 48,
                child: Text(
                  testing
                      ? ''
                      : delay == null
                          ? ''
                          : delay == -1
                              ? '失败'
                              : '$delay ms',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 10.5, color: delayColor),
                ),
              ),
              SizedBox(
                width: 30,
                height: 30,
                child: testing
                    ? const Padding(
                        padding: EdgeInsets.all(7),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: '测速',
                        onPressed: onTest,
                        icon: const Icon(Icons.speed, size: 17),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog();

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _pin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请填写订阅地址');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      setState(() => _error = '地址必须以 http:// 或 https:// 开头');
      return;
    }
    final pin = _pin.text.trim();
    if (pin.isNotEmpty && !SubscriptionClient.isValidPin(pin)) {
      setState(() => _error = '证书指纹应为 64 位十六进制（SHA-256）');
      return;
    }
    Navigator.of(context).pop((url, _name.text.trim(), pin));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加订阅'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '订阅地址',
                hintText: 'https://面板地址/sub/令牌?target=singbox',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称（可选）',
                hintText: '留空则使用面板域名',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pin,
              style: HorseBoxTheme.mono(context, size: 12),
              decoration: const InputDecoration(
                labelText: '面板证书 SHA-256 指纹（可选）',
                hintText: '自签证书时填写，留空则只信任系统证书',
                isDense: true,
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
