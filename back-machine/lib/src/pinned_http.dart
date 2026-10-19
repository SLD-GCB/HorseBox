import 'dart:io';

import 'package:crypto/crypto.dart';

// 证书指纹工具 + 逐条连接校验的 HttpClient 工厂。
//
// 面板常用自签证书，客户端用 SHA-256 指纹做固定校验：
// - 每条新连接（含连接复用前的首次握手）都必须命中指纹，否则直接断开；
// - 不做「仅在校验失败时才比对」，所以就算对端拿了公网 CA 证书，
//   指纹不一致一样拒绝。

/// 去掉冒号、空格等分隔符并转小写，得到 64 位十六进制。
String normalizePin(String pin) =>
    pin.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();

bool isValidPin(String pin) => normalizePin(pin).length == 64;

/// DER 证书的 SHA-256（小写十六进制，与 `openssl x509 -fingerprint -sha256` 一致）。
String fingerprint(List<int> der) => sha256.convert(der).toString();

/// 创建一个「每次握手都校验指纹」的 [HttpClient]。
///
/// 用 [HttpClient.connectionFactory] 自己建立 TLS 连接，握手成功后读取
/// `peerCertificate` 比对指纹，再把手里的 SecureSocket 交给 HttpClient。
/// 这样就不会出现「证书链合法但指纹不对仍放行」的空档。
HttpClient createPinnedHttpClient(
  String rawPin, {
  Duration? connectionTimeout,
}) {
  final pin = normalizePin(rawPin);
  if (pin.length != 64) {
    throw ArgumentError('证书指纹必须是 64 位十六进制');
  }

  final client = HttpClient();
  if (connectionTimeout != null) {
    client.connectionTimeout = connectionTimeout;
  }

  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    final Future<Socket> socket = SecureSocket.connect(
      uri.host,
      uri.port,
      onBadCertificate: (_) => true,
      timeout: connectionTimeout,
    ).then<Socket>((secure) {
      final cert = secure.peerCertificate;
      if (cert == null) {
        secure.destroy();
        throw HandshakeException('对端没有提供证书');
      }
      if (sha256.convert(cert.der).toString() != pin) {
        secure.destroy();
        throw HandshakeException('证书指纹不一致');
      }
      return secure;
    });
    return ConnectionTask.fromSocket(socket, () {});
  };

  return client;
}
