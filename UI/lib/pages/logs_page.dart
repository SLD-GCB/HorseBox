import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../utils/format.dart';

/// 内核日志。
class LogsPage extends StatelessWidget {
  const LogsPage({super.key, required this.state});

  final AppState state;

  Color _color(String level, ColorScheme scheme) {
    return switch (level) {
      'ERROR' || 'FATAL' => scheme.error,
      'WARN' => const Color(0xFFD9A441),
      'DEBUG' || 'TRACE' => scheme.onSurfaceVariant,
      _ => scheme.primary,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final logs = state.logs;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  const Text(
                    '日志',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${logs.length}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: logs.isEmpty ? null : state.clearLogs,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('清空'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: logs.isEmpty
                  ? Center(
                      child: Text(
                        '连接后这里会显示内核日志',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 2, 14, 20),
                      itemCount: logs.length,
                      itemBuilder: (context, index) {
                        final entry = logs[logs.length - 1 - index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                formatClock(entry.time),
                                style: HorseBoxTheme.mono(context, size: 11),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 42,
                                child: Text(
                                  entry.level,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: _color(entry.level, scheme),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: SelectableText(
                                  entry.message,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    height: 1.45,
                                    color: scheme.onSurface.withValues(alpha: 0.88),
                                  ),
                                ),
                              ),
                            ],
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
