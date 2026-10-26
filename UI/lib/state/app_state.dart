import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import '../security/dpapi.dart';
import '../security/secret_vault.dart';

import 'package:path/path.dart' as p;

import '../platform/ime_channel.dart';
import '../platform/vpn_channel.dart';
import '../utils/app_paths.dart';
import '../utils/rule_assets.dart';
import '../widgets/password_keyboard.dart';

enum CoreStatus { idle, connecting, connected, stopping, error }

/// 客户端全局状态：订阅、设置、内核生命周期、流量、日志、连接。
class AppState extends ChangeNotifier {
  AppState(this._store, this._dataDir);

  static const _kProfiles = 'profiles';
  static const _kSshHosts = 'ssh_hosts';
  static const _kCredentials = 'panel_credentials';
  static const _kActive = 'active_profile';
  static const _kSettings = 'settings';
  static const _kUsage = 'panel_usage';

  LocalStore _store;
  String _dataDir;
  String _rulesDir = '';
  final VpnChannel _vpn = VpnChannel();

  final List<Profile> _profiles = [];
  final List<SshHost> _sshHosts = [];
  final List<PanelCredential> _credentials = [];
  SecretVault? _vault;
  String? _activeId;
  AppSettings _settings = const AppSettings();

  CoreStatus _status = CoreStatus.idle;
  String? _error;
  String _coreVersion = '';
  DateTime? _connectedAt;
  TrafficSample _traffic = const TrafficSample();
  final List<LogEntry> _logs = [];
  List<ConnectionRow> _connections = const [];
  int _clashPort = 0;

  ClashApi? _api;
  SingBoxRunner? _runner;
  StreamSubscription<TrafficSample>? _trafficSub;
  StreamSubscription<LogEntry>? _apiLogSub;
  StreamSubscription<LogEntry>? _processLogSub;
  StreamSubscription<int>? _exitSub;
  StreamSubscription<bool>? _vpnSub;
  Timer? _pollTimer;
  Timer? _tickTimer;
  bool _stopping = false;
  bool _busy = false;
  bool _disposed = false;

  /// 面板用量：键是订阅 id，值以面板返回为准；断网时保留上一次的值。
  final Map<String, PanelUsage> _usage = {};
  final Map<String, String> _usageError = {};
  Timer? _usageTimer;
  final Set<String> _usageInFlight = {};

  List<Profile> get profiles => List.unmodifiable(_profiles);
  List<SshHost> get sshHosts => List.unmodifiable(_sshHosts);
  List<PanelCredential> get credentials => List.unmodifiable(_credentials);
  String? get activeId => _activeId;
  Profile? get activeProfile =>
      _profiles.where((item) => item.id == _activeId).firstOrNull;
  AppSettings get settings => _settings;
  CoreStatus get status => _status;
  String? get error => _error;
  String get coreVersion => _coreVersion;
  int get clashPort => _clashPort;
  TrafficSample get traffic => _traffic;

  /// 订阅在面板侧的用量；还没查过时返回 null。
  PanelUsage? usageOf(Profile profile) => _usage[profile.id];

  /// 最近一次查询用量的错误（成功后会清掉）。
  String? usageErrorOf(Profile profile) => _usageError[profile.id];
  List<LogEntry> get logs => List.unmodifiable(_logs);
  List<ConnectionRow> get connections => _connections;
  String get dataDir => _dataDir;
  bool get busy => _busy;
  bool get isConnected => _status == CoreStatus.connected;
  Duration get uptime => _connectedAt == null
      ? Duration.zero
      : DateTime.now().difference(_connectedAt!);

