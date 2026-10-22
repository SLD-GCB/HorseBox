import 'package:flutter/material.dart';

import '../ime/pinyin_engine.dart';
import '../state/app_state.dart';
import '../widgets/section.dart';

/// 内置输入法设置：中文/英文、候选数量、按键反馈。
class SettingsImePage extends StatelessWidget {
  const SettingsImePage({super.key, required this.state});

  final AppState state;

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
              const SectionLabel('输入'),
              SectionCard(
                child: Column(
                  children: [
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
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('全 App 使用内置键盘'),
                      subtitle: const Text('输入框不再切回系统输入法；多行输入仍用系统键盘'),
                      value: settings.imeGlobal,
                      onChanged: (v) =>
                          state.updateSettings(settings.copyWith(imeGlobal: v)),
                    ),
                    const Divider(height: 22),
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
                      subtitle: const Text('长串拼音自动分词，例如 woaibeijing → 我爱北京'),
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
                              : '离线拼音词库，共 ${engine.entryCount} 条（单字 + 常用词组）',
                          style: const TextStyle(fontSize: 12),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '数据来自 rime-pinyin-simp（Apache-2.0），全部离线，不联网、不上传输入内容。'
                      '支持全拼与首字母，暂不支持模糊音和整句联想。',
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
