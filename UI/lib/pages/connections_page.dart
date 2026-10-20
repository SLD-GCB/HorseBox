import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../utils/format.dart';
import '../widgets/section.dart';

/// 当前活动连接。
class ConnectionsPage extends StatelessWidget {
  const ConnectionsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final rows = state.connections;
        final up = rows.fold<int>(0, (sum, item) => sum + item.upload);
        final down = rows.fold<int>(0, (sum, item) => sum + item.download);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  const Text(
                    '连接',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${rows.length}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: state.refreshConnections,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: StatTile(
                      icon: Icons.arrow_upward_rounded,
                      label: '本次上传',
                      value: formatBytes(up),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      icon: Icons.arrow_downward_rounded,
                      label: '本次下载',
                      value: formatBytes(down),
                      color: scheme.tertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        state.isConnected ? '暂无活动连接' : '连接后显示活动连接',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: state.refreshConnections,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          return SectionCard(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.language,
                                      size: 15,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        row.host,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: HorseBoxTheme.mono(
                                          context,
                                          size: 12.5,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      formatBytes(row.total),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  row.chains.isEmpty
                                      ? row.rule
                                      : '${row.rule} · ${row.chains.join(' → ')}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
