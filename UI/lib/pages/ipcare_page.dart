import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../state/app_state.dart';
import '../widgets/section.dart';
import 'ipcare_detail_page.dart';

/// IP 养护：每张卡片是一台服务器，点卡片直接检测，送中则自动纠偏。
class IpCarePage extends StatefulWidget {
  const IpCarePage({super.key, required this.state});

  final AppState state;

  @override
  State<IpCarePage> createState() => _IpCarePageState();
}

class _IpCarePageState extends State<IpCarePage> {
  static const _regions = <String, String>{
    'US': '美国',
    'HK': '香港',
    'JP': '日本',
    'SG': '新加坡',
    'TW': '台湾',
    'GB': '英国',
    'DE': '德国',
    'KR': '韩国',
    'CA': '加拿大',
    'AU': '澳大利亚',
  };

  final Map<String, IpCareStatus> _statuses = {};
  final Map<String, String> _errors = {};
  final Set<String> _running = {};
  List<IpCareTarget> _targets = const [];

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _targets = List<IpCareTarget>.from(_state.settings.ipCareTargets);
    for (final target in _targets) {
      _refresh(target, quiet: true);
    }
  }

  IpCareClient _client(IpCareTarget target) => IpCareClient(
        subscriptionUrl: target.url,
        pin: normalizePin(target.pin),
        token: target.token.trim(),
      );

  Future<void> _refresh(IpCareTarget target, {bool quiet = false}) async {
    if (_running.contains(target.id)) return;
    if (!quiet) setState(() => _running.add(target.id));
    try {
      final status = await _client(target).status();
      if (!mounted) return;
      setState(() {
        _statuses[target.id] = status;
        _errors.remove(target.id);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errors[target.id] = e.toString());
    } finally {
      if (mounted) setState(() => _running.remove(target.id));
    }
  }

  Future<void> _openDetail(IpCareTarget target) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => IpCareDetailPage(state: _state, target: target),
      ),
    );
    if (mounted) await _refresh(target, quiet: true);
  }

  Future<void> _addTarget() async {
    final name = TextEditingController();
    final url = TextEditingController(text: _state.settings.panelUrl);
    final pin = TextEditingController(text: _state.settings.panelPin);
    final token = TextEditingController();
    final result = await showDialog<IpCareTarget>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加服务器'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '香港-01',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '面板地址',
                  hintText: 'https://1.2.3.4:8080',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: pin,
                decoration: const InputDecoration(
                  labelText: '证书指纹',
                  hintText: '64 位 SHA-256',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: token,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'IP 养护令牌',
                  hintText: '面板 IP 养护页生成',
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
              final rawUrl = url.text.trim();
              final rawPin = normalizePin(pin.text);
              if (!rawUrl.startsWith('https://') ||
                  rawPin.length != 64 ||
                  token.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请填写 https 地址、64 位指纹和令牌')),
                );
                return;
              }
              Navigator.of(context).pop(
                IpCareTarget(
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  name: name.text.trim().isEmpty ? '未命名服务器' : name.text.trim(),
                  url: rawUrl,
                  pin: rawPin,
                  token: token.text.trim(),
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    name.dispose();
    url.dispose();
    pin.dispose();
    token.dispose();
    if (result == null) return;
    final next = [..._targets, result];
    await _state.updateSettings(_state.settings.copyWith(ipCareTargets: next));
    setState(() => _targets = next);
    await _refresh(result, quiet: true);
  }

  Future<void> _removeTarget(IpCareTarget target) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除服务器'),
        content: Text('确定删除「${target.name}」？'),
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
    if (ok != true) return;
    final next = _targets.where((e) => e.id != target.id).toList();
    await _state.updateSettings(_state.settings.copyWith(ipCareTargets: next));
    setState(() {
      _targets = next;
      _statuses.remove(target.id);
      _errors.remove(target.id);
    });
  }

  Future<void> _editSettings(IpCareTarget target) async {
    final status = _statuses[target.id];
    var region = status?.settings.targetRegion ?? 'US';
    var mode = status?.settings.detectMode ?? 'manual';
    var warm = status?.settings.warmMode ?? 'manual';
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('设置 · ${target.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: region,
                decoration: const InputDecoration(labelText: '目标区域'),
                items: _regions.entries
                    .map((e) => DropdownMenuItem(
                          value: e.key,
                          child: Text('${e.value} ${e.key}'),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setDialogState(() => region = v);
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: mode,
                decoration: const InputDecoration(labelText: '检测模式'),
                items: const [
                  DropdownMenuItem(value: 'manual', child: Text('手动')),
                  DropdownMenuItem(value: '20m', child: Text('每 20 分钟')),
                  DropdownMenuItem(value: 'hourly', child: Text('每小时')),
                  DropdownMenuItem(value: '6h', child: Text('每 6 小时')),
                  DropdownMenuItem(value: '12h', child: Text('每 12 小时')),
                  DropdownMenuItem(value: 'daily', child: Text('每天一次')),
                  DropdownMenuItem(value: 'weekly', child: Text('每周一次')),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => mode = v);
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: warm,
                decoration: const InputDecoration(labelText: '纠偏模式'),
                items: const [
                  DropdownMenuItem(value: 'manual', child: Text('手动')),
                  DropdownMenuItem(
                    value: 'auto',
                    child: Text('检测到送中后自动纠偏'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => warm = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await _client(target).saveSettings(
                    targetRegion: region,
                    detectMode: mode,
                    warmMode: warm,
                  );
                  if (context.mounted) Navigator.of(context).pop(true);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) await _refresh(target);
  }

  String _time(int ts) {
    if (ts <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('IP 养护'),
        actions: [
          IconButton(
            onPressed: _addTarget,
            icon: const Icon(Icons.add),
            tooltip: '添加服务器',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          for (final target in _targets) {
            await _refresh(target, quiet: true);
          }
        },
        child: _targets.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(40),
                children: [
                  Icon(Icons.radar, size: 56, color: scheme.primary),
                  const SizedBox(height: 16),
                  const Text(
                    '还没有服务器',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点右上角 +，填写面板地址、证书指纹和 IP 养护令牌。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _addTarget,
                    icon: const Icon(Icons.add),
                    label: const Text('添加服务器'),
                  ),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.all(14),
                itemCount: _targets.length,
                itemBuilder: (context, index) {
                  final target = _targets[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _targetCard(target),
                  );
                },
              ),
      ),
    );
  }

  Widget _targetCard(IpCareTarget target) {
    final status = _statuses[target.id];
    final error = _errors[target.id] ?? '';
    final running = _running.contains(target.id) || status?.busy == true;
    final sent = status?.isCN == true;
    final scheme = Theme.of(context).colorScheme;
    final color = error.isNotEmpty
        ? scheme.error
        : sent
            ? Colors.orange
            : status?.lastCheck != null && status!.lastCheck > 0
                ? scheme.primary
                : scheme.onSurfaceVariant;
    final label = error.isNotEmpty
        ? '连接失败'
        : running
            ? '维护中…'
            : status == null
                ? '未检测'
                : status.lastCheck == 0
                    ? '未检测'
                    : sent
                        ? '送中'
                        : '正常';

    return SectionCard(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: running ? null : () => _openDetail(target),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  running ? Icons.sync : Icons.radar,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            target.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            color: color,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      target.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      status == null
                          ? '点击卡片查看详情'
                          : '${status.googleRegion.isEmpty ? '未知' : status.googleRegion} · '
                              '信誉 ${status.trustScore >= 0 ? status.trustScore : '未检测'} · '
                              '${_time(status.lastCheck)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: error.isNotEmpty ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                    if (status != null && status.lastWarm > 0)
                      Text(
                        '最后纠偏 ${_time(status.lastWarm)}',
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'settings') _editSettings(target);
                  if (value == 'delete') _removeTarget(target);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'settings', child: Text('设置')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
