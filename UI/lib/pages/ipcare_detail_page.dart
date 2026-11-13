import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../state/app_state.dart';
import '../widgets/section.dart';

/// IP 养护单台服务器详情：状态、设置、检测历史、纠偏历史。
class IpCareDetailPage extends StatefulWidget {
  const IpCareDetailPage({
    super.key,
    required this.state,
    required this.target,
  });

  final AppState state;
  final IpCareTarget target;

  @override
  State<IpCareDetailPage> createState() => _IpCareDetailPageState();
}

class _IpCareDetailPageState extends State<IpCareDetailPage> {
  IpCareStatus? _status;
  List<IpCareCheck> _checks = const [];
  List<IpCareJob> _jobs = const [];
  String _error = '';
  bool _loading = true;
  bool _busy = false;

  IpCareClient get _client => IpCareClient(
        subscriptionUrl: widget.target.url,
        pin: normalizePin(widget.target.pin),
        token: widget.target.token.trim(),
      );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final values = await Future.wait([
        _client.status(),
        _client.history(),
        _client.warmHistory(),
      ]);
      if (!mounted) return;
      setState(() {
        _status = values[0] as IpCareStatus;
        _checks = values[1] as List<IpCareCheck>;
        _jobs = values[2] as List<IpCareJob>;
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted && !quiet) setState(() => _loading = false);
    }
  }

  Future<void> _check({bool warmIfNeeded = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await _client.check();
      if (!mounted) return;
      if (result.error.isNotEmpty) {
        _snack(result.error);
      } else if (warmIfNeeded && result.isCN) {
        final job = await _client.warm();
        if (!mounted) return;
        _snack(job.error.isEmpty
            ? '发现送中，已纠偏 ${job.requests} 次'
            : job.error);
      } else {
        _snack(result.isCN ? '检测完成：送中' : '检测完成：正常');
      }
      await _load(quiet: true);
    } catch (e) {
      if (mounted) _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _warm() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final job = await _client.warm();
      if (!mounted) return;
      _snack(job.error.isEmpty ? '已纠偏 ${job.requests} 次' : job.error);
      await _load(quiet: true);
    } catch (e) {
      if (mounted) _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.target.name),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
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
            _statusCard(status),
            const SizedBox(height: 10),
            _settingsCard(status),
            const SizedBox(height: 10),
            _actionsCard(),
            const SizedBox(height: 10),
            _checksCard(),
            const SizedBox(height: 10),
            _jobsCard(),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(IpCareStatus? status) {
    final scheme = Theme.of(context).colorScheme;
    final sent = status?.isCN == true;
    final color = sent ? Colors.orange : Colors.green;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.radar, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sent ? '送中' : status == null ? '加载中' : '正常',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              if (status?.busy == true)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (status == null)
            const Text('加载中…')
          else ...[
            _row('出口 IP', status.ip.isEmpty ? '—' : status.ip),
            _row('Google 区域', status.googleRegion.isEmpty ? '未知' : status.googleRegion),
            _row('目标区域', status.targetRegion),
            _row('信誉分', status.trustScore >= 0 ? '${status.trustScore}' : '未检测'),
            _row('最近检测', _time(status.lastCheck)),
            _row('最近纠偏', _time(status.lastWarm)),
            if (status.lastError.isNotEmpty)
              _row('最近错误', status.lastError, color: scheme.error),
          ],
        ],
      ),
    );
  }

  Widget _settingsCard(IpCareStatus? status) {
    final s = status?.settings;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '当前设置',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          _row('目标区域', s?.targetRegion ?? '—'),
          _row('检测模式', _detectMode(s?.detectMode)),
          _row('检测间隔', _interval(s?.detectIntervalSeconds)),
          _row('纠偏模式', s?.warmMode == 'auto' ? '自动' : '手动'),
          _row('送中通知', s?.notifyCN == true ? '开' : '关'),
          _row('失败通知', s?.notifyFail == true ? '开' : '关'),
        ],
      ),
    );
  }

  Widget _actionsCard() {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '维护',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _check(),
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('只检测'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _check(warmIfNeeded: true),
                  icon: const Icon(Icons.build, size: 16),
                  label: const Text('检测并纠偏'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _warm,
              icon: const Icon(Icons.autorenew, size: 16),
              label: const Text('直接纠偏'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '目标：${widget.target.url}',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            '指纹：${_mask(widget.target.pin)} · 令牌：${widget.target.token.isEmpty ? '未配置' : '已配置'}',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _checksCard() {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '最近检测',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          if (_checks.isEmpty)
            Text(
              '暂无检测记录',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            )
          else
            ..._checks.take(20).map((item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${item.isCN ? '送中' : '正常'} · ${item.googleRegion.isEmpty ? '未知' : item.googleRegion}',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            _time(item.createdAt),
                            style: TextStyle(
                              fontSize: 10.5,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        'IP ${item.ip.isEmpty ? '—' : item.ip} · '
                        '信誉 ${item.trustScore >= 0 ? item.trustScore : '—'} · '
                        '延迟 ${item.latencyMs > 0 ? '${item.latencyMs}ms' : '—'}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (item.error.isNotEmpty)
                        Text(
                          item.error,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }

  Widget _jobsCard() {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '最近纠偏',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          if (_jobs.isEmpty)
            Text(
              '暂无纠偏记录',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            )
          else
            ..._jobs.take(20).map((job) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${job.status} · 请求 ${job.requests} 次',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      Text(
                        _time(job.createdAt),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }

  Widget _row(String key, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              key,
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12.5, color: color),
            ),
          ),
        ],
      ),
    );
  }

  String _time(int ts) {
    if (ts <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  String _detectMode(String? mode) {
    switch (mode) {
      case 'interval':
        return '定时';
      case 'manual':
        return '手动';
      default:
        return mode ?? '—';
    }
  }

  String _interval(int? seconds) {
    if (seconds == null || seconds <= 0) return '—';
    if (seconds < 3600) return '${seconds ~/ 60} 分钟';
    if (seconds < 86400) return '${seconds ~/ 3600} 小时';
    return '${seconds ~/ 86400} 天';
  }

  String _mask(String pin) {
    final value = normalizePin(pin);
    if (value.isEmpty) return '未配置';
    if (value.length <= 12) return value;
    return '${value.substring(0, 8)}…${value.substring(value.length - 4)}';
  }
}
