import 'dart:io';

import 'package:flutter/material.dart';

import '../ime/pinyin_engine.dart';
import '../platform/ime_channel.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/section.dart';

/// 内置输入法设置：系统输入法开关、中文/英文、候选数量、词库。
class SettingsImePage extends StatefulWidget {
  const SettingsImePage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsImePage> createState() => _SettingsImePageState();
}

class _SettingsImePageState extends State<SettingsImePage>
    with WidgetsBindingObserver {
  SystemImeStatus _ime = SystemImeStatus.unavailable;
  ImeStats _stats = ImeStats.empty;
  bool _loading = true;

  /// 滑杆的本地值：拖动时只重绘，松手才写设置。
  late double _height = widget.state.settings.imeHeight.toDouble();
  late double _scale = widget.state.settings.imeScale;
  late double _amp = widget.state.settings.imeVibrateAmplitude.toDouble();

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置返回时刷新一次，用户不用手动重进页面。
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final status = await SystemIme.status();
    final stats = await SystemIme.stats();
    if (!mounted) return;
    setState(() {
      _ime = status;
      _stats = stats;
      _loading = false;
    });
  }

  /// 一行颜色设置：名称 + 色块 + 选择按钮。
  Widget _colorRow(String label, int value, ValueChanged<Color> onPick) {
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Color(value),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        TextButton(
          onPressed: () async {
            final picked = await showDialog<Color>(
              context: context,
              builder: (context) => _ImeColorDialog(initial: Color(value)),
            );
            if (picked != null) onPick(picked);
          },
          child: const Text('选择'),
        ),
      ],
    );
  }

  Future<void> _pickImeColor() async {
    final current = Color(widget.state.settings.imeAccentColor);
    final picked = await showDialog<Color>(
      context: context,
      builder: (context) => _ImeColorDialog(initial: current),
    );
    if (picked == null) return;
    await widget.state.updateSettings(
      widget.state.settings.copyWith(imeAccentColor: picked.toARGB32()),
    );
  }

  Future<void> _clearLearning() async {
    await SystemIme.clearLearning();
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('学习记录已清除')));
  }

  Future<void> _clearClipboard() async {
    await SystemIme.clearClipboard();
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('剪贴板记录已清除')));
  }

  String get _statusLabel {
    if (_loading) return '正在检查…';
    if (_ime.current) return '正在使用 HorseBox 输入法';
    if (_ime.enabled) return '已启用 · 当前用的是其它输入法';
    return '未启用';
  }

  String get _scaleLabel {
    if (_scale <= 0.9) return '偏小';
    if (_scale <= 1.05) return '标准';
    if (_scale <= 1.2) return '偏大';
    return '特大';
  }

  String get _deviceLine {
    if (!_stats.hasVibrator) return '设备：未检测到振动马达';
    final global = _stats.globalHaptic ? '系统触感开' : '系统触感关（已用触感通道绕过）';
    final amp = _stats.amplitudeControl ? '支持振幅' : '不支持振幅（改用时长）';
    return '设备：$global · $amp';
  }

  Future<void> _enableHaptic() async {
    final ok = await SystemIme.enableSystemHaptic();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请允许「修改系统设置」，返回后再点一次')));
      return;
    }
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('系统触感反馈已开启，震感会更强')));
  }

  Future<void> _previewFeedback() async {
    await SystemIme.preview();
    final stats = await SystemIme.stats();
    if (!mounted) return;
    setState(() => _stats = stats);
    if (!stats.hasVibrator) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这台设备没有可用的振动马达，只能用按键音')));
    }
  }

  Future<void> _saveAmplitude() async {
    final settings = widget.state.settings;
    final value = _amp.round();
    if (settings.imeVibrateAmplitude == value) return;
    await widget.state.updateSettings(
      settings.copyWith(imeVibrateAmplitude: value),
    );
  }

  Future<void> _saveSize() async {
    final settings = widget.state.settings;
    final height = _height.round();
    if (settings.imeHeight == height && settings.imeScale == _scale) return;
    await widget.state.updateSettings(
      settings.copyWith(imeHeight: height, imeScale: _scale),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final settings = state.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('内置输入法')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
            children: [
              if (Platform.isAndroid) ...[
                const SectionLabel('系统输入法'),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _ime.current
                                  ? scheme.primary
                                  : (_ime.enabled
                                        ? scheme.tertiary
                                        : scheme.outline),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _statusLabel,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '把键盘扩展到全系统：同一个布局、同一份离线词库，在任何 App 里都能用。'
                        '没有网络权限，不读剪贴板，不记录输入。',
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
                          FilledButton.tonalIcon(
                            onPressed: SystemIme.openSettings,
                            icon: const Icon(
                              Icons.keyboard_alt_outlined,
                              size: 17,
                            ),
                            label: Text(_ime.enabled ? '输入法设置' : '去启用'),
                          ),
                          OutlinedButton.icon(
                            onPressed: SystemIme.showPicker,
                            icon: const Icon(Icons.swap_horiz, size: 17),
                            label: const Text('切换输入法'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _ime.enabled
                            ? '切换输入法：点上面的按钮，或长按空格键。'
                            : '启用路径：系统设置 → 语言和输入法 → 当前输入法 → 选择「HorseBox 输入法」。',
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
                const SectionLabel('习惯与剪贴板'),
                SectionCard(
                  child: Column(
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('词频记忆'),
                        subtitle: const Text('记住你选过的词，同一个拼音下次排前面；只记在本机'),
                        value: settings.imeLearn,
                        onChanged: (v) => state.updateSettings(
                          settings.copyWith(imeLearn: v),
                        ),
                      ),
                      const Divider(height: 22),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('剪贴板入口'),
                        subtitle: const Text(
                          '键盘顶栏显示「剪贴板」，保留最近 30 条；加密保存在应用私有目录',
                        ),
                        value: settings.imeClipboard,
                        onChanged: (v) => state.updateSettings(
                          settings.copyWith(imeClipboard: v),
                        ),
                      ),
                      const Divider(height: 22),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('清除学习记录'),
                        subtitle: Text('已记录 ${_stats.learned} 条'),
                        trailing: const Icon(Icons.delete_outline, size: 18),
                        onTap: _stats.learned == 0 ? null : _clearLearning,
                      ),
                      const Divider(height: 22),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('清除剪贴板记录'),
                        subtitle: Text('已保存 ${_stats.clipboard} 条'),
                        trailing: const Icon(Icons.delete_outline, size: 18),
                        onTap: _stats.clipboard == 0 ? null : _clearClipboard,
                      ),
                    ],
                  ),
                ),
              ],
              if (Platform.isAndroid) ...[
                const SectionLabel('键盘主题'),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '明暗',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'app', label: Text('跟随 App')),
                          ButtonSegment(value: 'system', label: Text('跟随系统')),
                        ],
                        selected: {settings.imeDarkMode},
                        onSelectionChanged: (value) => state.updateSettings(
                          settings.copyWith(imeDarkMode: value.first),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '主色',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'app', label: Text('跟随 App')),
                          ButtonSegment(value: 'system', label: Text('跟随系统')),
                          ButtonSegment(value: 'custom', label: Text('自定义')),
                        ],
                        selected: {settings.imeAccentMode},
                        onSelectionChanged: (value) => state.updateSettings(
                          settings.copyWith(imeAccentMode: value.first),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (settings.imeAccentMode == 'custom') ...[
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final color in HorseBoxTheme.presets)
                              _ImeSwatch(
                                color: color,
                                selected:
                                    color.toARGB32() == settings.imeAccentColor,
                                onTap: () => state.updateSettings(
                                  settings.copyWith(
                                    imeAccentColor: color.toARGB32(),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: _pickImeColor,
                              icon: const Icon(Icons.colorize, size: 17),
                              label: const Text('自定义颜色'),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: Color(settings.imeAccentColor),
                                borderRadius: BorderRadius.circular(7),
                              ),
                            ),
                          ],
                        ),
                      ] else
                        Text(
                          settings.imeAccentMode == 'system'
                              ? '取系统的动态主题色（Android 12 及以上）；更低版本会退回 App 主题色。'
                              : '和 App 主题色一致；想换色改「外观 → 主题色」即可。',
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      const SizedBox(height: 10),
                      Text(
                        '用在回车键、⇧ 高亮、候选首项和拼音提示上；改完下次弹出键盘生效。',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Divider(height: 22),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('自定义整套颜色'),
                        subtitle: const Text('单独设置键盘背景、按键和文字颜色'),
                        value: settings.imeCustomPalette,
                        onChanged: (v) => state.updateSettings(
                          settings.copyWith(imeCustomPalette: v),
                        ),
                      ),
                      if (settings.imeCustomPalette) ...[
                        _colorRow(
                          '键盘背景',
                          settings.imeBgColor,
                          (c) => state.updateSettings(
                            settings.copyWith(imeBgColor: c.toARGB32()),
                          ),
                        ),
                        _colorRow(
                          '按键颜色',
                          settings.imeKeyColor,
                          (c) => state.updateSettings(
                            settings.copyWith(imeKeyColor: c.toARGB32()),
                          ),
                        ),
                        _colorRow(
                          '文字颜色',
                          settings.imeTextColor,
                          (c) => state.updateSettings(
                            settings.copyWith(imeTextColor: c.toARGB32()),
                          ),
                        ),
                        Text(
                          '其余层级（工具栏、底座、描边、提示文字）会按这三个颜色自动推导。',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (Platform.isAndroid) ...[
                const SectionLabel('按键反馈'),
                SectionCard(
                  child: Column(
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('按键震动'),
                        subtitle: const Text('每按一下震一下；不跟随系统的「触感反馈」开关'),
                        value: settings.imeVibrate,
                        onChanged: (v) => state.updateSettings(
                          settings.copyWith(imeVibrate: v),
                        ),
                      ),
                      if (settings.imeVibrate) ...[
                        const Divider(height: 22),
                        Row(
                          children: [
                            const Expanded(child: Text('震动强度')),
                            Text(
                              '${_amp.round()} / 255',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: _previewFeedback,
                              child: const Text('试一下'),
                            ),
                          ],
                        ),
                        Slider(
                          value: _amp.clamp(20, 255),
                          min: 20,
                          max: 255,
                          divisions: 47,
                          label: '${_amp.round()}',
                          onChanged: (v) => setState(() => _amp = v),
                          onChangeEnd: (_) => _saveAmplitude(),
                        ),
                        Text(
                          '数值越大震感越强；不支持振幅控制的机型会改成调震动时长。',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _deviceLine,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: scheme.primary,
                          ),
                        ),
                        if (!_stats.globalHaptic) ...[
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              onPressed: _enableHaptic,
                              icon: const Icon(Icons.vibration, size: 17),
                              label: const Text('开启系统触感反馈'),
                            ),
                          ),
                        ],
                      ],
                      const Divider(height: 22),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('按键音'),
                        subtitle: const Text('短促的按键声，跟随媒体音量；静音模式下只震不响'),
                        value: settings.imeSound,
                        onChanged: (v) => state.updateSettings(
                          settings.copyWith(imeSound: v),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (Platform.isAndroid) ...[
                const SectionLabel('键盘尺寸'),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(child: Text('键盘高度')),
                          Text(
                            '${_height.round()} dp',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: _height.clamp(220, 380),
                        min: 220,
                        max: 380,
                        divisions: 16,
                        label: '${_height.round()} dp',
                        onChanged: (v) => setState(() => _height = v),
                        onChangeEnd: (_) => _saveSize(),
                      ),
                      Row(
                        children: [
                          const Expanded(child: Text('按键大小')),
                          Text(
                            _scaleLabel,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: _scale.clamp(0.85, 1.3),
                        min: 0.85,
                        max: 1.3,
                        divisions: 9,
                        label: _scaleLabel,
                        onChanged: (v) => setState(() => _scale = v),
                        onChangeEnd: (_) => _saveSize(),
                      ),
                      Text(
                        '改完下次弹出键盘生效；高度还会限制在屏幕高度的 55% 以内，避免横屏占满。',
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
              const SectionLabel('输入'),
              SectionCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('使用内置键盘'),
                      subtitle: const Text(
                        '关闭后 App 内的输入框改用系统输入法（SSH 终端仍需内置键盘）',
                      ),
                      value: settings.imeBuiltin,
                      onChanged: (v) => state.updateSettings(
                        settings.copyWith(imeBuiltin: v),
                      ),
                    ),
                    const Divider(height: 22),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('英文自动纠错'),
                      subtitle: const Text('打字后按空格时，差一个字母的常见拼写会被自动改正'),
                      value: settings.imeAutocorrect,
                      onChanged: (v) => state.updateSettings(
                        settings.copyWith(imeAutocorrect: v),
                      ),
                    ),
                    const Divider(height: 22),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('默认使用中文'),
                      subtitle: const Text('打开键盘时直接进入拼音模式，可在键盘上临时切换'),
                      value: settings.imeChinese,
                      onChanged: (v) => state.updateSettings(
                        settings.copyWith(imeChinese: v),
                      ),
                    ),
                    const Divider(height: 22),
                    Row(
                      children: [
                        const Expanded(child: Text('候选词数量')),
                        DropdownButton<int>(
                          value: settings.imeCandidates.clamp(3, 7),
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(value: 3, child: Text('3')),
                            DropdownMenuItem(value: 5, child: Text('5')),
                            DropdownMenuItem(value: 7, child: Text('7')),
                          ],
                          onChanged: (v) => state.updateSettings(
                            settings.copyWith(imeCandidates: v ?? 5),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 22),
                    Row(
                      children: [
                        const Expanded(child: Text('键盘布局')),
                        DropdownButton<String>(
                          value: settings.imeLayout == 'nine' ? 'nine' : 'full',
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(value: 'full', child: Text('全键盘')),
                            DropdownMenuItem(value: 'nine', child: Text('九宫格')),
                          ],
                          onChanged: (v) => state.updateSettings(
                            settings.copyWith(imeLayout: v ?? 'full'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SectionLabel('输入法'),
              SectionCard(
                child: Column(
                  children: [
                    if (settings.imeBuiltin) ...[
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('全 App 使用内置键盘'),
                        subtitle: const Text('输入框不再切回系统输入法；多行输入仍用系统键盘'),
                        value: settings.imeGlobal,
                        onChanged: (v) => state.updateSettings(
                          settings.copyWith(imeGlobal: v),
                        ),
                      ),
                      const Divider(height: 22),
                    ],
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('模糊音'),
                      subtitle: const Text('zh/z、ch/c、sh/s 视为相同，打错也能出词'),
                      value: settings.imeFuzzy,
                      onChanged: (v) =>
                          state.updateSettings(settings.copyWith(imeFuzzy: v)),
                    ),
                    const Divider(height: 22),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('整句联想'),
                      subtitle: const Text('长串拼音自动分词，例如 woaibeijing 拼出我爱北京'),
                      value: settings.imeSentence,
                      onChanged: (v) => state.updateSettings(
                        settings.copyWith(imeSentence: v),
                      ),
                    ),
                  ],
                ),
              ),
              const SectionLabel('词库'),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FutureBuilder<PinyinEngine>(
                      future: PinyinEngine.instance(),
                      builder: (context, snapshot) {
                        final engine = snapshot.data;
                        return Text(
                          engine == null
                              ? '正在读取词库…'
                              : '离线拼音词库，共 ${engine.entryCount} 条（单字 + 词组 + 成语）',
                          style: const TextStyle(fontSize: 12),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '词库由 rime-pinyin-simp（Apache-2.0）、phrase-pinyin-data（MIT）、'
                      'jieba 词频（MIT）、CC-CEDICT（CC BY-SA 4.0）合并而成。'
                      '全部离线，不联网、不上传输入内容；支持全拼、首字母、模糊音、整句切分和九宫格。',
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

/// 键盘配色的一个色块。
class _ImeSwatch extends StatelessWidget {
  const _ImeSwatch({
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
        width: 32,
        height: 32,
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
            ? const Icon(Icons.check, size: 15, color: Colors.white)
            : null,
      ),
    );
  }
}

/// 自定义颜色：色相 / 饱和度 / 明度三条滑杆。
class _ImeColorDialog extends StatefulWidget {
  const _ImeColorDialog({required this.initial});

  final Color initial;

  @override
  State<_ImeColorDialog> createState() => _ImeColorDialogState();
}

class _ImeColorDialogState extends State<_ImeColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return AlertDialog(
      title: const Text('自定义键盘颜色'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 40,
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
              min: 0.35,
              max: 0.9,
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
