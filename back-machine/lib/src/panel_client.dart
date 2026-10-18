import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 面板预检失败，message 直接展示给用户。
class PanelProbeException implements Exception {
  PanelProbeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 面板访问前的 TLS 预检。
///
/// WebView 本身拿不到服务端证书，无法做指纹固定，所以在加载页面前
/// 先用 HttpClient 连一次 `/api/ping`，证书指纹不一致就直接拒绝。
class PanelClient {
  static String normalizePin(String pin) =>
      pin.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();

  static bool isValidPin(String pin) => normalizePin(pin).length == 64;

  static String fingerprint(X509Certificate cert) =>
      sha256.convert(cert.der).toString();

  static Future<void> probe(
    String rawUrl,
    String rawPin, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) {
      throw PanelProbeException('面板地址必须以 https:// 开头');
    }
    final pin = normalizePin(rawPin);
    if (pin.length != 64) {
      throw PanelProbeException('请先在设置里填写 64 位证书指纹');
    }

    final ping = Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/api/ping',
    );

    final client = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = (cert, host, port) =>
          fingerprint(cert) == pin;

    try {
      final request = await client.getUrl(ping).timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw PanelProbeException('面板返回 HTTP ${response.statusCode}');
      }
    } on HandshakeException {
      throw PanelProbeException('证书校验失败：指纹与面板不一致');
    } on TimeoutException {
      throw PanelProbeException('连接面板超时');
    } on SocketException catch (e) {
      throw PanelProbeException('无法连接面板：${e.message}');
    } finally {
      client.close(force: true);
    }
  }
}
