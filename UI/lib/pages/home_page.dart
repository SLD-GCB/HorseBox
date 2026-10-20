import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../utils/format.dart';
import '../widgets/section.dart';

/// 首页：连接开关、实时速率、当前订阅。
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.state,
    required this.onOpenProfiles,
  });

  final AppState state;
  final VoidCallback onOpenProfiles;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final connected = state.isConnected;
        final connecting = state.status == CoreStatus.connecting;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          children: [
            Row(
              children: [
                const Text(
                  'HorseBox',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (state.coreVersion.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      state.coreVersion,
                      style: TextStyle(fontSize: 11, color: scheme.primary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'HorseUI 专用客户端',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            Center(
              child: _ConnectButton(
                state: state,
                connected: connected,
                connecting: connecting,
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: Text(
                switch (state.status) {
                  CoreStatus.idle => '未连接',
                  CoreStatus.connecting => '正在连接…',
                  CoreStatus.connected =>
                    '已连接 · ${formatDuration(state.uptime)}',
                  CoreStatus.stopping => '正在断开…',
                  CoreStatus.error => '连接失败',
                },
                style: TextStyle(
                  fontSize: 13,
                  color: connected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    icon: Icons.arrow_upward_rounded,
                    label: '上传',
                    value: formatRate(state.traffic.up),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StatTile(
                    icon: Icons.arrow_downward_rounded,
                    label: '下载',
                    value: formatRate(state.traffic.down),
                    color: scheme.tertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.dns_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '当前订阅',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: onOpenProfiles,
                        child: const Text('管理'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    state.activeProfile?.name ?? '还没有添加订阅',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    state.activeProfile?.url ?? '从面板「用户 → 链接」复制 sing-box 订阅地址',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (state.activeProfile != null) ...[
                    const Divider(height: 24),
                    Row(
                      children: [
                        _MetaChip(
                          label: '混合端口',
                          value: '${state.settings.mixedPort}',
                        ),
                        const SizedBox(width: 8),
                        _MetaChip(
                          label: 'TUN',
                          value: state.settings.enableTun ? '开启' : '关闭',
                        ),
                        if (state.clashPort > 0) ...[
                          const SizedBox(width: 8),
                          _MetaChip(label: 'API', value: '${state.clashPort}'),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (state.error != null) ...[
              const SizedBox(height: 16),
              _ErrorCard(message: state.error!),
            ],
            const SizedBox(height: 18),
            SectionLabel(
              '提示',
              trailing: Icon(
                Icons.lightbulb_outline,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
            Text(
              '连接后所有应用的流量会进入 sing-box。电脑端首次使用 TUN 需要管理员权限；'
              '如果只是浏览器走代理，可以关闭 TUN，改用混合端口 ${state.settings.mixedPort}。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({
    required this.state,
    required this.connected,
    required this.connecting,
  });

  final AppState state;
  final bool connected;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = connected ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = connected ? scheme.onPrimary : scheme.onSurfaceVariant;
    return GestureDetector(
      onTap: state.busy ? null : state.toggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 158,
        height: 158,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: base,
          boxShadow: [
            if (connected)
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.32),
                blurRadius: 28,
                spreadRadius: 4,
              ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (connecting)
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3, color: fg),
              )
            else
              Icon(
                connected
                    ? Icons.power_settings_new
                    : Icons.power_settings_new_outlined,
                size: 42,
                color: fg,
              ),
            const SizedBox(height: 10),
            Text(
              connecting
                  ? '连接中'
                  : connected
                  ? '断开'
                  : '连接',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
