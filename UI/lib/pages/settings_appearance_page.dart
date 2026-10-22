import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/section.dart';

/// 外观：主题模式 + 主题色（含自定义）。
class SettingsAppearancePage extends StatelessWidget {
  const SettingsAppearancePage({super.key, required this.state});

  final AppState state;

  static const _modes = <(String, String, IconData)>[
    ('system', '跟随系统', Icons.brightness_auto_outlined),
    ('dark', '深色', Icons.dark_mode_outlined),
    ('light', '浅色', Icons.light_mode_outlined),
  ];

  Future<void> _save(String mode) async {
    await state.updateSettings(state.settings.copyWith(themeMode: mode));
  }

  Future<void> _saveAccent(Color color) async {
    await state.updateSettings(
      state.settings.copyWith(accent: color.toARGB32()),
    );
  }

  Future<void> _pickCustom(BuildContext context) async {
    final current = Color(state.settings.accent);
    final picked = await showDialog<Color>(
      context: context,
      builder: (context) => _ColorDialog(initial: current),
    );
    if (picked != null) await _saveAccent(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final settings = state.settings;
        final accent = Color(settings.accent);
        return Scaffold(
          appBar: AppBar(title: const Text('外观')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
            children: [
              const SectionLabel('主题模式'),
              SectionCard(
                child: Column(
                  children: [
                    for (final item in _modes) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(item.$3, size: 20),
                        title: Text(item.$2),
                        trailing: settings.themeMode == item.$1
                            ? Icon(Icons.check, size: 18, color: scheme.primary)
                            : null,
                        onTap: () => _save(item.$1),
                      ),
                      if (item != _modes.last) const Divider(height: 1),
                    ],
                  ],
                ),
              ),
              const SectionLabel('主题色'),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final color in HorseBoxTheme.presets)
                          _Swatch(
                            color: color,
                            selected: color.toARGB32() == settings.accent,
                            onTap: () => _saveAccent(color),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _pickCustom(context),
                          icon: const Icon(Icons.colorize, size: 18),
                          label: const Text('自定义颜色'),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '主色会用在按钮、开关、进度条等强调位置；深色背景保持中性，不会整屏染色。',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 一个圆形色块。
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : null,
      ),
    );
  }
}

/// 自定义颜色：色相 / 饱和度 / 明度三条滑杆。
class _ColorDialog extends StatefulWidget {
  const _ColorDialog({required this.initial});

  final Color initial;

  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return AlertDialog(
      title: const Text('自定义颜色'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 44,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '色相 ${_hsv.hue.round()}',
              style: const TextStyle(fontSize: 12),
            ),
            Slider(
              value: _hsv.hue,
              max: 360,
              onChanged: (v) => setState(() => _hsv = _hsv.withHue(v)),
            ),
            Text(
              '饱和度 ${(_hsv.saturation * 100).round()}%',
              style: const TextStyle(fontSize: 12),
            ),
            Slider(
              value: _hsv.saturation,
              min: 0.15,
              onChanged: (v) => setState(() => _hsv = _hsv.withSaturation(v)),
            ),
            Text(
              '明度 ${(_hsv.value * 100).round()}%',
              style: const TextStyle(fontSize: 12),
            ),
            Slider(
              value: _hsv.value,
              min: 0.3,
              max: 0.85,
              onChanged: (v) => setState(() => _hsv = _hsv.withValue(v)),
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
          onPressed: () => Navigator.of(context).pop(color),
          child: const Text('使用'),
        ),
      ],
    );
  }
}