  Future<void> init() async {
    _vault = await SecretVault.open(_dataDir);
    final rawProfiles = _store.get(_kProfiles);
    if (rawProfiles is List) {
      for (final item in rawProfiles.whereType<Map>()) {
        final map = Map<String, dynamic>.from(item);
        map['url'] = await _unseal(map['url'] as String? ?? '');
        _profiles.add(Profile.fromJson(map));
      }
    }
    final rawHosts = _store.get(_kSshHosts);
    if (rawHosts is List) {
      for (final item in rawHosts.whereType<Map>()) {
        final map = Map<String, dynamic>.from(item);
        map['password'] = await _unseal(map['password'] as String? ?? '');
        _sshHosts.add(SshHost.fromJson(map));
      }
    }
    final rawCredentials = _store.get(_kCredentials);
    if (rawCredentials is List) {
      for (final item in rawCredentials.whereType<Map>()) {
        final map = Map<String, dynamic>.from(item);
        map['password'] = await _unseal(map['password'] as String? ?? '');
        _credentials.add(PanelCredential.fromJson(map));
      }
    }
    _activeId = _store.getString(_kActive);
    if (_activeId != null && !_profiles.any((item) => item.id == _activeId)) {
      _activeId = null;
    }
    if (_activeId == null && _profiles.isNotEmpty) {
      _activeId = _profiles.first.id;
    }
    final rawSettings = _store.get(_kSettings);
    if (rawSettings is Map) {
      _settings = AppSettings.fromJson(Map<String, dynamic>.from(rawSettings));
      _applyKeyboardConfig();
    }
    final rawUsage = _store.get(_kUsage);
    if (rawUsage is Map) {
      for (final entry in rawUsage.entries) {
        final value = entry.value;
        if (value is Map) {
          _usage['${entry.key}'] = PanelUsage.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      }
    }
    try {
      _rulesDir = await ensureCnRuleSets(_dataDir);
    } catch (_) {
      _rulesDir = '';
    }
    _usageTimer?.cancel();
    _usageTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(refreshUsage()),
    );
    _notify();
    unawaited(refreshUsage());
    if (!Platform.isAndroid && _settings.autoConnect && activeProfile != null) {
      unawaited(connect());
    }
  }

  /// 拉一次面板用量。默认查当前订阅，也可以指定某一个。
  Future<void> refreshUsage({Profile? profile}) async {
    final target = profile ?? activeProfile;
    if (target == null || _usageInFlight.contains(target.id)) return;
    _usageInFlight.add(target.id);
    final base = PanelUsageClient.baseOf(target.url);
    if (base == null) {
      _usageInFlight.remove(target.id);
      _usageError[target.id] = '订阅地址不是 http(s)，无法查询用量';
      _notify();
      return;
    }
    final subToken = PanelUsageClient.subTokenOf(target.url);
    if (subToken.isEmpty) {
      _usageInFlight.remove(target.id);
      _usageError[target.id] = '订阅地址里没有令牌，无法按用户查询用量';
      _notify();
      return;
    }
    final credential = _credentialForPanel(base);
    if (credential == null) {
      _usageInFlight.remove(target.id);
      _usageError[target.id] = '先在「密码本」添加该面板的账号，才能查询用量';
      _notify();
      return;
    }
    try {
      final usage = await PanelUsageClient.fetch(
        base: base,
        username: credential.username,
        password: credential.password,
        subToken: subToken,
        certPin: _pinFor(target),
      );
      _usage[target.id] = usage;
      _usageError.remove(target.id);
      await _store.set(_kUsage, {
        for (final entry in _usage.entries) entry.key: entry.value.toJson(),
      });
    } catch (e) {
      _usageError[target.id] = e is PanelUsageException ? e.message : '$e';
    } finally {
      _usageInFlight.remove(target.id);
      _notify();
    }
  }

  /// 按面板地址（host:port）找密码本里对应那条管理员账号。
  PanelCredential? _credentialForPanel(String base) {
    final authority = normalizePanel(base);
    if (authority.isEmpty) return null;
    for (final item in _credentials) {
      if (normalizePanel(item.panel) == authority) return item;
    }
    return null;
  }

