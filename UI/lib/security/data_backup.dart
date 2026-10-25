import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:path/path.dart' as p;

import 'dpapi.dart';

/// 备份/恢复用到的异常，消息直接展示给用户。
class BackupException implements Exception {
  BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解开后的备份内容：相对路径 -> 字节。
class BackupPayload {
  BackupPayload({
    required this.files,
    required this.counts,
    required this.preferences,
    required this.created,
    this.dataDir = '',
  });

  final Map<String, List<int>> files;
  final Map<String, int> counts;

  /// 关键偏好（主题、输入法等），只为恢复前给用户看清楚，恢复本身靠 settings.json。
  final Map<String, dynamic> preferences;
  final DateTime? created;

  /// 导出时所在的数据目录（Windows 可能是自定义路径），恢复时可以照原样放回去。
  final String dataDir;

  int get profiles => counts['profiles'] ?? 0;

  int get sshHosts => counts['ssh_hosts'] ?? 0;

  int get credentials => counts['panel_credentials'] ?? 0;

  String get themeMode => preferences['theme_mode'] as String? ?? 'dark';

  int get accent => (preferences['accent'] as num?)?.toInt() ?? 0xFF4C8F6F;

  bool get imeChinese => preferences['ime_chinese'] as bool? ?? false;

  bool get imeFuzzy => preferences['ime_fuzzy'] as bool? ?? true;

  bool get imeSentence => preferences['ime_sentence'] as bool? ?? true;

  bool get imeGlobal => preferences['ime_global'] as bool? ?? false;

  bool get imeBuiltin => preferences['ime_builtin'] as bool? ?? true;

  bool get imeAutocorrect => preferences['ime_autocorrect'] as bool? ?? true;

  bool get imeSound => preferences['ime_sound'] as bool? ?? false;

  bool get imeVibrate => preferences['ime_vibrate'] as bool? ?? true;

  bool get imeCustomPalette =>
      preferences['ime_custom_palette'] as bool? ?? false;

  /// 键盘明暗：app / system。
  String get imeDarkMode => preferences['ime_dark_mode'] as String? ?? 'app';

  bool get imeNine => preferences['ime_layout'] == 'nine';
}

/// 整包备份：整个数据目录（设置、secret.key、规则、词频、剪贴板等），用口令重新加密后写成一个文件。
///
/// 内部敏感字段仍由设备密钥（secret.key）加密，所以包里必须带上它，
/// 否则恢复到另一台设备后解不出订阅地址和密码。
class BackupService {
  static const _magic = 'HBBK1';
  static const _version = 1;
  static const _saltLength = 16;
  static const _nonceLength = 12;
  static const _macLength = 16;
  static const _iterations = 200000;

  /// 打包并加密，返回整个备份文件的字节。
  static Future<Uint8List> export({
    required String dataDir,
    required String passphrase,
  }) async {
    final settings = File(p.join(dataDir, 'settings.json'));
    if (!await settings.exists()) {
      throw BackupException('数据目录里没有 settings.json，无法备份');
    }
    // 整个数据目录都打包：设置、设备密钥、规则、词频、剪贴板、面板配置……
    // 只跳过日志/缓存这类可重建的东西，以及上一次恢复留下的旧目录。
    final files = await _collect(dataDir);
    await _unwrapForBackup(files);
    if (!files.containsKey('settings.json')) {
      throw BackupException('数据目录里没有 settings.json，无法备份');
    }
    final payload = <String, dynamic>{
      'format': _version,
      'created': DateTime.now().toIso8601String(),
      'data_dir': dataDir,
      'counts': _counts(files['settings.json']!),
      'preferences': _preferences(files['settings.json']!),
      'entries': [
        for (final entry in files.entries)
          {'path': entry.key, 'data': base64Encode(entry.value)},
      ],
    };
    return _seal(utf8.encode(jsonEncode(payload)), passphrase);
  }

  /// 需要跳过的目录：日志、缓存、运行时工作目录。
  static const _skipDirs = {'logs', 'cache', 'tmp'};

  /// 单个文件上限：超过的多半是内核或缓存，没必要塞进备份。
  static const _maxFileBytes = 32 * 1024 * 1024;

