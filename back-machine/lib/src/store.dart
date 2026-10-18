import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 极简 JSON 文件存储，避免引入平台插件。
class LocalStore {
  LocalStore._(this._file, this._data);

  final File _file;
  Map<String, dynamic> _data;

  static Future<LocalStore> open(String dir) async {
    final directory = Directory(dir);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final file = File(p.join(dir, 'settings.json'));
    var data = <String, dynamic>{};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {
        // 文件损坏时从空白配置开始，不让客户端起不来。
      }
    }
    return LocalStore._(file, data);
  }

  dynamic get(String key) => _data[key];

  String? getString(String key) {
    final value = _data[key];
    return value is String ? value : null;
  }

  int? getInt(String key) {
    final value = _data[key];
    return value is num ? value.toInt() : null;
  }

  bool? getBool(String key) {
    final value = _data[key];
    return value is bool ? value : null;
  }

  Future<void> set(String key, Object? value) async {
    _data[key] = value;
    await _flush();
  }

  Future<void> remove(String key) async {
    _data.remove(key);
    await _flush();
  }

  Future<void> _flush() async {
    await _file.writeAsString(jsonEncode(_data), flush: true);
  }
}
