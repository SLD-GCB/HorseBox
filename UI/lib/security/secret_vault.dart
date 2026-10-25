import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:path/path.dart' as p;

import 'dpapi.dart';

/// 敏感字段（订阅地址里的令牌、SSH 密码）落盘前加密。
///
/// 密钥是首次启动随机生成的 32 字节：
/// - Windows：用 DPAPI（当前用户）包一层再写进 secret.key，换机器/换账户都解不开；
/// - Android：写在应用私有目录（其他应用读不到）。
/// 配置文件里只有 AES-GCM 密文，直接打开 settings.json 看不到明文。
class SecretVault {
  SecretVault._(this._key);

  static const _fileName = 'secret.key';

  /// Windows 上密钥文件本身用 DPAPI 包一层，明文 base64 不再落盘。
  static const _dpapiPrefix = 'dpapi1:';
  static const _prefix = 'enc1:';
  static const _nonceLength = 12;
  static const _macLength = 16;

  final cg.SecretKey _key;
  final _algorithm = cg.AesGcm.with256bits();

  static SecretVault? _instance;

  /// 读不到密钥时返回 null；调用方必须当作"不能落盘"处理，不许退回明文。
  static Future<SecretVault?> open(String dataDir) async {
    final cached = _instance;
    if (cached != null) return cached;
    try {
      final file = File(p.join(dataDir, _fileName));
      List<int> bytes;
      if (await file.exists()) {
        final raw = (await file.readAsString()).trim();
        final wrapped = raw.startsWith(_dpapiPrefix);
        if (wrapped) {
          final plain = Dpapi.unprotect(base64Decode(raw.substring(_dpapiPrefix.length)));
          if (plain == null) return null;   // 换机器/换账户后解不开，交给调用方报错
          bytes = plain;
        } else {
          bytes = base64Decode(raw);
        }
        if (!wrapped && Dpapi.supported) {
          // 老版本明文密钥，读一次就迁成密文
          await _write(file, bytes);
        }
      } else {
        bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
        await file.parent.create(recursive: true);
        await _write(file, bytes);
      }
      if (bytes.length != 32) return null;
      return _instance = SecretVault._(cg.SecretKey(bytes));
    } catch (_) {
      return null;
    }
  }

  /// 写密钥：Windows 必须 DPAPI 包一层，包不上就报错，绝不写明文。
  static Future<void> _write(File file, List<int> raw) async {
    if (Dpapi.supported) {
      final sealed = Dpapi.protect(raw);
      if (sealed == null) throw StateError('DPAPI 不可用');
      await file.writeAsString(_dpapiPrefix + base64Encode(sealed), flush: true);
    } else {
      await file.writeAsString(base64Encode(raw), flush: true);
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