  static Future<Map<String, List<int>>> _collect(String dataDir) async {
    final out = <String, List<int>>{};
    final root = Directory(dataDir);
    if (!await root.exists()) return out;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: dataDir).replaceAll('\\', '/');
      if (rel.contains('.backup-') || rel.contains('.restore-')) continue;
      final parts = rel.split('/');
      if (parts.any(_skipDirs.contains)) continue;
      if (rel.endsWith('.log') || rel.endsWith('.db')) continue;
      if (p.basename(rel) == 'ime_log.txt') continue;  // 输入法调试日志，没必要进备份
      try {
        final stat = await entity.stat();
        if (stat.size > _maxFileBytes) continue;
        out[rel] = await entity.readAsBytes();
      } catch (_) {
        // 单个文件读不出来就跳过，不要因此整包失败。
      }
    }
    return out;
  }

  /// 备份里要放"换台机器也能用"的形态：DPAPI 密文只有本机本账户能解，
  /// 所以导出前先拆掉这层壳（密钥、学习记录），再由备份本身的口令加密保护。
  /// 恢复时不用反过来处理：App 启动读 secret.key、输入法第一次上屏写学习记录时，都会自动重新套壳。
  static Future<void> _unwrapForBackup(Map<String, List<int>> files) async {
    final key = files['secret.key'];
    if (key != null) {
      final text = utf8.decode(key, allowMalformed: true).trim();
      if (text.startsWith('dpapi1:')) {
        final plain = Dpapi.unprotect(base64Decode(text.substring(7)));
        if (plain != null) files['secret.key'] = utf8.encode(base64Encode(plain));
      }
    }
    final learned = files['ime_learned.txt'];
    if (learned != null) {
      final plain = Dpapi.unprotect(learned);
      if (plain != null) files['ime_learned.txt'] = plain;
    }
    // 内核运行配置（含节点地址和密码）平时也是 DPAPI 密文
    final core = files['core/config.json'];
    if (core != null) {
      final plain = Dpapi.unprotect(core);
      if (plain != null) files['core/config.json'] = plain;
    }
  }

  /// 校验口令并解析备份；口令错误或文件损坏都会抛出 [BackupException]。
  static Future<BackupPayload> inspect({
    required List<int> bytes,
    required String passphrase,
  }) async {
    final clear = await _open(bytes, passphrase);
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map) throw BackupException('备份内容格式不正确');
    final entries = decoded['entries'];
    if (entries is! List) throw BackupException('备份里缺少文件清单');

    final files = <String, List<int>>{};
    for (final item in entries) {
      if (item is! Map) continue;
      final path = item['path'];
      final data = item['data'];
      if (path is! String || data is! String) continue;
      if (!_safePath(path)) {
        throw BackupException('备份里包含非法路径：$path');
      }
      files[path] = base64Decode(data);
    }
    if (!files.containsKey('settings.json')) {
      throw BackupException('备份里没有 settings.json');
    }
    final rawCounts = decoded['counts'];
    final counts = <String, int>{};
    if (rawCounts is Map) {
      for (final entry in rawCounts.entries) {
        final value = entry.value;
        if (value is num) counts['${entry.key}'] = value.toInt();
      }
    }
    final rawPreferences = decoded['preferences'];
    return BackupPayload(
      files: files,
      counts: counts,
      preferences: rawPreferences is Map
          ? Map<String, dynamic>.from(rawPreferences)
          : const {},
      created: DateTime.tryParse(decoded['created'] as String? ?? ''),
      dataDir: (decoded['data_dir'] as String? ?? '').trim(),
    );
  }

  /// 把解开的备份写进数据目录。原目录只改名、不删除，失败时改回来。
  ///
  /// 返回旧数据被改名到的位置，用户可以据此手动回退。
  static Future<String> apply({
    required String dataDir,
    required BackupPayload payload,
  }) async {
    final tmp = Directory('$dataDir.restore-tmp');
    if (await tmp.exists()) await tmp.delete(recursive: true);
    await tmp.create(recursive: true);
    try {
      for (final entry in payload.files.entries) {
        final target = File(p.join(tmp.path, p.joinAll(entry.key.split('/'))));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.value, flush: true);
      }
      // 先在临时目录里验证，确认能解析再动原目录。
      final settings = File(p.join(tmp.path, 'settings.json'));
      final parsed = jsonDecode(utf8.decode(await settings.readAsBytes()));
      if (parsed is! Map) throw BackupException('备份里的 settings.json 无法解析');
      final keyFile = File(p.join(tmp.path, 'secret.key'));
      if (await keyFile.exists()) {
        final raw = base64Decode((await keyFile.readAsString()).trim());
        if (raw.length != 32) {
          throw BackupException('备份里的 secret.key 长度不正确');
        }
      }
    } catch (e) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
      if (e is BackupException) rethrow;
      throw BackupException('备份内容无法写入：$e');
    }

    final backupDir =
        '$dataDir.backup-${DateTime.now().microsecondsSinceEpoch}';
    final marker = File('$dataDir.restore-pending');
    await marker.writeAsString(backupDir, flush: true);
    var moved = false;
    try {
      final current = Directory(dataDir);
      if (await current.exists()) {
        await current.rename(backupDir);
        moved = true;
      }
      await tmp.rename(dataDir);
      await marker.delete();
      return backupDir;
    } catch (e) {
      try {
        final broken = Directory(dataDir);
        if (await broken.exists()) await broken.delete(recursive: true);
      } catch (_) {}
      if (moved) {
        try {
          await Directory(backupDir).rename(dataDir);
        } catch (_) {}
      }
      throw BackupException('恢复失败，已回退到原来的数据：$e');
    }
  }

  /// 上次恢复如果在改名途中被中断，下次启动时把备份目录改回来。
  static Future<void> recoverIfNeeded(String dataDir) async {
    final marker = File('$dataDir.restore-pending');
    try {
      if (!await marker.exists()) return;
      final backupDir = (await marker.readAsString()).trim();
      if (backupDir.isNotEmpty && await Directory(backupDir).exists()) {
        final current = Directory(dataDir);
        if (await current.exists()) await current.delete(recursive: true);
        await Directory(backupDir).rename(dataDir);
      }
      await marker.delete();
    } catch (_) {
      // 回滚失败也没别的办法，至少不要让 App 起不来。
    }
  }

  static Future<Uint8List> _seal(List<int> clear, String passphrase) async {
    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    final key = await _deriveKey(passphrase, salt);
    final box = await cg.AesGcm.with256bits().encrypt(
      clear,
      secretKey: key,
      nonce: nonce,
    );
    final out = BytesBuilder(copy: false);
    out.add(utf8.encode(_magic));
    out.addByte(_version);
    out.add(salt);
    out.add(nonce);
    out.add(_uint32(box.cipherText.length));
    out.add(box.cipherText);
    out.add(box.mac.bytes);
    return out.takeBytes();
  }

  static Future<List<int>> _open(List<int> bytes, String passphrase) async {
    final headerLength = 5 + 1 + _saltLength + _nonceLength + 4;
    if (bytes.length < headerLength + _macLength) {
      throw BackupException('文件太短，不是有效的备份');
    }
    if (String.fromCharCodes(bytes.sublist(0, _magic.length)) != _magic) {
      throw BackupException('这不是 HorseBox 的备份文件');
    }
    final version = bytes[5];
    if (version > _version) {
      throw BackupException('备份来自更新的版本，请先升级 App');
    }
    final salt = bytes.sublist(6, 6 + _saltLength);
    final nonceStart = 6 + _saltLength;
    final nonce = bytes.sublist(nonceStart, nonceStart + _nonceLength);
    final lengthPos = nonceStart + _nonceLength;
    final cipherLength = _readUint32(bytes.sublist(lengthPos, lengthPos + 4));
    final cipherStart = lengthPos + 4;
    final cipherEnd = cipherStart + cipherLength;
    if (cipherLength <= 0 || cipherEnd + _macLength > bytes.length) {
      throw BackupException('备份文件不完整');
    }
    final cipher = bytes.sublist(cipherStart, cipherEnd);
    final mac = bytes.sublist(cipherEnd, cipherEnd + _macLength);
    final key = await _deriveKey(passphrase, salt);
    try {
      return await cg.AesGcm.with256bits().decrypt(
        cg.SecretBox(cipher, nonce: nonce, mac: cg.Mac(mac)),
        secretKey: key,
      );
    } on cg.SecretBoxAuthenticationError {
      throw BackupException('口令不正确，或文件已损坏');
    }
  }

  static Future<cg.SecretKey> _deriveKey(String passphrase, List<int> salt) {
    return cg.Pbkdf2.hmacSha256(
      iterations: _iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: passphrase, nonce: salt);
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static List<int> _uint32(int value) {
    return [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];
  }

  static int _readUint32(List<int> bytes) {
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }

  /// 只接受相对路径，且不能跳出数据目录。
  static bool _safePath(String path) {
    if (path.isEmpty || path.startsWith('/') || path.contains(':')) {
      return false;
    }
    if (path.contains('\\')) return false;
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.' || part == '..') return false;
    }
    return true;
  }

  /// 挑出几项用户能直观理解的偏好，导出时写进清单，恢复前展示。
  static Map<String, dynamic> _preferences(List<int> settingsBytes) {
    try {
      final decoded = jsonDecode(utf8.decode(settingsBytes));
      if (decoded is! Map) return const {};
      return {
        'theme_mode': decoded['theme_mode'],
        'accent': decoded['accent'],
        'ime_chinese': decoded['ime_chinese'],
        'ime_layout': decoded['ime_layout'],
        'ime_fuzzy': decoded['ime_fuzzy'],
        'ime_sentence': decoded['ime_sentence'],
        'ime_global': decoded['ime_global'],
        'ime_builtin': decoded['ime_builtin'],
        'ime_dark_mode': decoded['ime_dark_mode'],
        'ime_accent_mode': decoded['ime_accent_mode'],
        'ime_custom_palette': decoded['ime_custom_palette'],
        'ime_autocorrect': decoded['ime_autocorrect'],
        'ime_sound': decoded['ime_sound'],
        'ime_vibrate': decoded['ime_vibrate'],
      };
    } catch (_) {
      return const {};
    }
  }

  static Map<String, int> _counts(List<int> settingsBytes) {
    try {
      final decoded = jsonDecode(utf8.decode(settingsBytes));
      if (decoded is! Map) return const {};
      int len(Object? value) => value is List ? value.length : 0;
      return {
        'profiles': len(decoded['profiles']),
        'ssh_hosts': len(decoded['ssh_hosts']),
        'panel_credentials': len(decoded['panel_credentials']),
      };
    } catch (_) {
      return const {};
    }
  }
}
