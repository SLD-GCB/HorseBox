import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/section.dart';

/// 内嵌面板：从订阅里取地址和指纹，预检通过后交给 WebView。
class PanelPage extends StatefulWidget {
  const PanelPage({super.key, required this.state});

  final AppState state;

  @override
  State<PanelPage> createState() => _PanelPageState();
}

class _PanelPageState extends State<PanelPage> {
  /// 正在访问的面板地址；null 表示还在列表页。
  String? _base;
  String _pin = '';
  bool _temporary = false;
  bool _probing = false;
  bool _ready = false;
  String? _error;
  final _addr = TextEditingController();

  /// 从订阅地址推导面板根地址：只保留 scheme、host、port。
  String? _panelBase(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) {
      return null;
    }
    return Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  void _enterLandscape() {
    if (!Platform.isAndroid) return;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _exitLandscape() {
    if (!Platform.isAndroid) return;
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  String _pinFor(Profile profile) =>
      profile.certPin.isNotEmpty ? profile.certPin : widget.state.settings.certPin;

  Future<void> _open(Profile profile) async {
    final base = _panelBase(profile.url);
    if (base == null) {
      setState(() => _error = '该订阅不是 HTTPS，无法用于访问面板');
      return;
    }
    await _openAt(base, _pinFor(profile));
  }

  /// 首次登录：还没有订阅，直接填面板地址。
  Future<void> _openByAddress() async {
    var raw = _addr.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请填写面板地址，例如 https://1.2.3.4:8443');
      return;
    }
    if (!raw.contains('://')) raw = 'https://$raw';
    final base = _panelBase(raw);
    if (base == null) {
      setState(() => _error = '面板地址必须以 https:// 开头');
      return;
    }
    await _openAt(base, '');
  }

  Future<void> _openAt(String base, String rawPin) async {
    final pin = PanelClient.normalizePin(rawPin);
    final temporary = pin.isEmpty;
    _enterLandscape();
    setState(() {
      _base = base;
      _pin = pin;
      _temporary = temporary;
      _probing = true;
      _ready = false;
      _error = null;
    });
    try {
      if (temporary) {
        // 还没有指纹：临时连一次，只用于第一次进面板，连接本身仍是 TLS。
        await PanelClient.probeTemporary(base);
      } else {
        await PanelClient.probe(base, pin);
      }
      if (Platform.isWindows) {
        final ok = temporary
            ? await PanelClient.publishWindowsTemporary()
            : await PanelClient.publishWindowsPin(pin);
        if (!ok) {
          throw '无法写入证书状态（%LOCALAPPDATA%\\HorseBox 不可写）';
        }
      }
      if (!mounted) return;
      setState(() {
        _ready = true;
        _probing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _probing = false;
        _ready = false;
      });
    }
  }

  /// 每次 TLS 握手（含子资源）都校验一次指纹，不匹配直接中止连接。
  bool _certMatches(URLAuthenticationChallenge challenge) {
    // 首次登录的临时连接：只保证加密，不校验指纹。
    if (_temporary) return true;
    final der = challenge.protectionSpace.sslCertificate?.x509Certificate?.encoded;
    if (der == null || der.isEmpty) return false;
    return sha256.convert(der).toString() == _pin;
  }

  void _rejectTls() {
    if (!mounted || _error != null) return;
    setState(() {
      _ready = false;
      _probing = false;
      _error = '面板证书指纹不匹配，连接已中止。请重新核对面板展示的 SHA-256 指纹。';
    });
  }

  void _back() {
    _exitLandscape();
    PanelClient.revokeWindowsPin();
    setState(() {
      _base = null;
      _pin = '';
      _temporary = false;
      _ready = false;
      _probing = false;
      _error = null;
    });
  }

  @override
  void dispose() {
    _exitLandscape();
    PanelClient.revokeWindowsPin();
    _addr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_base == null) return _buildList();
    if (_probing) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _buildError();
    if (!_ready) return const SizedBox.shrink();
    return _buildWebView();
  }

  Widget _buildList() {
    final scheme = Theme.of(context).colorScheme;
    final profiles = widget.state.profiles;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 34, 20, 28),
      children: [
        const Text('面板', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          '第一次使用面板：填面板地址直接连；已有订阅：点下面的订阅。',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '首次登录',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                '还没有订阅时，先连一次面板建好入站。这次是临时连接，'
                '连上后在面板里复制证书指纹，填进订阅即可。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _addr,
                keyboardType: TextInputType.url,
                style: const TextStyle(fontSize: 12.5),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'https://1.2.3.4:8443',
                ),
                onSubmitted: (_) => _openByAddress(),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _openByAddress,
                  child: const Text('临时连接'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (profiles.isEmpty)
          SectionCard(
            child: Text(
              '还没有订阅，先到「订阅」添加。',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          )
        else
          for (final profile in profiles)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.apps,
                    color: scheme.brightness == Brightness.dark
                        ? Colors.white
                        : scheme.primary,
                  ),
                  title: Text(
                    profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5),
                  ),
                  subtitle: Text(
                    _panelBase(profile.url) ?? profile.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HorseBoxTheme.mono(context, size: 10.5),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => _open(profile),
                ),
              ),
            ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(
            _error!,
            style: TextStyle(fontSize: 12, height: 1.5, color: scheme.error),
          ),
        ],
      ],
    );
  }

  Widget _buildError() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 36, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.6, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: _back, child: const Text('返回')),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView() {
    return Stack(
      children: [
        Positioned.fill(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_base!)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              thirdPartyCookiesEnabled: true,
              supportZoom: true,
              transparentBackground: false,
            ),
            onReceivedServerTrustAuthRequest: (controller, challenge) async {
              // 自签证书每次握手都会进到这里：只放行指纹完全一致的那个。
              if (_certMatches(challenge)) {
                return ServerTrustAuthResponse(
                  action: ServerTrustAuthResponseAction.PROCEED,
                );
              }
              _rejectTls();
              return ServerTrustAuthResponse(
                action: ServerTrustAuthResponseAction.CANCEL,
              );
            },
            onReceivedError: (controller, request, error) async {
              // Windows 侧由 WebView2 原生层拒绝，只能从加载错误里识别证书问题。
              if (request.isForMainFrame == false) return;
              final text = '${error.type} ${error.description}'.toUpperCase();
              if (text.contains('CERTIFICATE') || text.contains('CERT_')) {
                _rejectTls();
              }
            },
          ),
        ),
        Positioned(
          top: 10,
          left: 10,
          child: SafeArea(
            child: Material(
              color: Colors.black.withValues(alpha: 0.45),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _back,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.arrow_back, size: 20, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
        if (_temporary)
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: SafeArea(
              child: Material(
                color: const Color(0xE6B26A00),
                borderRadius: BorderRadius.circular(10),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    '临时连接：未校验证书指纹。登录后请在面板里复制证书 SHA-256 指纹，填进订阅。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, height: 1.4, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
