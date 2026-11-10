import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../state/app_state.dart';
import '../widgets/section.dart';

/// 防火墙只读监控：摘要卡片点进详情。
class FirewallPage extends StatefulWidget {
  const FirewallPage({super.key, required this.state});

  final AppState state;

  @override
  State<FirewallPage> createState() => _FirewallPageState();
}

class _FirewallPageState extends State<FirewallPage> {
  final List<IpCareTarget> _targets = [];
  IpCareTarget? _target;
  FirewallStatus? _status;
  FirewallGuardState? _guard;
  List<String> _logs = const [];
  List<FirewallAttackSource> _attackSources = const [];
  List<FirewallAttackLog> _attackLogs = const [];
  ServerMetrics? _metrics;
  String _error = '';
  bool _loading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _targets.addAll(widget.state.settings.ipCareTargets);
    if (_targets.isNotEmpty) _target = _targets.first;
    _load();
    _timer =
        Timer.periodic(const Duration(seconds: 5), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  IpCareClient get _client => IpCareClient(
        subscriptionUrl: _target!.url,
        pin: normalizePin(_target!.pin),
        token: _target!.token,
      );

  Future<void> _load({bool quiet = false}) async {
    if (_target == null) return;
    if (!quiet) setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _client.firewallStatus(),
        _client.firewallGuard(),
        _client.firewallLogs(),
        _client.firewallAttackSources(),
        _client.firewallAttackLogs(),
        _client.systemMetrics(),
      ]);
      if (!mounted) return;
      setState(() {
        _status = results[0] as FirewallStatus;
        _guard = results[1] as FirewallGuardState;
        _logs = results[2] as List<String>;
        _attackSources = results[3] as List<FirewallAttackSource>;
        _attackLogs = results[4] as List<FirewallAttackLog>;
        _metrics = results[5] as ServerMetrics;
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted && !quiet) setState(() => _loading = false);
    }
  }

  void _open(Widget page) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (context) => page));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('防火墙监控'),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => _load(),
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _targets.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '先在「IP 养护」里添加服务器和令牌。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () => _load(),
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  if (_targets.length > 1) _targetPicker(),
                  _metricsRow(scheme),
                  const SizedBox(height: 10),
                  if (_error.isNotEmpty)
                    Card(
                      color: scheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _error,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  _statusCard(scheme),
                  const SizedBox(height: 10),
                  _guardCard(scheme),
                  const SizedBox(height: 10),
                  _attacksCard(scheme),
                  const SizedBox(height: 10),
                  _portsCard(scheme),
                  const SizedBox(height: 10),
                  _logsCard(scheme),
                ],
              ),
            ),
    );
  }

  Widget _targetPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<IpCareTarget>(
        initialValue: _target,
        decoration: const InputDecoration(labelText: '监控服务器'),
        items: _targets
            .map((e) => DropdownMenuItem(value: e, child: Text(e.name)))
            .toList(),
        onChanged: (value) {
          if (value == null) return;
          setState(() {
            _target = value;
            _status = null;
            _guard = null;
            _logs = const [];
          });
          _load();
        },
      ),
    );
  }

  Widget _metricsRow(ColorScheme scheme) {
    final m = _metrics;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _MetricCard(
            label: 'CPU',
            value: m == null ? '—' : '${m.cpuPercent.toStringAsFixed(0)}%',
            sub: m == null ? '' : '${m.cpus} 核',
            percent: m?.cpuPercent ?? 0,
            color: _metricColor(m?.cpuPercent ?? 0),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MetricCard(
            label: '内存',
            value: m == null ? '—' : '${m.memPercent.toStringAsFixed(0)}%',
            sub: m == null
                ? ''
                : '${_bytes(m.memUsed)} / ${_bytes(m.memTotal)}',
            percent: m?.memPercent ?? 0,
            color: _metricColor(m?.memPercent ?? 0),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MetricCard(
            label: '硬盘',
            value: m == null ? '—' : '${m.diskPercent.toStringAsFixed(0)}%',
            sub: m == null
                ? ''
                : '${_bytes(m.diskUsed)} / ${_bytes(m.diskTotal)}',
            percent: m?.diskPercent ?? 0,
            color: _metricColor(m?.diskPercent ?? 0),
          ),
        ),
      ],
    );
  }

  Color _metricColor(double percent) {
    if (percent >= 90) return Colors.red;
    if (percent >= 75) return Colors.orange;
    return Colors.green;
  }

  String _bytes(int value) {
    if (value <= 0) return '—';
    const units = ['B', 'K', 'M', 'G', 'T'];
    var size = value.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 10 ? 0 : 1)}${units[unit]}';
  }

  Widget _statusCard(ColorScheme scheme) {
    final status = _status;
    final enabled = status?.enabled == true;
    final supported = status?.supported == true;
    return _SummaryCard(
      icon: supported ? Icons.shield_outlined : Icons.shield_outlined,
      color: supported ? (enabled ? Colors.green : Colors.orange) : Colors.red,
      title: '防火墙状态',
      value: status == null
          ? '加载中'
          : supported
              ? (enabled ? '已启用' : '未启用')
              : '不可用',
      subtitle: status == null
          ? ''
          : supported
              ? '规则${status.applied ? '已应用' : '未应用'} · '
                  '自动关端口${status.autoProtect ? '开启' : '关闭'}'
              : (status.error.isEmpty ? 'nftables 不可用' : status.error),
      onTap: status == null
          ? null
          : () => _open(FirewallStatusDetail(status: status)),
    );
  }

  Widget _guardCard(ColorScheme scheme) {
    final guard = _guard;
    final items = guard?.ports ?? const <FirewallPortGuard>[];
    final abnormal =
        items.where((e) => e.status == 'watch' || e.status == 'closed').length;
    return _SummaryCard(
      icon: Icons.speed,
      color: guard?.stale == true
          ? scheme.onSurfaceVariant
          : guard?.healthy == true
              ? Colors.green
              : Colors.orange,
      title: '动态容量',
      value: guard == null
          ? '加载中'
          : guard.stale
              ? 'fwd 未运行'
              : '${items.length} 个活动端口',
      subtitle: guard == null
          ? ''
          : guard.stale
              ? '快照过期'
              : abnormal > 0
                  ? '$abnormal 个端口观察/关闭中'
                  : '全部正常 · 资源${guard.healthy ? '健康' : '紧张'}',
      onTap: guard == null
          ? null
          : () => _open(FirewallGuardDetail(guard: guard)),
    );
  }

  Widget _attacksCard(ColorScheme scheme) {
    final latest = _attackLogs.isEmpty ? null : _attackLogs.first;
    final subtitle = latest == null
        ? '暂无攻击事件'
        : '最近 ${latest.protocol.toUpperCase()} ${latest.port} · '
            '${latest.current}/${latest.limit.toStringAsFixed(0)}';
    return _SummaryCard(
      icon: Icons.warning_amber_outlined,
      color: _attackLogs.isEmpty ? scheme.primary : Colors.orange,
      title: '攻击日志',
      value: '${_attackSources.length} 个异常 IP · ${_attackLogs.length} 条事件',
      subtitle: subtitle,
      onTap: () => _open(FirewallAttackDetail(
        sources: _attackSources,
        logs: _attackLogs,
      )),
    );
  }

  Widget _portsCard(ColorScheme scheme) {
    final ports = _status?.ports ?? const <FirewallPortState>[];
    final protected = ports.where((e) => e.protect).length;
    return _SummaryCard(
      icon: Icons.dns_outlined,
      color: scheme.primary,
      title: '端口规则',
      value: '${ports.length} 条',
      subtitle: '${ports.where((e) => e.action == 'close').length} 个关闭 · '
          '$protected 个保护',
      onTap: ports.isEmpty
          ? null
          : () => _open(FirewallPortsDetail(ports: ports)),
    );
  }

  Widget _logsCard(ColorScheme scheme) {
    final last = _logs.isEmpty ? '' : _logs.last;
    return _SummaryCard(
      icon: Icons.article_outlined,
      color: scheme.primary,
      title: '运行日志',
      value: _logs.isEmpty ? '暂无日志' : last,
      subtitle: '${_logs.length} 行 · 每 5 秒刷新',
      onTap: _logs.isEmpty ? null : () => _open(FirewallLogsDetail(lines: _logs)),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.percent,
    required this.color,
  });

  final String label;
  final String value;
  final String sub;
  final double percent;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 5),
          LinearProgressIndicator(
            value: (percent / 100).clamp(0.0, 1.0),
            minHeight: 4,
            color: color,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 4),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String value;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class FirewallStatusDetail extends StatelessWidget {
  const FirewallStatusDetail({super.key, required this.status});

  final FirewallStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('防火墙状态')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          SectionCard(
            child: Column(
              children: [
                _row('nftables', status.supported ? '支持' : '不支持/无权限'),
                _row('启用', status.enabled ? '是' : '否'),
                _row('规则应用', status.applied ? '是' : '否'),
                _row('自动关端口', status.autoProtect ? '开启' : '关闭'),
                _row('端口规则', '${status.ports.length} 条'),
                _row('黑名单', '${status.bans.length} 条'),
                if (status.error.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        status.error,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(width: 90, child: Text(key)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class FirewallGuardDetail extends StatelessWidget {
  const FirewallGuardDetail({super.key, required this.guard});

  final FirewallGuardState guard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('动态容量')),
      body: guard.ports.isEmpty
          ? const Center(child: Text('暂无活动连接'))
          : ListView(
              padding: const EdgeInsets.all(14),
              children: [
                Text(
                  guard.stale
                      ? 'fwd 未运行 / 快照过期'
                      : guard.healthy
                          ? '资源健康'
                          : '资源紧张',
                  style: TextStyle(
                    color: guard.stale
                        ? scheme.onSurfaceVariant
                        : guard.healthy
                            ? Colors.green
                            : Colors.orange,
                  ),
                ),
                const SizedBox(height: 10),
                ...guard.ports.map((item) {
                  final percent = item.limit <= 0
                      ? 0.0
                      : (item.current / item.limit).clamp(0.0, 1.0);
                  final color = item.status == 'closed'
                      ? Colors.red
                      : item.status == 'watch'
                          ? Colors.orange
                          : Colors.green;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '${item.protocol.toUpperCase()} ${item.port}',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '${item.current} / ${item.limit.toStringAsFixed(0)}',
                                style: TextStyle(fontSize: 12, color: color),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '基线 ${item.baseline.toStringAsFixed(1)} · '
                            '下限 ${item.floor.toStringAsFixed(0)} · '
                            '上限 ${item.ceiling.toStringAsFixed(0)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(
                            value: percent,
                            minHeight: 6,
                            color: color,
                            backgroundColor: scheme.surfaceContainerHighest,
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
    );
  }
}

class FirewallAttackDetail extends StatelessWidget {
  const FirewallAttackDetail({
    super.key,
    required this.sources,
    required this.logs,
  });

  final List<FirewallAttackSource> sources;
  final List<FirewallAttackLog> logs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('攻击日志')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Text(
            '异常 IP',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          if (sources.isEmpty)
            Text('暂无异常 IP', style: TextStyle(color: scheme.onSurfaceVariant))
          else
            ...sources.map((s) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${s.ip}  ·  ${s.protocol}/${s.port}'),
                  subtitle: Text('连接数 ${s.count} · ${_fmt(s.lastSeen)}'),
                  trailing: s.banned
                      ? const Text('已封', style: TextStyle(color: Colors.red))
                      : const Text('待确认',
                          style: TextStyle(color: Colors.orange)),
                )),
          const SizedBox(height: 14),
          Text(
            '攻击事件',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          if (logs.isEmpty)
            Text('暂无攻击事件', style: TextStyle(color: scheme.onSurfaceVariant))
          else
            ...logs.map((e) {
              final color = e.action == 'close'
                  ? Colors.red
                  : e.action == 'reopen'
                      ? Colors.green
                      : Colors.orange;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${e.protocol.toUpperCase()} ${e.port}  '
                  '${e.current}/${e.limit.toStringAsFixed(0)}',
                ),
                subtitle: Text(
                  '${_fmt(e.createdAt)} · ${_actionText(e.action)}\n'
                  '${_sourceText(e.sources)}',
                ),
                trailing: Icon(Icons.circle, size: 10, color: color),
              );
            }),
        ],
      ),
    );
  }

  String _fmt(int ts) =>
      ts == 0 ? '—' : DateTime.fromMillisecondsSinceEpoch(ts * 1000)
          .toLocal()
          .toString()
          .substring(0, 19);

  String _actionText(String action) {
    if (action == 'close') return '关端口';
    if (action == 'reopen') return '恢复';
    return '观察';
  }

  String _sourceText(String raw) {
    try {
      final list = jsonDecode(raw) as List;
      final parts = <String>[];
      for (final item in list.take(5)) {
        if (item is Map) {
          parts.add('${item['ip']} (${item['count']})');
        }
      }
      return parts.isEmpty ? '无来源' : parts.join('，');
    } catch (_) {
      return '无来源';
    }
  }
}

class FirewallPortsDetail extends StatelessWidget {
  const FirewallPortsDetail({super.key, required this.ports});

  final List<FirewallPortState> ports;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('端口规则')),
      body: ListView.separated(
        padding: const EdgeInsets.all(14),
        itemCount: ports.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final p = ports[index];
          return ListTile(
            dense: true,
            leading: Text(p.protocol.toUpperCase()),
            title: Text('${p.port}'),
            subtitle: Text(p.comment),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.protect)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(
                      Icons.verified_user_outlined,
                      size: 16,
                      color: Colors.green,
                    ),
                  ),
                Text(
                  p.action == 'close' ? '关闭' : '允许',
                  style: TextStyle(
                    fontSize: 12,
                    color: p.action == 'close' ? Colors.red : Colors.green,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class FirewallLogsDetail extends StatelessWidget {
  const FirewallLogsDetail({super.key, required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('运行日志')),
      body: Container(
        width: double.infinity,
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          child: Text(
            lines.join('\n'),
            style: const TextStyle(
              color: Color(0xFFD1D5DB),
              fontSize: 10.5,
              height: 1.5,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }
}
