import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:path/path.dart' as p;

/// 敏感字段（订阅地址里的令牌、SSH 密码）落盘前加密。
///
/// 密钥是首次启动随机生成、写在应用数据目录的 secret.key 里：
/// Android 在应用私有目录（其他应用读不到），Windows 在 LOCALAPPDATA 下的
/// HorseBox 目录（按用户 ACL 保护）。配置文件里只有 AES-GCM 密文，
/// 直接打开 settings.json 看不到明文。
class SecretVault {
  SecretVault._(this._key);

  static const _fileName = 'secret.key';
  static const _prefix = 'enc1:';
  static const _nonceLength = 12;
  static const _macLength = 16;

  final cg.SecretKey _key;
  final _algorithm = cg.AesGcm.with256bits();

  static SecretVault? _instance;

  /// 读不到也写不了密钥时返回 null，调用方退回明文（不影响功能）。
  static Future<SecretVault?> open(String dataDir) async {
    final cached = _instance;
    if (cached != null) return cached;
    try {
      final file = File(p.join(dataDir, _fileName));
      List<int> bytes;
      if (await file.exists()) {
        bytes = base64Decode((await file.readAsString()).trim());
      } else {
        bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
        await file.parent.create(recursive: true);
        await file.writeAsString(base64Encode(bytes), flush: true);
      }
      if (bytes.length != 32) return null;
      return _instance = SecretVault._(cg.SecretKey(bytes));
    } catch (_) {
      return null;
    }
  }

  static bool isSealed(String value) => value.startsWith(_prefix);

  Future<String> seal(String plain) async {
    if (plain.isEmpty) return '';
    final box = await _algorithm.encrypt(utf8.encode(plain), secretKey: _key);
    final bytes = <int>[...box.nonce, ...box.cipherText, ...box.mac.bytes];
    return _prefix + base64Encode(bytes);
  }

  /// 明文（老数据）原样返回，方便迁移。
  Future<String> openText(String stored) async {
    if (stored.isEmpty || !stored.startsWith(_prefix)) return stored;
    try {
      final bytes = base64Decode(stored.substring(_prefix.length));
      if (bytes.length <= _nonceLength + _macLength) return '';
      final nonce = bytes.sublist(0, _nonceLength);
      final mac = bytes.sublist(bytes.length - _macLength);
      final cipher = bytes.sublist(_nonceLength, bytes.length - _macLength);
      final clear = await _algorithm.decrypt(
        cg.SecretBox(cipher, nonce: nonce, mac: cg.Mac(mac)),
        secretKey: _key,
      );
      return utf8.decode(clear);
    } catch (_) {
      return '';
    }
  }
}
