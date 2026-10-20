import 'dart:collection';
import 'dart:convert';
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

  /// Android：默认屏蔽系统输入法，点按钮才放行（面板里点输入框/下拉不再弹键盘）。
  InAppWebViewController? _web;
  bool _imeArmed = false;

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

  String _pinFor(Profile profile) => profile.certPin.isNotEmpty
      ? profile.certPin
      : widget.state.settings.certPin;

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
    final der =
        challenge.protectionSpace.sslCertificate?.x509Certificate?.encoded;
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

  /// 切换「允许系统输入法」：默认关闭，面板里点输入框、下拉都不会弹键盘。
  Future<void> _toggleIme() async {
    setState(() => _imeArmed = !_imeArmed);
    await _applyIme();
  }

  Future<void> _applyIme() async {
    if (!Platform.isAndroid) return;
    final controller = _web;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(
        source: 'window.__hbIme && window.__hbIme($_imeArmed)',
      );
    } catch (_) {}
  }

  /// 密码本下拉：一个面板一条记录，选中后填进当前页面的登录框。
  Future<void> _showVault() async {
    final items = widget.state.credentials;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码本还没有记录，先到「密码本」添加')));
      return;
    }
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final choice = await showMenu<PanelCredential>(
      context: context,
      position: RelativeRect.fromLTRB(overlay.size.width - 300, 56, 12, 0),
      items: [
        for (final item in items)
          PopupMenuItem<PanelCredential>(
            value: item,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.username, style: const TextStyle(fontSize: 12.5)),
                Text(
                  item.panel,
                  style: const TextStyle(fontSize: 10.5, color: Colors.grey),
                ),
              ],
            ),
          ),
      ],
    );
    if (choice != null) await _fillCredential(choice);
  }

  Future<void> _fillCredential(PanelCredential item) async {
    final web = _web;
    if (web == null) return;
    try {
      final result = await web.evaluateJavascript(
        source: _fillScript(
          jsonEncode(item.username),
          jsonEncode(item.password),
        ),
      );
      final filled = int.tryParse(result?.toString() ?? '') ?? 0;
      if (!mounted) return;
      if (filled == 0) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('没找到登录框，请先打开面板的登录页')));
      } else if (filled == 3) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已填入账号和密码')));
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('只找到账号或密码其中一个输入框')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('填入失败：$e')));
    }
  }

  String _fillScript(String user, String pass) =>
      '''
(function () {
  function setValue(el, value) {
    var desc = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
    desc.set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  var pwd = document.querySelector('input[type="password"]');
  var usr = document.querySelector('input[name="username"], input[type="text"], input[type="email"]');
  var flags = 0;
  if (usr) { setValue(usr, $user); flags |= 1; }
  if (pwd) { setValue(pwd, $pass); flags |= 2; }
  if (usr) { usr.focus(); } else if (pwd) { pwd.focus(); }
  return flags;
})();
''';

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

  /// 同一个面板（scheme + host + port 相同）只保留一条，避免多个订阅把列表撑重复。
  /// 优先用当前订阅；其次优先带指纹的那条，免得点进去落到临时连接。
  List<Profile> _panelEntries(List<Profile> profiles) {
    final ordered = [...profiles];
    ordered.sort((a, b) {
      final aActive = a.id == widget.state.activeId;
      final bActive = b.id == widget.state.activeId;
      if (aActive != bActive) return aActive ? -1 : 1;
      final aPin = _pinFor(a).isNotEmpty;
      final bPin = _pinFor(b).isNotEmpty;
      if (aPin != bPin) return aPin ? -1 : 1;
      return 0;
    });
    final seen = <String>{};
    final out = <Profile>[];
    for (final profile in ordered) {
      final base = _panelBase(profile.url);
      if (base == null) {
        // 不是 HTTPS 的订阅照样列出来，点进去会提示原因。
        out.add(profile);
        continue;
      }
      if (seen.add(base)) out.add(profile);
    }
    return out;
  }

  /// 同一个面板下有几个订阅，显示在副标题上，避免误以为漏了配置。
  String _panelSubtitle(Profile profile, List<Profile> profiles) {
    final base = _panelBase(profile.url);
    if (base == null) return profile.url;
    final count = profiles.where((item) => _panelBase(item.url) == base).length;
    return count > 1 ? '$base · $count 个订阅' : base;
  }

  Widget _buildList() {
    final scheme = Theme.of(context).colorScheme;
    final profiles = widget.state.profiles;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 34, 20, 28),
      children: [
        const Text(
          '面板',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
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
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
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
          for (final profile in _panelEntries(profiles))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
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
                    _panelSubtitle(profile, profiles),
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
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: scheme.onSurfaceVariant,
              ),
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
            initialUserScripts: UnmodifiableListView<UserScript>([
              if (Platform.isWindows)
                UserScript(
                  source: _optionClickFix,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
                  forMainFrameOnly: false,
                ),
              if (Platform.isAndroid)
                UserScript(
                  source: _imeScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
                  forMainFrameOnly: false,
                ),
              if (Platform.isAndroid)
                UserScript(
                  source: _passwordFixScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
                  forMainFrameOnly: false,
                ),
            ]),
            onWebViewCreated: (controller) {
              _web = controller;
            },
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
            onLoadStop: (controller, url) async {
              // 用户脚本按文档注入，SPA 切页不会重跑，这里补一次。
              if (Platform.isWindows) {
                await controller.evaluateJavascript(source: _optionClickFix);
              }
              if (Platform.isAndroid) {
                await controller.evaluateJavascript(source: _imeScript);
                await controller.evaluateJavascript(source: _passwordFixScript);
                await _applyIme();
              }
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
        Positioned(
          top: 10,
          right: Platform.isAndroid ? 56 : 10,
          child: SafeArea(
            child: Material(
              color: Colors.black.withValues(alpha: 0.45),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _showVault,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.vpn_key, size: 20, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
        if (Platform.isAndroid)
          Positioned(
            top: 10,
            right: 10,
            child: SafeArea(
              child: Material(
                color: _imeArmed
                    ? Colors.white.withValues(alpha: 0.85)
                    : Colors.black.withValues(alpha: 0.45),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _toggleIme,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      _imeArmed ? Icons.keyboard : Icons.keyboard_hide_outlined,
                      size: 20,
                      color: _imeArmed ? Colors.black : Colors.white,
                    ),
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
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Windows 的合成视图下，一次点击要拆成 MOVE / DOWN / UP 三条注入，
/// 浏览器只有在按下和抬起命中同一个节点时才会生成 click，而 Element Plus 的
/// 下拉选项正是靠 click 选中。弹层刚展开时还在做定位和滚动，两者只要错开一帧，
/// click 就不生成 —— 表现就是“点好几次才中”。
///
/// 这里不再依赖 click：按下落在选项上的那一刻，直接替浏览器补发一次 click，
/// 走的是同一个处理函数；随后浏览器若真的又生成一次 click，就吞掉，避免重复。
const _optionClickFix = r'''
(function () {
  if (window.__hbOptionFix) return;
  window.__hbOptionFix = true;

  var consumed = null;
  var consumedAt = 0;

  function itemOf(node) {
    var el = node;
    while (el && el.nodeType === 1) {
      if (el.classList && el.classList.contains('el-select-dropdown__item')) return el;
      el = el.parentElement;
    }
    return null;
  }

  document.addEventListener('mousedown', function (event) {
    var item = itemOf(event.target);
    if (!item || item.classList.contains('is-disabled')) return;
    consumed = item;
    consumedAt = Date.now();
    var click = new MouseEvent('click', {
      bubbles: true,
      cancelable: true,
      view: window,
      button: 0
    });
    click.__horsebox = true;
    item.dispatchEvent(click);
  }, true);

  document.addEventListener('click', function (event) {
    if (event.__horsebox) return;
    if (!consumed) return;
    if (Date.now() - consumedAt > 600) {
      consumed = null;
      return;
    }
    if (itemOf(event.target) !== consumed) return;
    consumed = null;
    event.stopPropagation();
    event.preventDefault();
  }, true);
})();
''';

/// Android：面板里的输入框/下拉默认不弹系统键盘。
///
/// Element Plus 的下拉触发器本身是 <input>，点一下就会唤起输入法，横屏下面板被键盘
/// 遮掉大半。这里给所有可编辑元素标上 inputmode=none（浏览器不弹键盘但仍可聚焦，
/// 下拉、开关行为不受影响）；点右上角的键盘按钮放行，键盘才会正常弹出。
const _imeScript = r'''
(function () {
  if (window.__hbIme) return;

  var armed = false;
  var SELECTOR = 'input, textarea, [contenteditable="true"]';
  var SKIP_TYPES = ['button', 'checkbox', 'radio', 'submit', 'reset', 'file',
                    'range', 'color', 'hidden', 'image'];

  function usable(el) {
    if (!el || el.tagName !== 'INPUT') return true;
    var type = (el.getAttribute('type') || 'text').toLowerCase();
    return SKIP_TYPES.indexOf(type) < 0;
  }

  function apply() {
    var list = document.querySelectorAll(SELECTOR);
    for (var i = 0; i < list.length; i++) {
      var el = list[i];
      if (!usable(el)) continue;
      if (armed) {
        if (el.__hbImeLocked) {
          el.removeAttribute('inputmode');
          el.__hbImeLocked = false;
        }
      } else if (!el.__hbImeLocked) {
        el.setAttribute('inputmode', 'none');
        el.__hbImeLocked = true;
      }
    }
  }

  window.__hbIme = function (value) {
    armed = !!value;
    apply();
    return armed;
  };

  new MutationObserver(apply).observe(document.documentElement, {
    childList: true,
    subtree: true
  });

  apply();
})();
''';

/// Android：WebView 里 type=password 的输入框会触发输入法的「安全键盘」。
/// 把类型改成 text 再用 -webkit-text-security 画圆点，输入法看到的就是普通文本框，
/// 界面上仍然是遮住的。
const _passwordFixScript = r'''
(function () {
  if (window.__hbPwdFix) return;
  window.__hbPwdFix = true;

  function relax(el) {
    if (!el || el.tagName !== 'INPUT') return;
    var type = (el.getAttribute('type') || '').toLowerCase();
    if (type !== 'password') return;
    el.setAttribute('type', 'text');
    el.style.webkitTextSecurity = 'disc';
    if (!el.getAttribute('autocomplete')) el.setAttribute('autocomplete', 'off');
  }

  function scan() {
    var list = document.querySelectorAll('input[type="password"]');
    for (var i = 0; i < list.length; i += 1) relax(list[i]);
  }

  document.addEventListener('focusin', function (event) {
    relax(event.target);
  }, true);

  new MutationObserver(scan).observe(document.documentElement, {
    childList: true,
    subtree: true
  });

  scan();
})();
''';
