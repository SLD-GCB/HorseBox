import 'dart:io';

import 'package:flutter/material.dart';

import '../pages/connections_page.dart';
import '../pages/home_page.dart';
import '../pages/logs_page.dart';
import '../pages/panel_page.dart';
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
  bool _navCollapsed = false;

  static const _items = <CapsuleNavItem>[
    CapsuleNavItem(label: '首页', icon: Icons.bolt_outlined, activeIcon: Icons.bolt),
    CapsuleNavItem(label: '订阅', icon: Icons.cloud_outlined, activeIcon: Icons.cloud),
    CapsuleNavItem(label: '日志', icon: Icons.article_outlined, activeIcon: Icons.article),
    CapsuleNavItem(label: '连接', icon: Icons.swap_vert_outlined, activeIcon: Icons.swap_vert),
    CapsuleNavItem(label: '面板', icon: Icons.apps, activeIcon: Icons.apps),
    CapsuleNavItem(label: '设置', icon: Icons.settings_outlined, activeIcon: Icons.settings),
  ];

  List<Widget> get _pages => [
        HomePage(state: widget.state, onOpenProfiles: () => setState(() => _index = 1)),
        ProfilesPage(state: widget.state),
        LogsPage(state: widget.state),
        ConnectionsPage(state: widget.state),
        PanelPage(state: widget.state),
        SettingsPage(state: widget.state),
      ];

  @override
  Widget build(BuildContext context) {
    final desktop = !Platform.isAndroid && MediaQuery.sizeOf(context).width >= 760;
    final body = IndexedStack(index: _index, children: _pages);
    if (desktop) {
      return Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(child: body),
              Positioned(
                left: 14,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_navCollapsed)
                        CapsuleNav(
                          items: _items,
                          index: _index,
                          onChanged: (value) => setState(() {
                            _index = value;
                            _navCollapsed = false;
                          }),
                          axis: Axis.vertical,
                        ),
                      const SizedBox(height: 8),
                      Material(
                        color: Colors.white.withValues(alpha: 0.06),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _navCollapsed = !_navCollapsed),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              _navCollapsed ? Icons.chevron_right : Icons.chevron_left,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final isPanel = _pages[_index] is PanelPage;
    return Scaffold(
      extendBody: isPanel,
      body: isPanel ? body : SafeArea(child: body),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isPanel)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.35),
                    shape: const StadiumBorder(),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () => setState(() => _navCollapsed = !_navCollapsed),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: Icon(
                          _navCollapsed
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              if (!isPanel || !_navCollapsed)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CapsuleNav(
                      items: _items,
                      index: _index,
                      onChanged: (value) => setState(() {
                        _index = value;
                        _navCollapsed = false;
                      }),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
