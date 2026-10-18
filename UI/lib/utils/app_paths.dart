import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Windows 默认数据目录：%APPDATA%\HorseBox
String defaultWindowsDataDir() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    return p.join(Directory.current.path, 'data');
  }
  return p.join(appData, 'HorseBox');
}

/// 数据目录指针文件固定放在默认目录，避免自定义目录后找不到自己。
File _pointerFile() => File(p.join(defaultWindowsDataDir(), 'bootstrap.json'));

Future<String> resolveWindowsDataDir() async {
  final fallback = defaultWindowsDataDir();
  try {
    final file = _pointerFile();
    if (!await file.exists()) return fallback;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return fallback;
    final custom = (decoded['data_dir'] as String? ?? '').trim();
    if (custom.isEmpty) return fallback;
    if (!await Directory(custom).exists()) return fallback;
    return custom;
  } catch (_) {
    return fallback;
  }
}

Future<void> writeWindowsDataDir(String dataDir) async {
  final fallback = defaultWindowsDataDir();
  await Directory(fallback).create(recursive: true);
  await _pointerFile().writeAsString(
    const JsonEncoder.withIndent('  ').convert({'data_dir': dataDir}),
    flush: true,
  );
}

/// 把旧数据目录复制到新目录，保留订阅、设置和 core 配置。
Future<void> copyDataDir(String from, String to) async {
  final source = Directory(from);
  if (!await source.exists()) return;
  await Directory(to).create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: from);
    if (relative == 'bootstrap.json') continue;
    final target = p.join(to, relative);
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await Directory(p.dirname(target)).create(recursive: true);
      await entity.copy(target);
    }
  }
}
