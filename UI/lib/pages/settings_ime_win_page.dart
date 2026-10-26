import 'package:flutter/material.dart';

import '../platform/ime_win.dart';
import '../theme.dart';
import '../widgets/section.dart';

/// Windows 输入法：安装/启停 + Windows 专用选项。
class SettingsImeWinPage extends StatefulWidget {
  const SettingsImeWinPage({super.key});

  @override
  State<SettingsImeWinPage> createState() => _SettingsImeWinPageState();
}

class _SettingsImeWinPageState extends State<SettingsImeWinPage> {
  ImeWinStatus _status = ImeWinStatus.unavailable;
  ImeWinConfig _config = const ImeWinConfig();
  ImeLearnStats _learn = const ImeLearnStats();
  bool _busy = false;
  bool _applying = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _config = ImeWin.readConfig();
    _refresh();
    _loadLearning();
  }

  Future<void> _loadLearning() async {
    final stats = await ImeWin.learningStats();
    if (!mounted) return;
    setState(() => _learn = stats);
  }

  Future<void> _refresh() async {
    final s = await ImeWin.status();
    if (!mounted) return;
    setState(() {
      _status = s;
    });
  }

  Future<void> _act(Future<bool> Function() fn, String ok, String fail) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    final r = await fn();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msg = r ? ok : fail;
    });
    await _refresh();
  }

  /// 改完配置后手动触发一次重新加载，省得用户去切输入法/重启程序。
  Future<void> _apply() async {
    if (_applying) return;
    setState(() {
      _applying = true;
      _msg = null;
    });
    final ok = await ImeWin.applyNow(_config);
    if (!mounted) return;
    setState(() {
      _applying = false;
      _msg = ok
          ? '已重新加载：切到输入框直接打字就生效'
          : '配置已写入，但输入法未安装，请先点「安装 / 修复」';
    });
  }

  Future<void> _saveConfig(ImeWinConfig c) async {
    setState(() => _config = c);
    await ImeWin.writeConfig(c);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存'), duration: Duration(milliseconds: 900)),
    );
  }

  Future<int?> _pickColor(int initial, String title) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => _WinColorDialog(initial: Color(initial), title: title),
    );
    return picked?.toARGB32();
  }

  Widget _swatches(int value, void Function(int) onChanged) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final color in HorseBoxTheme.presets)
          _WinSwatch(
            color: color,
            selected: color.toARGB32() == value,
            onTap: () => onChanged(color.toARGB32()),
          ),
      ],
    );
  }

  Widget _colorRow(
    String label,
    int value,
    void Function(int) onChanged,
    String title,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Color(value),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black26),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            onPressed: () async {
              final picked = await _pickColor(value, title);
              if (picked != null) onChanged(picked);
            },
            child: const Text('选择'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Text(value,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final packaged = _status.packaged;
    final installText = !packaged
        ? '输入法文件缺失'
        : (_status.registered ? '已安装' : '未注册');
    return Scaffold(
      appBar: AppBar(title: const Text('内置输入法（Windows）')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          const SectionLabel('系统输入法'),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _row('文件', packaged ? '已随程序分发' : '缺少 ime 目录'),
                _row('安装', installText),
                _row('启用', _status.enabled ? '已启用（语言列表）' : '未启用'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy || !packaged
                          ? null
                          : () => _act(ImeWin.install, '注册成功',
                              '注册失败（需要管理员确认）'),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('安装 / 修复'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !packaged
                          ? null
                          : () => _act(ImeWin.uninstall, '已卸载', '卸载失败'),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('卸载'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !packaged
                          ? null
                          : () => _act(ImeWin.enable, '已启用', '启用失败'),
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('启用'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !packaged
                          ? null
                          : () => _act(ImeWin.disable, '已禁用', '禁用失败'),
                      icon: const Icon(Icons.cancel_outlined, size: 18),
                      label: const Text('禁用'),
                    ),
                    TextButton.icon(
                      onPressed: ImeWin.openLanguageSettings,
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      label: const Text('系统语言设置'),
                    ),
                  ],
                ),
                if (_msg != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_msg!,
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
              ],
            ),
          ),
          const SectionLabel('Windows 专用选项'),
          SectionCard(
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('候选数量'),
                  subtitle: const Text('候选窗最多显示几个词'),
                  trailing: DropdownButton<int>(
                    value: _config.candidates.clamp(3, 9),
                    items: [
                      for (var i = 3; i <= 9; i++)
                        DropdownMenuItem(value: i, child: Text('$i')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      _saveConfig(_config.copyWith(candidates: v));
                    },
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('模糊音'),
                  subtitle: const Text('zh/z、ch/c、sh/s 视为相同，打错也能出词'),
                  value: _config.fuzzy,
                  onChanged: (v) => _saveConfig(_config.copyWith(fuzzy: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('整句联想'),
                  subtitle: const Text('长串拼音自动分词，例如 woaibeijing 拼出我爱北京'),
                  value: _config.sentence,
                  onChanged: (v) => _saveConfig(_config.copyWith(sentence: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('繁体中文'),
                  subtitle: const Text('开启后候选和上屏都转成繁体；Shift 只在简体/英文之间切换'),
                  value: _config.traditional,
                  onChanged: (v) => _saveConfig(_config.copyWith(traditional: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('英文联想'),
                  subtitle: const Text('英文模式下也弹候选框；关掉则字母直接进输入框'),
                  value: _config.english,
                  onChanged: (v) => _saveConfig(_config.copyWith(english: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('词频记忆'),
                  subtitle: const Text('记住你选过的词，同一个拼音下次排前面；只记在本机'),
                  value: _config.learn,
                  onChanged: (v) => _saveConfig(_config.copyWith(learn: v)),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('候选窗主题'),
                  trailing: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'light', label: Text('浅色')),
                      ButtonSegment(value: 'dark', label: Text('深色')),
                    ],
                    selected: {_config.theme},
                    onSelectionChanged: (s) =>
                        _saveConfig(_config.copyWith(theme: s.first)),
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('候选窗外观'),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('明暗', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'light', label: Text('浅色')),
                    ButtonSegment(value: 'dark', label: Text('深色')),
                    ButtonSegment(value: 'system', label: Text('跟随系统')),
                  ],
                  selected: {_config.theme},
                  onSelectionChanged: (s) =>
                      _saveConfig(_config.copyWith(theme: s.first)),
                ),
                const SizedBox(height: 14),
                const Text('主色', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 2),
                const Text(
                  '选中候选的高亮色；想精确调可以点「自定义颜色」。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                _swatches(
                  _config.accent,
                  (v) => _saveConfig(_config.copyWith(accent: v)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Color(_config.accent),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: () async {
                        final picked = await _pickColor(_config.accent, '主色');
                        if (picked != null) {
                          _saveConfig(_config.copyWith(accent: picked));
                        }
                      },
                      child: const Text('自定义颜色'),
                    ),
                  ],
                ),
                const Divider(height: 24),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自定义整套颜色'),
                  subtitle: const Text('单独设置候选窗背景、文字和边框'),
                  value: _config.palette,
                  onChanged: (v) => _saveConfig(_config.copyWith(palette: v)),
                ),
                if (_config.palette) ...[
                  _colorRow(
                    '背景',
                    _config.bg,
                    (v) => _saveConfig(_config.copyWith(bg: v)),
                    '候选窗背景',
                  ),
                  _colorRow(
                    '文字',
                    _config.fg,
                    (v) => _saveConfig(_config.copyWith(fg: v)),
                    '候选文字',
                  ),
                  _colorRow(
                    '边框',
                    _config.border,
                    (v) => _saveConfig(_config.copyWith(border: v)),
                    '候选窗边框',
                  ),
                ],
              ],
            ),
          ),
          const SectionLabel('应用设置'),
          SectionCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('重新加载配置'),
              subtitle: const Text('改完选项点一下，输入法下次按键就用新配置，不用重启程序'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_applying) ...[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                  ],
                  FilledButton(
                    onPressed: _applying ? null : _apply,
                    child: Text(_applying ? '加载中…' : '重新加载'),
                  ),
                ],
              ),
            ),
          ),
          const SectionLabel('数据'),
          SectionCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('学习记录'),
              subtitle: Text(
                _learn.total == 0
                    ? '还没有学习记录；选过的字词会记在这里'
                    : '单字 ${_learn.chars} 个 · 词语 ${_learn.words} 个（共 ${_learn.total} 条）',
              ),
              trailing: TextButton(
                onPressed: () async {
                  await ImeWin.clearLearning();
                  await _loadLearning();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已清空学习记录')),
                  );
                },
                child: const Text('清空'),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 4, 0),
            child: Text(
              '提示：每次改动都会立刻存盘；想让当前打开的程序也用上，点上面的「重新加载」或切一下焦点。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

class _WinSwatch extends StatelessWidget {
  const _WinSwatch({
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
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: 30,
        height: 30,
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
      ),
    );
  }
}

/// 候选窗配色用的取色器：色相 / 饱和度 / 明度三条滑杆。
class _WinColorDialog extends StatefulWidget {
  const _WinColorDialog({required this.initial, required this.title});

  final Color initial;
  final String title;

  @override
  State<_WinColorDialog> createState() => _WinColorDialogState();
}

class _WinColorDialogState extends State<_WinColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
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
            Text('色相 ${_hsv.hue.round()}', style: const TextStyle(fontSize: 12)),
            Slider(
              value: _hsv.hue,
              max: 360,
              onChanged: (v) => setState(() => _hsv = _hsv.withHue(v)),
            ),
            Text('饱和度 ${(_hsv.saturation * 100).round()}%',
                style: const TextStyle(fontSize: 12)),
            Slider(
              value: _hsv.saturation,
              onChanged: (v) => setState(() => _hsv = _hsv.withSaturation(v)),
            ),
            Text('明度 ${(_hsv.value * 100).round()}%',
                style: const TextStyle(fontSize: 12)),
            Slider(
              value: _hsv.value,
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
