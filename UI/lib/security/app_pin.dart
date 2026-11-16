import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Windows 应用锁的本机 PIN：只保存哈希和盐。
class AppPin {
  static const length = 6;

  static String newSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static String hash(String pin, String salt) {
    return sha256.convert(utf8.encode('$salt:$pin')).toString();
  }

  static bool verify(String pin, String salt, String expected) {
    if (pin.length != length || salt.isEmpty || expected.isEmpty) return false;
    return hash(pin, salt) == expected;
  }
}
