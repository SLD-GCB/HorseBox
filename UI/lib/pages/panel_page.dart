import 'dart:io';

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
  Profile? _active;
  String _base = '';
  bool _probing = false;
  bool _ready = false;
  String? _error;

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
    final pin = _pinFor(profile).trim();
    if (pin.isEmpty) {
      setState(() => _error = '该订阅没有证书指纹，请先在订阅里填写');
      return;
    }
    _enterLandscape();
    setState(() {
      _active = profile;
      _base = base;
      _probing = true;
      _ready = false;
      _error = null;
    });
    try {
      await PanelClient.probe(base, pin);
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

  void _back() {
    _exitLandscape();
    setState(() {
      _active = null;
      _ready = false;
      _probing = false;
      _error = null;
    });
  }

  @override
  void dispose() {
    _exitLandscape();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_active == null) return _buildList();
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
          '选择订阅，使用它的地址和指纹打开面板。',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
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
            initialUrlRequest: URLRequest(url: WebUri(_base)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              thirdPartyCookiesEnabled: true,
              supportZoom: true,
              transparentBackground: false,
            ),
            onReceivedServerTrustAuthRequest: (controller, challenge) async {
              // 预检已经校验过指纹，这里直接放行。
              return ServerTrustAuthResponse(
                action: ServerTrustAuthResponseAction.PROCEED,
              );
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
      ],
    );
  }
}