  // ---------------------------------------------------------------- 密码本

  /// 面板地址归一化：去掉协议、路径和尾部斜杠，只留 host:port，用作去重键。
  static String normalizePanel(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    text = text.replaceFirst(RegExp('^[a-zA-Z]+://'), '');
    final slash = text.indexOf('/');
    if (slash >= 0) text = text.substring(0, slash);
    return text.toLowerCase();
  }

  /// 新增或修改一条面板凭据；面板重复时返回错误文案，成功返回 null。
  Future<String?> saveCredential({
    String? id,
    required String panel,
    required String username,
    required String password,
  }) async {
    final key = normalizePanel(panel);
    if (key.isEmpty) return '请填写面板地址';
    if (username.trim().isEmpty) return '请填写用户名';
    if (_credentials.any((item) => item.id != id && item.panel == key)) {
      return '这个面板已经有一条记录了';
    }
    final existing = id == null
        ? null
        : _credentials.where((item) => item.id == id).firstOrNull;
    if (existing == null) {
      _credentials.add(
        PanelCredential(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          panel: key,
          username: username.trim(),
          password: password,
        ),
      );
    } else {
      existing.panel = key;
      existing.username = username.trim();
      existing.password = password;
    }
    await _persistCredentials();
    _notify();
    return null;
  }

  Future<void> removeCredential(String id) async {
    _credentials.removeWhere((item) => item.id == id);
    await _persistCredentials();
    _notify();
  }

  Future<void> _persistCredentials() async {
    final rows = <Map<String, dynamic>>[];
    for (final item in _credentials) {
      final row = item.toJson();
      row['password'] = await _seal(item.password);
      rows.add(row);
    }
    await _store.set(_kCredentials, rows);
  }

  // ---------------------------------------------------------------- SSH 主机

  Future<SshHost> addSshHost({
    required String host,
    required String username,
    String password = '',
    String name = '',
    int port = 22,
  }) async {
    final item = SshHost(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      host: host.trim(),
      port: port,
      username: username.trim(),
      password: password,
    );
    _sshHosts.add(item);
    await _persistHosts();
    _notify();
    return item;
  }

  Future<void> updateSshHost(
    SshHost item, {
    String? host,
    String? username,
    String? password,
    String? name,
    int? port,
  }) async {
    if (host != null && host.trim().isNotEmpty) item.host = host.trim();
    if (username != null && username.trim().isNotEmpty) {
      item.username = username.trim();
    }
    if (password != null) item.password = password;
    if (name != null) item.name = name.trim();
    if (port != null && port > 0 && port <= 65535) item.port = port;
    await _persistHosts();
    _notify();
  }

  Future<void> removeSshHost(String id) async {
    _sshHosts.removeWhere((item) => item.id == id);
    await _persistHosts();
    _notify();
  }

  /// 首次连接时记住主机密钥指纹。
  Future<void> saveSshFingerprint(String id, String fingerprint) async {
    final item = _sshHosts.where((host) => host.id == id).firstOrNull;
    if (item == null) return;
    item.fingerprint = fingerprint;
    await _persistHosts();
  }

  /// 端口转发规则存在主机里，改完直接落盘。
  Future<void> saveSshForwards(SshHost host) async {
    await _persistHosts();
    _notify();
  }

  Future<void> _persistHosts() async {
    final rows = <Map<String, dynamic>>[];
    for (final item in _sshHosts) {
      final row = item.toJson();
      row['password'] = await _seal(item.password);
      rows.add(row);
    }
    await _store.set(_kSshHosts, rows);
  }

  // ---------------------------------------------------------------- 订阅

