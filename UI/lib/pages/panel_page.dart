import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../state/app_state.dart';
import '../widgets/password_keyboard.dart';
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

  // 注意：安卓上 _passwordFixScript 会把 type=password 改成 text 并画上圆点，
  // 所以这里不能再按 type=password 找密码框，否则永远只填得上账号。
  String _fillScript(String user, String pass) =>
      '''
(function () {
  function setValue(el, value) {
    var desc = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
    desc.set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function isMasked(el) {
    if (el.getAttribute('data-hb-pwd') === '1') return true;
    var style = window.getComputedStyle(el);
    var mask = style.webkitTextSecurity;
    return !!mask && mask !== 'none';
  }
  function looksSecret(el) {
    var hint = (el.getAttribute('name') || '') + ' ' + (el.id || '') + ' ' + (el.getAttribute('placeholder') || '');
    hint = hint.toLowerCase();
    return hint.indexOf('pass') >= 0 || hint.indexOf('pwd') >= 0 || hint.indexOf('密码') >= 0;
  }
  var all = document.querySelectorAll('input');
  var pwd = null;
  var usr = null;
  for (var i = 0; i < all.length; i += 1) {
    var el = all[i];
    if (el.disabled) continue;
    var type = (el.getAttribute('type') || 'text').toLowerCase();
    if (type === 'hidden' || type === 'checkbox' || type === 'radio' || type === 'submit' ||
        type === 'button' || type === 'file' || type === 'search') continue;
    if (!pwd && (type === 'password' || isMasked(el))) { pwd = el; continue; }
    if (usr || el === pwd) continue;
    if (looksSecret(el)) { if (!pwd) pwd = el; continue; }
    usr = el;
  }
  // 没有密码框说明当前不是登录页（仪表盘、用户管理这些页面也有输入框），
  // 这时宁可不填，也不要把账号打进搜索框里。
  if (!pwd) return 0;
  var flags = 0;
  if (usr) { setValue(usr, $user); flags |= 1; }
  if (pwd) { setValue(pwd, $pass); flags |= 2; }
  if (usr) { usr.focus(); } else if (pwd) { pwd.focus(); }
  return flags;
})();
      ''';

  /// 面板里的密码框获得焦点时，由内置键盘接管输入。
  void _openPageKeypad() {
    final web = _web;
    if (web == null) return;
    // 面板页的键盘压短一点，别把登录卡片挡死。
    PasswordKeyboard.show(_WebKeySink(web), title: '面板密码', height: 200);
  }

  void _back() {
    PasswordKeyboard.hide();
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
    PasswordKeyboard.hide();
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
              KeyField(
                controller: _addr,
                hint: 'https://1.2.3.4:8443',
                keyboardType: TextInputType.url,
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
              if (Platform.isAndroid)
                UserScript(
                  source: _panelKeyScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
                  forMainFrameOnly: false,
                ),
            ]),
            onWebViewCreated: (controller) {
              _web = controller;
              if (Platform.isAndroid) {
                controller.addJavaScriptHandler(
                  handlerName: 'hbPasswordFocus',
                  callback: (args) {
                    _openPageKeypad();
                    return null;
                  },
                );
              }
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
                await controller.evaluateJavascript(source: _panelKeyScript);
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
/// 把类型改成 text，输入法看到的就是普通文本框，也就不会切成安全键盘。
/// 字段内容不做遮罩：面板登录时用户需要看清自己输入了什么。
const _passwordFixScript = r"""
(function () {
  if (window.__hbPwdFix) return;

  // 隐藏态用 CSS 画圆点，字段本身始终是 text，输入法看不到密码类型。
  function seal(el, hidden) {
    try {
      // 只有本来是密码框（已经打过标记）或明确要隐藏时才打标记，
      // 否则普通输入框（用户名）也会被当成密码框，填充会填错位置。
      if (!hidden && el.getAttribute('data-hb-pwd') !== '1') {
        el.style.webkitTextSecurity = 'none';
        return;
      }
      el.setAttribute('data-hb-pwd', '1');
      if (hidden) {
        el.setAttribute('data-hb-hidden', '1');
        el.style.webkitTextSecurity = 'disc';
      } else {
        el.removeAttribute('data-hb-hidden');
        el.style.webkitTextSecurity = 'none';
      }
    } catch (e) {}
  }

  function relax(el) {
    if (!el || el.tagName !== 'INPUT') return;
    var type = (el.getAttribute('type') || '').toLowerCase();
    if (type !== 'password') return;
    try { el.type = 'text'; } catch (e) {}
    el.setAttribute('type', 'text');
    // 页面自己渲染成密码框时默认遮住，之后交给眼睛按钮切换。
    seal(el, el.getAttribute('data-hb-hidden') !== '0');
    if (!el.getAttribute('autocomplete')) el.setAttribute('autocomplete', 'off');
  }

  function scan() {
    var list = document.querySelectorAll('input[type="password"]');
    for (var i = 0; i < list.length; i += 1) relax(list[i]);
  }

  // 1) 属性级拦截。Vue 每次 patch 都会执行 el.type = 'password'，在 setter 里
  //    直接换成 text：输入法在聚焦那一刻读到的就已经是 text，不存在时间差。
  try {
    var proto = window.HTMLInputElement && window.HTMLInputElement.prototype;
    var desc = proto && Object.getOwnPropertyDescriptor(proto, 'type');
    if (desc && desc.set && desc.get && !proto.__hbTypeTrap) {
      Object.defineProperty(proto, 'type', {
        configurable: true,
        enumerable: desc.enumerable,
        get: desc.get,
        set: function (value) {
          var next = String(value).toLowerCase();
          if (next === 'password') {
            // Element 的「显示密码」按钮就是靠改 type 实现的：这里必须
            // 记住它的意图，用 CSS 遮罩代替 password 类型。
            desc.set.call(this, 'text');
            seal(this, true);
            return;
          }
          desc.set.call(this, value);
          if (next === 'text') seal(this, false);
        }
      });
      proto.__hbTypeTrap = true;
    }
  } catch (e) {}

  // 2) 手指按下就转换，早于 focus，也就早于输入法建立会话。
  function onDown(event) { relax(event.target); }
  document.addEventListener('pointerdown', onDown, true);
  document.addEventListener('touchstart', onDown, true);
  document.addEventListener('mousedown', onDown, true);

  // 3) 兜底：节点插入，以及 type 被别的途径写回。
  new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i += 1) {
      var record = records[i];
      if (record.type === 'attributes') relax(record.target);
      else scan();
    }
  }).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['type']
  });

  scan();
  window.__hbPwdFix = true;
})();
""";

/// 面板 WebView 的键盘出口：把按键转成 JS 调用，写进当前聚焦的密码框。
class _WebKeySink extends PasswordKeySink {
  _WebKeySink(this.web);

  final InAppWebViewController web;

  void _call(String op, [String? value]) {
    final arg = value == null ? 'null' : jsonEncode(value);
    unawaited(
      web.evaluateJavascript(
        source: 'window.__hbKey && window.__hbKey("$op", $arg)',
      ),
    );
  }

  @override
  void insert(String text) => _call('insert', text);

  @override
  void backspace() => _call('backspace');

  @override
  void clear() => _call('clear');
}

/// Android：面板里的密码框改由 App 内置键盘输入。聚焦时挡住系统输入法，
/// 并把焦点字段记下来，之后按键都写进这个字段。
const _panelKeyScript = r'''
(function () {
  function masked(el) {
    if (!el || el.tagName !== 'INPUT') return false;
    if (el.getAttribute('data-hb-pwd') === '1') return true;
    if ((el.getAttribute('type') || '').toLowerCase() === 'password') return true;
    var style = window.getComputedStyle(el);
    var mask = style.webkitTextSecurity;
    return !!mask && mask !== 'none';
  }

  function field() {
    var el = window.__hbField;
    if (el && el.isConnected) return el;
    var list = document.querySelectorAll('input[data-hb-pwd="1"], input[type="password"]');
    return list.length ? list[0] : null;
  }

  window.__hbKey = function (op, value) {
    var el = field();
    if (!el) return false;
    el.focus();
    var start = el.selectionStart == null ? el.value.length : el.selectionStart;
    var end = el.selectionEnd == null ? el.value.length : el.selectionEnd;
    if (op === 'insert') {
      el.value = el.value.slice(0, start) + value + el.value.slice(end);
      var pos = start + value.length;
      el.setSelectionRange(pos, pos);
    } else if (op === 'backspace') {
      if (start !== end) {
        el.value = el.value.slice(0, start) + el.value.slice(end);
        el.setSelectionRange(start, start);
      } else if (start > 0) {
        el.value = el.value.slice(0, start - 1) + el.value.slice(start);
        el.setSelectionRange(start - 1, start - 1);
      }
    } else if (op === 'clear') {
      el.value = '';
      el.setSelectionRange(0, 0);
    }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  };

  document.addEventListener('focusin', function (event) {
    var el = event.target;
    if (!masked(el)) return;
    window.__hbField = el;
    // 这个字段交给 App 的内置键盘，别让系统输入法弹出来。
    el.setAttribute('inputmode', 'none');
    try {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('hbPasswordFocus');
      }
    } catch (e) {}
    function center() {
      try { el.scrollIntoView({ block: 'center' }); } catch (e) {}
    }
    center();
    setTimeout(center, 320);
  }, true);
})();
''';
