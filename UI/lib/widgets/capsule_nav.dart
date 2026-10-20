import 'package:flutter/material.dart';

/// 胶囊导航项。
class CapsuleNavItem {
  const CapsuleNavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// 悬浮胶囊导航：只有图标，不贴边。
class CapsuleNav extends StatelessWidget {
  const CapsuleNav({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
    this.axis = Axis.horizontal,
    this.compact = false,
  });

  final List<CapsuleNavItem> items;
  final int index;
  final ValueChanged<int> onChanged;
  final Axis axis;

  /// 手机端用更小的尺寸，避免占掉太多竖向空间。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = compact ? 34.0 : 42.0;
    final iconSize = compact ? 18.0 : 22.0;
    final children = <Widget>[
      for (var i = 0; i < items.length; i++)
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: axis == Axis.horizontal ? (compact ? 1 : 2) : 0,
            vertical: axis == Axis.vertical ? 3 : 0,
          ),
          child: _NavButton(
            item: items[i],
            selected: i == index,
            onTap: () => onChanged(i),
            size: size,
            iconSize: iconSize,
          ),
        ),
    ];

    return Container(
      padding: EdgeInsets.all(compact ? 4 : 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(compact ? 24 : 30),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.28),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: axis == Axis.horizontal
          ? Row(mainAxisSize: MainAxisSize.min, children: children)
          : Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
    this.size = 42,
    this.iconSize = 22,
  });

  final CapsuleNavItem item;
  final bool selected;
  final VoidCallback onTap;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.label,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withValues(alpha: 0.16)
                : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(
            selected ? item.activeIcon : item.icon,
            size: iconSize,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
