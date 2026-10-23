import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../widgets/section.dart';
import 'backup_page.dart';
import 'settings_appearance_page.dart';
import 'settings_core_page.dart';
import 'settings_save_page.dart';
import 'settings_ime_page.dart';
import 'settings_proxy_page.dart';
import 'settings_rules_page.dart';

/// 设置入口：每一项是一张卡片，点进去再做具体配置。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  void _open(BuildContext context, Widget page) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (context) => page));
  }

  String _appearanceLabel() {
    final mode = switch (state.settings.themeMode) {
      'light' => '浅色',
      'system' => '跟随系统',
      _ => '深色',
    };
    return mode;
  }

  String _proxyLabel() {
    final s = state.settings;
    final dns = s.dnsMode == 'custom' ? '自定义 DNS' : '面板 DNS';
    final hosts = s.hosts.isEmpty ? '无域名映射' : '${s.hosts.length} 条域名映射';
    return '端口 ${s.mixedPort} · $dns · $hosts';
  }

  String _rulesLabel() {
    final s = state.settings;
    final rules = '${s.customRules.length} 条自定义规则';
    if (!Platform.isAndroid) return rules;
    final apps = s.proxyApps.isEmpty ? '全部应用' : '${s.proxyApps.length} 个应用';
    return '$rules · 代理 $apps';
  }

  String _coreLabel() {
    final s = state.settings;
    final auto = s.autoConnect ? '开' : '关';
    return Platform.isWindows
        ? '日志 ${s.logLevel} · 自动连接 $auto'
        : '日志 ${s.logLevel}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                '设置',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
            _EntryCard(
              icon: Icons.palette_outlined,
              title: '外观',
              subtitle: _appearanceLabel(),
              accent: Color(state.settings.accent),
              onTap: () => _open(context, SettingsAppearancePage(state: state)),
            ),
            const SizedBox(height: 10),
            _EntryCard(
              icon: Icons.keyboard_alt_outlined,
              title: '内置输入法',
              subtitle: state.settings.imeChinese
                  ? '默认中文 · @@{state.settings.imeCandidates} 个候选'
                  : '默认英文 · 可在键盘上切中文',
              onTap: () => _open(context, SettingsImePage(state: state)),
            ),
            const SizedBox(height: 10),
            _EntryCard(
              icon: Icons.tune,
              title: '代理设置',
              subtitle: _proxyLabel(),
              onTap: () => _open(context, SettingsProxyPage(state: state)),
            ),
            const SizedBox(height: 10),
            _EntryCard(
              icon: Icons.rule_folder_outlined,
              title: '代理规则',
              subtitle: _rulesLabel(),
              onTap: () => _open(context, SettingsRulesPage(state: state)),
            ),
            const SizedBox(height: 10),
            _EntryCard(
              icon: Icons.memory,
              title: Platform.isAndroid ? '内核与后台' : '内核',
              subtitle: _coreLabel(),
              onTap: () => _open(context, SettingsCorePage(state: state)),
            ),
            const SizedBox(height: 10),
            _EntryCard(
              icon: Icons.save_outlined,
              title: '保存设置',
              subtitle: '把当前所有设置写盘，并同步给系统输入法',
              onTap: () => _open(context, SettingsSavePage(state: state)),
            ),
            const SizedBox(height: 10),
            _EntryCard(
              icon: Icons.backup_outlined,
              title: '备份管理',
              subtitle: '导出 / 导入全部数据（口令加密）',
              onTap: () => _open(context, BackupPage(state: state)),
            ),
            const SizedBox(height: 22),
            Text(
              'HorseBox · HorseUI 专用双端客户端',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        );
      },
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// 有值时在右侧显示一个小色块（用在外观卡片上）。
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(icon, size: 20, color: scheme.primary),
        title: Text(title, style: const TextStyle(fontSize: 13.5)),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (accent != null)
              Container(
                width: 14,
                height: 14,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
            Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
