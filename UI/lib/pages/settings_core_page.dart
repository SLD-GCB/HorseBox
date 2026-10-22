import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/vpn_channel.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/section.dart';

/// 内核与后台：日志级别、自动连接、后台驻留、运行信息。
class SettingsCorePage extends StatelessWidget {
  const SettingsCorePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final settings = state.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('内核与后台')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
            children: [
              const SectionLabel('内核'),
              SectionCard(
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Text('日志级别')),
                        DropdownButton<String>(
                          value: settings.logLevel,
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(
                              value: 'warn',
                              child: Text('warn'),
                            ),
                            DropdownMenuItem(
                              value: 'info',
                              child: Text('info'),
                            ),
                            DropdownMenuItem(
                              value: 'debug',
                              child: Text('debug'),
                            ),
                          ],
                          onChanged: (v) => state.updateSettings(
                            settings.copyWith(logLevel: v ?? 'info'),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 22),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启动后自动连接'),
                      subtitle: const Text('仅 Windows 生效'),
                      value: settings.autoConnect,
                      onChanged: Platform.isAndroid
                          ? null
                          : (v) => state.updateSettings(
                              settings.copyWith(autoConnect: v),
                            ),
                    ),
                    const Divider(height: 22),
                    _InfoRow(
                      label: '内核版本',
                      value: state.coreVersion.isEmpty
                          ? '未运行'
                          : state.coreVersion,
                    ),
                    _InfoRow(label: '数据目录', value: state.dataDir),
                  ],
                ),
              ),

              if (Platform.isWindows) ...[
                const SectionLabel('数据目录'),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        state.dataDir,
                        style: HorseBoxTheme.mono(context, size: 11.5),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => _changeDataDir(context, state),
                        icon: const Icon(
                          Icons.drive_file_move_outline,
                          size: 18,
                        ),
                        label: const Text('更改数据目录'),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '更改后订阅、设置和 core 配置会复制到新目录；之后需要重连内核。',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              if (Platform.isAndroid) ...[
                const SectionLabel('后台驻留'),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '代理运行时会在通知栏显示常驻通知。Android 13+ 需要通知权限；'
                        '国产 ROM 还需要允许后台运行和关闭电池优化。',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () =>
                                VpnChannel().openNotificationSettings(),
                            icon: const Icon(
                              Icons.notifications_outlined,
                              size: 18,
                            ),
                            label: const Text('通知设置'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => VpnChannel().openBatterySettings(),
                            icon: const Icon(
                              Icons.battery_saver_outlined,
                              size: 18,
                            ),
                            label: const Text('电池优化'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 更改 Windows 数据目录：先输路径，再让 AppState 迁移。
Future<void> _changeDataDir(BuildContext context, AppState state) async {
  final controller = TextEditingController(text: state.dataDir);
  final messenger = ScaffoldMessenger.of(context);
  final path = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('更改数据目录'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '新的数据目录',
                hintText: r'例如 D:\HorseBoxData',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '会复制当前订阅、设置和内核配置到新目录；更改前请先断开代理。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            final value = controller.text.trim();
            if (value.isNotEmpty) Navigator.of(context).pop(value);
          },
          child: const Text('迁移'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (path == null) return;
  try {
    await state.changeDataDir(path);
    messenger.showSnackBar(const SnackBar(content: Text('数据目录已切换')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: HorseBoxTheme.mono(context, size: 11),
            ),
          ),
        ],
      ),
    );
  }
}