  Future<void> addProfile(
    String url, {
    String name = '',
    String certPin = '',
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw const FormatException('订阅地址必须以 http:// 或 https:// 开头');
    }
    final trimmed = url.trim();
    if (_profiles.any((item) => item.url == trimmed)) {
      throw const FormatException('这个订阅已经添加过了');
    }
    final profile = Profile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim().isEmpty
          ? (uri.host.isEmpty ? '订阅' : uri.host)
          : name.trim(),
      url: trimmed,
      certPin: certPin.trim(),
    );
    _profiles.add(profile);
    _activeId ??= profile.id;
    await _persistProfiles();
    _notify();
  }

  /// 修改已有订阅的地址、名称、指纹。地址改了会顺手把节点缓存作废（UI 那边处理）。
  Future<void> updateProfile(
    Profile profile, {
    String? url,
    String? name,
    String? certPin,
  }) async {
    final nextUrl = url?.trim() ?? '';
    if (nextUrl.isNotEmpty) {
      final uri = Uri.tryParse(nextUrl);
      if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
        throw const FormatException('订阅地址必须以 http:// 或 https:// 开头');
      }
      if (_profiles.any(
        (item) => item.id != profile.id && item.url == nextUrl,
      )) {
        throw const FormatException('这个订阅已经添加过了');
      }
      profile.url = nextUrl;
    }
    if (name != null && name.trim().isNotEmpty) profile.name = name.trim();
    if (certPin != null) profile.certPin = certPin.trim();
    await _persistProfiles();
    _notify();
  }

  Future<void> removeProfile(String id) async {
    _profiles.removeWhere((item) => item.id == id);
    if (_activeId == id) {
      _activeId = _profiles.isEmpty ? null : _profiles.first.id;
    }
    await _persistProfiles();
    _notify();
  }

  Future<void> setActive(String id) async {
    final target = _profiles.where((item) => item.id == id).firstOrNull;
    if (target == null) return;
    _activeId = id;
    await _persistProfiles();
    _notify();
    unawaited(refreshUsage(profile: target));
  }

  /// 拉一次订阅，返回节点数量，用于添加前的连通性检查。
  Future<int> probeProfile(Profile profile) async {
    final nodes = await fetchNodes(profile);
    return nodes.length;
  }

  /// 拉订阅并解析出节点列表，供订阅页展开查看。
  Future<List<SubscriptionNode>> fetchNodes(Profile profile) async {
    final raw = await SubscriptionClient.fetch(
      profile.url,
      certPin: _pinFor(profile),
    );
    final outbounds = raw['outbounds'];
    if (outbounds is! List) return const [];
    return outbounds
        .whereType<Map>()
        .map(
          (item) =>
              SubscriptionNode.fromOutbound(Map<String, dynamic>.from(item)),
        )
        .whereType<SubscriptionNode>()
        .toList(growable: false);
  }

  Future<void> updateProfilePin(String id, String pin) async {
    final profile = _profiles.where((item) => item.id == id).firstOrNull;
    if (profile == null) return;
    profile.certPin = pin.trim();
    await _persistProfiles();
    _notify();
  }

  /// 选择节点；返回 true 表示当前连接已经即时生效。
  Future<bool> selectNode(Profile profile, String tag) async {
    profile.selectedNode = tag;
    await _persistProfiles();
    _notify();
    final api = _api;
    if (api == null || profile.id != _activeId) return false;
    try {
      await api.select('proxy', tag.isEmpty ? 'auto' : tag);
      return true;
    } catch (_) {
      // 当前连接使用的是旧配置（还没有 selector 组），下次连接生效。
      return false;
    }
  }

  Future<int> testNode(String tag) async {
    final api = _api;
    if (api == null) {
      throw const FormatException('请先连接后再测速');
    }
    return api.delay(tag);
  }

  String _pinFor(Profile profile) {
    return profile.certPin.isNotEmpty ? profile.certPin : _settings.certPin;
  }

  // ---------------------------------------------------------------- 连接

  Future<void> toggle() async {
    if (_status == CoreStatus.connected) {
      await disconnect();
    } else if (_status != CoreStatus.connecting) {
      await connect();
    }
  }

  Future<void> connect() async {
    if (_busy ||
        _status == CoreStatus.connected ||
        _status == CoreStatus.connecting) {
      return;
    }
    final profile = activeProfile;
    if (profile == null) {
      _error = '请先在「订阅」里添加面板订阅地址';
      _status = CoreStatus.error;
      _notify();
      return;
    }

    _busy = true;
    _error = null;
    _status = CoreStatus.connecting;
    _logs.clear();
    _notify();

    try {
      _info('正在拉取订阅：${profile.name}');
      final raw = await SubscriptionClient.fetch(
        profile.url,
        certPin: _pinFor(profile),
      );

      _clashPort = await _freePort();
      final config = patchClientConfig(
        jsonEncode(raw),
        ClientConfigOptions(
          mixedPort: _settings.mixedPort,
          clashPort: _clashPort,
          logLevel: _settings.logLevel,
          enableTun: Platform.isAndroid || _settings.enableTun,
          enableIpv6: _settings.enableIpv6,
          tunStack: normalizeTunStack(_settings.tunStack),
          tunMtu: _settings.tunMtu,
          allowLan: _settings.allowLan,
          dnsMode: _settings.dnsMode,
          dnsServers: _settings.dnsServers,
          dnsStrategy: _settings.dnsStrategy,
          hosts: _settings.hosts,
          selectedNode: profile.selectedNode,
          rulesDir: _rulesDir,
          customRules: _settings.customRules,
          dnsCnDirect: Platform.isWindows,
        ),
      );
      _info('配置已生成，Clash API 127.0.0.1:$_clashPort');

      if (Platform.isAndroid) {
        final granted = await _vpn.prepare();
        if (!granted) {
          throw const FormatException('没有拿到 VPN 权限，请重新点击并在系统弹窗里允许');
        }
        final notification = await _vpn.ensureNotificationPermission();
        if (!notification) {
          throw const FormatException(
            '通知权限被拒绝，代理无法保持后台驻留。请到「设置 → 后台驻留 → 通知设置」允许通知后重试',
          );
        }
        _vpnSub = _vpn.state.listen(_onVpnState);
        await _vpn.start(
          config: config,
          clashPort: _clashPort,
          allowedPackages: _settings.proxyApps,
          directPackages: _settings.directApps,
        );
      } else {
        final runner = SingBoxRunner(
          binaryPath: resolveCoreBinary(),
          workDir: p.join(_dataDir, 'core'),
          encrypt: Dpapi.protect,
        );
        _runner = runner;
        _processLogSub = runner.logs.map(LogEntry.parse).listen(_appendLog);
        _exitSub = runner.exits.listen(_onCoreExit);
        await runner.start(config, clashPort: _clashPort);
      }

      final api = ClashApi(port: _clashPort);
      _api = api;
      await _waitForApi(api);
      _coreVersion = await api.version();
      _info('内核就绪：$_coreVersion');

      if (Platform.isAndroid) {
        _apiLogSub = api
            .logs(level: _settings.logLevel)
            .listen(_appendLog, onError: (Object _) {});
      }

      _trafficSub = api.traffic().listen((sample) {
        _traffic = sample;
        _notify();
      }, onError: (Object _) {});
      // 连上之后立刻刷新一次面板用量，用户能看到最新的已用流量。
      unawaited(refreshUsage(profile: profile));

      _connectedAt = DateTime.now();
      _startTimers();
      _status = CoreStatus.connected;
    } catch (e) {
      await _teardown();
      _error = _friendly(e);
      _status = CoreStatus.error;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> disconnect() async {
    if (_status == CoreStatus.idle || _status == CoreStatus.stopping) return;
    _stopping = true;
    _status = CoreStatus.stopping;
    _notify();
    await _teardown();
    _status = CoreStatus.idle;
    _stopping = false;
    _notify();
  }

  // ---------------------------------------------------------------- 设置

  Future<void> updateSettings(AppSettings next) async {
    _settings = next;
    _applyKeyboardConfig();
    await _store.set(_kSettings, next.toJson());
    _notify();
  }

  /// 设置页打开时调用：把当前设置重新推给输入法，纠正可能过期的原生状态。
  void syncKeyboardConfig() => _applyKeyboardConfig();

  /// 把输入法相关设置同步给内置键盘（键盘是全局单例，拿不到 state），
  /// 同时推给原生系统输入法——它跑在 IME 窗口里，读不到这里的 settings。
  void _applyKeyboardConfig() {
    KeyboardConfig.builtin.value = _settings.imeBuiltin;
    if (!_settings.imeBuiltin && PasswordKeyboard.isOpen) {
      PasswordKeyboard.hide();
    }
    KeyboardConfig.chinese = _settings.imeChinese;
    KeyboardConfig.candidates = _settings.imeCandidates;
    KeyboardConfig.fuzzy = _settings.imeFuzzy;
    KeyboardConfig.sentence = _settings.imeSentence;
    KeyboardConfig.layout = _settings.imeLayout;
    KeyboardConfig.global = _settings.imeGlobal;
    if (Platform.isAndroid) {
      unawaited(
        SystemIme.configure(
          chinese: _settings.imeChinese,
          layout: _settings.imeLayout,
          fuzzy: _settings.imeFuzzy,
          sentence: _settings.imeSentence,
          candidates: _settings.imeCandidates,
          height: _settings.imeHeight,
          scale: _settings.imeScale,
          learn: _settings.imeLearn,
          clipboard: _settings.imeClipboard,
          accent: _settings.accent,
          accentMode: _settings.imeAccentMode,
          accentColor: _settings.imeAccentColor,
          darkMode: _settings.imeDarkMode,
          themeMode: _settings.themeMode,
          sound: _settings.imeSound,
          vibrate: _settings.imeVibrate,
          vibrateAmplitude: _settings.imeVibrateAmplitude,
          autocorrect: _settings.imeAutocorrect,
          customPalette: _settings.imeCustomPalette,
          bgColor: _settings.imeBgColor,
          keyColor: _settings.imeKeyColor,
          textColor: _settings.imeTextColor,
        ),
      );
    }
  }

  /// Windows 专用：迁移数据目录并记住位置。
  Future<void> changeDataDir(String raw) async {
    if (!Platform.isWindows) {
      throw const FormatException('只有 Windows 端支持自定义数据目录');
    }
    if (_status == CoreStatus.connected ||
        _status == CoreStatus.connecting ||
        _status == CoreStatus.stopping) {
      throw const FormatException('请先断开代理再更改数据目录');
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty || !p.isAbsolute(trimmed)) {
      throw const FormatException(r'请输入完整路径，例如 D:\HorseBoxData');
    }
    final newDir = p.normalize(trimmed);
    final oldDir = p.normalize(p.absolute(_dataDir));
    final oldKey = oldDir.toLowerCase();
    final newKey = newDir.toLowerCase();
    if (newKey == oldKey) return;
    if (p.isWithin(oldKey, newKey) || p.isWithin(newKey, oldKey)) {
      throw const FormatException('新目录不能是当前目录的上级或子目录');
    }

    await Directory(newDir).create(recursive: true);
    await copyDataDir(oldDir, newDir);
    await writeWindowsDataDir(newDir);
    _store = await LocalStore.open(newDir);
    _dataDir = newDir;
    _notify();
  }

  void clearLogs() {
    _logs.clear();
    _notify();
  }

  Future<void> refreshConnections() async {
    final api = _api;
    if (api == null) return;
    try {
      _connections = await api.connections();
      _notify();
    } catch (_) {
      // 内核正在重启或页面不可用，忽略下一次轮询再试。
    }
  }

  // ---------------------------------------------------------------- 内部

  Future<void> _waitForApi(ClashApi api) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (!Platform.isAndroid && _runner != null && !_runner!.running) {
        throw const FormatException('内核启动失败，请到「日志」查看原因');
      }
      try {
        await api.version();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw const FormatException('内核启动超时，请到「日志」查看原因');
  }

  Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  void _startTimers() {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => refreshConnections(),
    );
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _notify());
  }

  Future<void> _teardown() async {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    _pollTimer = null;
    _tickTimer = null;

    // 取消订阅本身可能等 WebSocket 关闭，不能让它挡住“断开”按钮。
    unawaited(_trafficSub?.cancel() ?? Future<void>.value());
    unawaited(_apiLogSub?.cancel() ?? Future<void>.value());
    unawaited(_processLogSub?.cancel() ?? Future<void>.value());
    unawaited(_exitSub?.cancel() ?? Future<void>.value());
    unawaited(_vpnSub?.cancel() ?? Future<void>.value());
    _trafficSub = null;
    _apiLogSub = null;
    _processLogSub = null;
    _exitSub = null;
    _vpnSub = null;

    final runner = _runner;
    _runner = null;
    _api = null;
    if (Platform.isAndroid) {
      unawaited(_vpn.stop().catchError((Object _) {}));
    } else {
      unawaited(runner?.stop() ?? Future<void>.value());
    }
    _traffic = const TrafficSample();
    _connections = const [];
    _connectedAt = null;
    _coreVersion = '';
  }

  void _onCoreExit(int code) {
    if (_stopping || _status != CoreStatus.connected) return;
    _error = '内核异常退出（code=$code），请到「日志」查看原因';
    _status = CoreStatus.error;
    unawaited(_teardown());
    _notify();
  }

  void _onVpnState(bool running) {
    if (running || _stopping || _status != CoreStatus.connected) return;
    _error = 'VPN 服务已停止（可能被系统回收），请重新连接';
    _status = CoreStatus.error;
    unawaited(_teardown());
    _notify();
  }

  void _appendLog(LogEntry entry) {
    _logs.add(entry);
    if (_logs.length > _settings.logLimit) {
      _logs.removeRange(0, _logs.length - _settings.logLimit);
    }
    _notify();
  }

  void _info(String message) {
    _appendLog(LogEntry(time: DateTime.now(), level: 'INFO', message: message));
  }

  String _friendly(Object error) {
    var text = error.toString();
    if (text.startsWith('Exception: ')) text = text.substring(11);
    return text;
  }

  Future<void> _persistProfiles() async {
    final rows = <Map<String, dynamic>>[];
    for (final item in _profiles) {
      final row = item.toJson();
      row['url'] = await _seal(item.url);
      rows.add(row);
    }
    await _store.set(_kProfiles, rows);
    if (_activeId == null) {
      await _store.remove(_kActive);
    } else {
      await _store.set(_kActive, _activeId);
    }
  }

  /// 敏感字段落盘前加密。密钥不可用时直接报错，绝不把明文写进配置。
  Future<String> _seal(String plain) async {
    if (plain.isEmpty) return plain;
    final vault = _vault;
    if (vault == null) {
      throw StateError('密钥不可用，已取消保存，避免明文落盘');
    }
    return vault.seal(plain);
  }

  Future<String> _unseal(String stored) async {
    if (stored.isEmpty) return stored;
    final vault = _vault;
    if (vault == null) {
      return SecretVault.isSealed(stored) ? '' : stored;
    }
    return vault.openText(stored);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    _usageTimer?.cancel();
    _trafficSub?.cancel();
    _apiLogSub?.cancel();
    _processLogSub?.cancel();
    _exitSub?.cancel();
    _vpnSub?.cancel();
    if (Platform.isAndroid) {
      unawaited(_vpn.stop().catchError((_) {}));
    } else {
      unawaited(_runner?.stop() ?? Future<void>.value());
    }
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
