import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../security/data_backup.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../widgets/masked_field.dart';
import '../widgets/password_keyboard.dart';
import '../widgets/section.dart';

/// 备份管理：整包导出/导入，口令加密。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.state});

  final AppState state;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;

  AppState get _state => widget.state;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('备份管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        children: [
          if (_busy) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 14),
          ],
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '完整备份',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  '包含订阅、SSH 主机、密码本、规则，以及全部设置（主题色、输入法偏好、DNS、分流等）；'
                  '不包含内核和日志。备份文件用你设置的口令加密，可以放到任何位置。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _export,
                      icon: const Icon(Icons.save_alt, size: 17),
                      label: const Text('导出备份'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.restore, size: 17),
                      label: const Text('导入备份'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '注意事项',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '· 口令只在你脑子里，忘记后备份无法恢复；\n'
                  '· 备份文件等同于你的密码本，别放公共网盘；\n'
                  '· 导入会整体覆盖当前数据，旧数据会改名保留在数据目录旁边；\n'
                  '· 恢复完成后需要重新打开 App。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    final passphrase = await _askPassphrase(confirm: true);
    if (passphrase == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await BackupService.export(
        dataDir: _state.dataDir,
        passphrase: passphrase,
      );
      if (!mounted) return;
      final uri = await FilePicker.saveFile(
        fileName: 'HorseBox-${_stamp()}.hbbk',
        bytes: bytes,
        mimeType: 'application/octet-stream',
        dialogTitle: '保存备份',
      );
      if (!mounted) return;
      if (uri == null) {
        _toast('已取消保存');
        return;
      }
      _toast('备份已保存（${formatBytes(bytes.length)}）');
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(dialogTitle: '选择备份文件');
    } catch (e) {
      _toast('打开文件选择器失败：$e');
      return;
    }
    if (picked.isEmpty) return;
    final path = picked.first.path;
    if (path == null) {
      _toast('无法读取该文件');
      return;
    }
    final passphrase = await _askPassphrase(confirm: false);
    if (passphrase == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await File(path).readAsBytes();
      final payload = await BackupService.inspect(
        bytes: bytes,
        passphrase: passphrase,
      );
      if (!mounted) return;
      final ok = await _confirmRestore(payload);
      if (ok != true) return;
      await BackupService.apply(dataDir: _state.dataDir, payload: payload);
      if (!mounted) return;
      await _finishAndExit();
    } catch (e) {
      _toast('恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPassphrase({required bool confirm}) async {
    final first = MaskedTextController();
    final second = MaskedTextController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          return AlertDialog(
            title: Text(confirm ? '设置备份口令' : '输入备份口令'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    confirm ? '备份会用这个口令加密，至少 8 位。忘记后无法恢复。' : '输入导出时设置的口令。',
                    style: const TextStyle(fontSize: 11.5, height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  SecretField(controller: first, label: '口令'),
                  if (confirm) ...[
                    const SizedBox(height: 12),
                    SecretField(controller: second, label: '再输一次'),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
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
                  final text = first.text;
                  if (text.length < 8) {
                    setLocal(() => error = '口令至少 8 位');
                    return;
                  }
                  if (confirm && text != second.text) {
                    setLocal(() => error = '两次输入不一致');
                    return;
                  }
                  Navigator.of(context).pop(text);
                },
                child: Text(confirm ? '导出' : '恢复'),
              ),
            ],
          );
        },
      ),
    );
    first.dispose();
    second.dispose();
    return result;
  }

  Future<bool?> _confirmRestore(BackupPayload payload) {
    final created = payload.created;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认恢复'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将覆盖当前全部数据：'
                '${payload.profiles} 个订阅、${payload.sshHosts} 台 SSH 主机、'
                '${payload.credentials} 条密码本记录。',
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 8),
              Text(
                '包含偏好：${_preferenceLabel(payload)}',
                style: const TextStyle(fontSize: 11.5),
              ),
              if (created != null) ...[
                const SizedBox(height: 4),
                Text(
                  '备份时间：${created.toLocal()}',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ],
              const SizedBox(height: 10),
              const Text(
                '当前数据会被改名保留在数据目录旁边，不会删除。',
                style: TextStyle(fontSize: 11.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('覆盖并恢复'),
          ),
        ],
      ),
    );
  }

  /// 把备份里的偏好拼成一句话，恢复前让用户确认带过来的是什么。
  String _preferenceLabel(BackupPayload payload) {
    final parts = <String>[
      switch (payload.themeMode) {
        'light' => '浅色主题',
        'system' => '跟随系统主题',
        _ => '深色主题',
      },
      '自定义主色',
      payload.imeChinese ? '中文输入' : '英文输入',
      payload.imeNine ? '九宫格' : '全键盘',
    ];
    if (payload.imeFuzzy) parts.add('模糊音');
    if (payload.imeSentence) parts.add('整句联想');
    if (payload.imeGlobal) parts.add('全 App 内置键盘');
    return parts.join(' · ');
  }

  Future<void> _finishAndExit() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('恢复完成'),
        content: const Text('数据已恢复，App 会关闭，请重新打开生效。'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
    if (Platform.isAndroid) {
      await SystemNavigator.pop();
    } else {
      exit(0);
    }
  }

  String _stamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}';
  }
}
