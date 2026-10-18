import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 订阅拉取失败，message 直接展示给用户。
class SubscriptionException implements Exception {
  SubscriptionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 订阅客户端。
///
/// 面板常用自签证书，因此这里用证书指纹做固定校验（双端一致）：
/// 设置里填了 SHA-256 指纹就只信任该证书，没填则拒绝自签证书并提示去设置。
class SubscriptionClient {
  static const userAgent = 'HorseBox/1.0 (sing-box 1.14)';

  static Uri buildUri(String rawUrl) {
    final uri = Uri.parse(rawUrl.trim());
    if (uri.host.isEmpty) {
      throw SubscriptionException('订阅地址不合法');
    }
    if (uri.queryParameters.containsKey('target')) return uri;
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      'target': 'singbox',
    });
  }

  static String normalizePin(String pin) {
    return pin.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
  }

  static bool isValidPin(String pin) => normalizePin(pin).length == 64;

  static String fingerprint(X509Certificate cert) {
    return sha256.convert(cert.der).toString();
  }

  static Future<Map<String, dynamic>> fetch(
    String rawUrl, {
    String certPin = '',
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = buildUri(rawUrl);
    final pin = normalizePin(certPin);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = userAgent;

    client.badCertificateCallback = (cert, host, port) {
      if (pin.isEmpty) return false;
      return fingerprint(cert) == pin;
    };

    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);

      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw SubscriptionException(switch (response.statusCode) {
          403 => '订阅已停用、已过期或 UA 被拒绝（403）',
          404 => '订阅不存在，请检查地址或令牌（404）',
          429 => '请求过于频繁，请稍后再试（429）',
          _ => '订阅服务器返回 HTTP ${response.statusCode}',
        });
      }

      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw SubscriptionException('订阅返回的不是 sing-box 配置');
      }
      return decoded;
    } on SubscriptionException {
      rethrow;
    } on HandshakeException {
      throw SubscriptionException(
        pin.isEmpty
            ? '证书校验失败：面板使用自签证书时，请到「设置 → 安全」填写证书 SHA-256 指纹'
            : '证书校验失败：面板证书与设置的指纹不一致，请重新核对',
      );
    } on TimeoutException {
      throw SubscriptionException('连接面板超时，请检查地址、端口和网络');
    } on SocketException catch (e) {
      throw SubscriptionException('无法连接面板：${e.message}');
    } on FormatException {
      throw SubscriptionException('订阅内容不是合法 JSON');
    } finally {
      client.close(force: true);
    }
  }
}
