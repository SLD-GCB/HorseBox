import 'dart:io';

import 'package:flutter/material.dart';

import '../pages/connections_page.dart';
import '../pages/home_page.dart';
import '../pages/logs_page.dart';
import '../pages/profiles_page.dart';
import '../pages/settings_page.dart';
import '../state/app_state.dart';
import '../widgets/capsule_nav.dart';

/// 主框架：桌面用悬浮侧边胶囊，安卓用悬浮底部胶囊。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});

  final AppState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _items = <CapsuleNavItem>[
    CapsuleNavItem(label: '首页', icon: Icons.bolt_outlined, activeIcon: Icons.bolt),
    CapsuleNavItem(label: '订阅', icon: Icons.cloud_outlined, activeIcon: Icons.cloud),
    CapsuleNavItem(label: '日志', icon: Icons.article_outlined, activeIcon: Icons.article),
    CapsuleNavItem(label: '连接', icon: Icons.swap_vert_outlined, activeIcon: Icons.swap_vert),
    CapsuleNavItem(label: '设置', icon: Icons.settings_outlined, activeIcon: Icons.settings),
  ];

  List<Widget> get _pages => [
        HomePage(state: widget.state, onOpenProfiles: () => setState(() => _index = 1)),
        ProfilesPage(state: widget.state),
        LogsPage(state: widget.state),
        ConnectionsPage(state: widget.state),
        SettingsPage(state: widget.state),
      ];

  @override
  Widget build(BuildContext context) {
    final desktop = !Platform.isAndroid && MediaQuery.sizeOf(context).width >= 760;
    final body = IndexedStack(index: _index, children: _pages);
    if (desktop) {
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 20, 8, 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: CapsuleNav(
                    items: _items,
                    index: _index,
                    onChanged: (value) => setState(() => _index = value),
                    axis: Axis.vertical,
                  ),
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(child: body),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CapsuleNav(
                items: _items,
                index: _index,
                onChanged: (value) => setState(() => _index = value),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
