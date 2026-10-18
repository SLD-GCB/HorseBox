import 'dart:io';

import 'package:path/path.dart' as p;

/// 定位 sing-box 可执行文件。
///
/// 查找顺序（不做全盘搜索）：
///   1. 显式传入的路径
///   2. 环境变量 HORSEBOX_CORE
///   3. 可执行文件旁的 core/sing-box.exe
///   4. 当前目录下的 core/sing-box.exe
///   5. 当前目录上一级的 core/sing-box.exe（flutter run 时）
String resolveCoreBinary({String? override}) {
  final candidates = <String>[
    if (override != null && override.trim().isNotEmpty) override.trim(),
    if ((Platform.environment['HORSEBOX_CORE'] ?? '').isNotEmpty)
      Platform.environment['HORSEBOX_CORE']!,
    p.join(p.dirname(Platform.resolvedExecutable), 'core', 'sing-box.exe'),
    p.join(Directory.current.path, 'core', 'sing-box.exe'),
    p.join(Directory.current.path, '..', 'core', 'sing-box.exe'),
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return p.normalize(path);
  }
  throw StateError(
    '找不到 sing-box 内核。请把 core/sing-box.exe 放到程序目录，'
    '或设置环境变量 HORSEBOX_CORE。',
  );
}
