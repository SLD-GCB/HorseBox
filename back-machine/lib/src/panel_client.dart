import 'dart:async';
import 'dart:io';

import 'pinned_http.dart' as pinned;

/// 面板预检失败，message 直接展示给用户。
class PanelProbeException implements Exception {
  PanelProbeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 面板访问前的 TLS 预检，以及 Windows WebView 的指纹下发。
///
/// 预检只是「快速失败」：真正加载页面时，WebView 每次握手还会再校验一次指纹
/// （Android 在 Dart 侧比对证书 DER，Windows 在 WebView2 的证书错误回调里比对）。
class PanelClient {
  static String normalizePin(String pin) => pinned.normalizePin(pin);

  static bool isValidPin(String pin) => pinned.isValidPin(pin);

  static String fingerprint(X509Certificate cert) =>
      pinned.fingerprint(cert.der);

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

    final client = pinned.createPinnedHttpClient(
      pin,
      connectionTimeout: timeout,
    );

    try {
      final request = await client.getUrl(ping).timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw PanelProbeException('面板返回 HTTP ${response.statusCode}');
      }
    } on PanelProbeException {
      rethrow;
    } on TlsException {
      throw PanelProbeException('证书校验失败：指纹与面板不一致');
    } on TimeoutException {
      throw PanelProbeException('连接面板超时');
    } on SocketException catch (e) {
      throw PanelProbeException('无法连接面板：${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// 首次登录的临时连接：仍然走 TLS，但不校验指纹。
  ///
  /// 只在还没写入订阅指纹时使用；用户填好指纹后必须走 [probe]。
  static Future<void> probeTemporary(
    String rawUrl, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) {
      throw PanelProbeException('面板地址必须以 https:// 开头');
    }

    final ping = Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/api/ping',
    );

    final client = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = (cert, host, port) => true;

    try {
      final request = await client.getUrl(ping).timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw PanelProbeException('面板返回 HTTP ${response.statusCode}');
      }
    } on PanelProbeException {
      rethrow;
    } on TimeoutException {
      throw PanelProbeException('连接面板超时');
    } on SocketException catch (e) {
      throw PanelProbeException('无法连接面板：${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  // ------------------------------------------------------------ Windows 指纹

  /// Windows 侧 WebView2 只能读进程内的本地文件，因此在打开面板前把指纹写到
  /// `%LOCALAPPDATA%\HorseBox\panel_pin`，由插件的证书错误回调读取比对。
  /// Android 不用这个文件（证书 DER 会直接回传 Dart）。
  static File? _windowsPinFile() {
    if (!Platform.isWindows) return null;
    var base = Platform.environment['LOCALAPPDATA'] ?? '';
    if (base.isEmpty) base = Platform.environment['TEMP'] ?? '';
    if (base.isEmpty) return null;
    return File(
      '$base${Platform.pathSeparator}HorseBox'
      '${Platform.pathSeparator}panel_pin',
    );
  }

  /// 写入当前面板的指纹；写失败时返回 false，面板将无法通过 WebView 校验。
  static Future<bool> publishWindowsPin(String rawPin) async {
    final pin = normalizePin(rawPin);
    if (pin.length != 64) return false;
    return _writeWindowsPin(pin);
  }

  /// 首次登录的临时连接：告诉 WebView2 「这次不校验指纹」。
  /// 只在没有指纹时使用，离开面板会立刻删除。
  static Future<bool> publishWindowsTemporary() =>
      _writeWindowsPin('temporary');

  static Future<bool> _writeWindowsPin(String value) async {
    final file = _windowsPinFile();
    if (file == null) return true;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(value, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 离开面板时清掉指纹，避免别的页面复用旧值。
  static Future<void> revokeWindowsPin() async {
    final file = _windowsPinFile();
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
