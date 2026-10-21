/// 数据模型：订阅、设置、流量、日志、连接。
library;

/// 一条订阅配置。
class Profile {
  Profile({
    required this.id,
    required this.name,
    required this.url,
    this.certPin = '',
    this.selectedNode = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  String url;

  /// 这个订阅专用的面板证书 SHA-256 指纹，留空时回落到全局设置。
  String certPin;

  /// 手动选择的节点 tag；空字符串表示自动（urltest）。
  String selectedNode;

  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'cert_pin': certPin,
    'selected_node': selectedNode,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? '未命名',
      url: json['url'] as String? ?? '',
      certPin: json['cert_pin'] as String? ?? '',
      selectedNode: json['selected_node'] as String? ?? '',
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }
}

/// 全局设置。
class AppSettings {
  const AppSettings({
    this.mixedPort = 7890,
    this.allowLan = false,
    this.enableTun = true,
    this.enableIpv6 = false,
    this.proxyApps = const [],
    this.directApps = const [],
    this.customRules = const [],
    this.tunStack = 'mixed',
    this.tunMtu = 9000,
    this.logLevel = 'info',
    this.dnsMode = 'panel',
    this.dnsServers = const ['223.5.5.5'],
    this.dnsStrategy = 'prefer_ipv4',
    this.hosts = const {},
    this.certPin = '',
    this.themeMode = 'dark',
    this.autoConnect = false,
    this.logLimit = 800,
    this.panelUrl = '',
    this.panelPin = '',
  });

  final int mixedPort;
  final bool allowLan;
  final bool enableTun;

  /// 是否启用 IPv6，默认关闭（只用 IPv4）。
  final bool enableIpv6;

  /// 走代理的用户应用包名；空列表表示全部用户应用。系统应用始终直连。
  final List<String> proxyApps;

  /// 强制直连的应用包名，始终不进入 VPN。
  final List<String> directApps;
  final List<RouteRuleSetting> customRules;
  final String tunStack;
  final int tunMtu;
  final String logLevel;

  /// panel = 沿用面板下发；custom = 使用下面的 dnsServers。
  final String dnsMode;
  final List<String> dnsServers;
  final String dnsStrategy;

  /// 私有域名映射：域名 -> IP 列表。
  final Map<String, List<String>> hosts;

  /// 面板自签证书的 SHA-256 指纹（十六进制，可带冒号）。
  final String certPin;

  /// system / light / dark。
  final String themeMode;
  final bool autoConnect;
  final int logLimit;

  /// 面板地址（仅 HTTPS），以及用于 TLS 指纹固定的 SHA-256。
  final String panelUrl;
  final String panelPin;

  AppSettings copyWith({
    int? mixedPort,
    bool? allowLan,
    bool? enableTun,
    bool? enableIpv6,
    List<String>? proxyApps,
    List<String>? directApps,
    List<RouteRuleSetting>? customRules,
    String? tunStack,
    int? tunMtu,
    String? logLevel,
    String? dnsMode,
    List<String>? dnsServers,
    String? dnsStrategy,
    Map<String, List<String>>? hosts,
    String? certPin,
    String? themeMode,
    bool? autoConnect,
    int? logLimit,
    String? panelUrl,
    String? panelPin,
  }) {
    return AppSettings(
      mixedPort: mixedPort ?? this.mixedPort,
      allowLan: allowLan ?? this.allowLan,
      enableTun: enableTun ?? this.enableTun,
      enableIpv6: enableIpv6 ?? this.enableIpv6,
      proxyApps: proxyApps ?? this.proxyApps,
      directApps: directApps ?? this.directApps,
      customRules: customRules ?? this.customRules,
      tunStack: tunStack ?? this.tunStack,
      tunMtu: tunMtu ?? this.tunMtu,
      logLevel: logLevel ?? this.logLevel,
      dnsMode: dnsMode ?? this.dnsMode,
      dnsServers: dnsServers ?? this.dnsServers,
      dnsStrategy: dnsStrategy ?? this.dnsStrategy,
      hosts: hosts ?? this.hosts,
      certPin: certPin ?? this.certPin,
      themeMode: themeMode ?? this.themeMode,
      autoConnect: autoConnect ?? this.autoConnect,
      logLimit: logLimit ?? this.logLimit,
      panelUrl: panelUrl ?? this.panelUrl,
      panelPin: panelPin ?? this.panelPin,
    );
  }

  Map<String, dynamic> toJson() => {
    'mixed_port': mixedPort,
    'allow_lan': allowLan,
    'enable_tun': enableTun,
    'enable_ipv6': enableIpv6,
    'proxy_apps': proxyApps,
    'direct_apps': directApps,
    'custom_rules': customRules.map((item) => item.toJson()).toList(),
    'tun_stack': tunStack,
    'tun_mtu': tunMtu,
    'log_level': logLevel,
    'dns_mode': dnsMode,
    'dns_servers': dnsServers,
    'dns_strategy': dnsStrategy,
    'hosts': hosts,
    'cert_pin': certPin,
    'theme_mode': themeMode,
    'auto_connect': autoConnect,
    'log_limit': logLimit,
    'panel_url': panelUrl,
    'panel_pin': panelPin,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final rawHosts = json['hosts'];
    final hosts = <String, List<String>>{};
    if (rawHosts is Map) {
      rawHosts.forEach((key, value) {
        if (key is String && value is List) {
          final ips = value.whereType<String>().toList(growable: false);
          if (ips.isNotEmpty) hosts[key] = ips;
        }
      });
    }
    final servers = json['dns_servers'];
    return AppSettings(
      mixedPort: (json['mixed_port'] as num?)?.toInt() ?? 7890,
      allowLan: json['allow_lan'] as bool? ?? false,
      enableTun: json['enable_tun'] as bool? ?? true,
      enableIpv6: json['enable_ipv6'] as bool? ?? false,
      proxyApps:
          (json['proxy_apps'] as List?)?.whereType<String>().toList(
            growable: false,
          ) ??
          const [],
      directApps:
          (json['direct_apps'] as List?)?.whereType<String>().toList(
            growable: false,
          ) ??
          const [],
      customRules:
          (json['custom_rules'] as List?)
              ?.whereType<Map>()
              .map(
                (item) =>
                    RouteRuleSetting.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((item) => item.value.isNotEmpty)
              .toList(growable: false) ??
          const [],
      tunStack: normalizeTunStack(json['tun_stack'] as String?),
      tunMtu: (json['tun_mtu'] as num?)?.toInt() ?? 9000,
      logLevel: json['log_level'] as String? ?? 'info',
      dnsMode: json['dns_mode'] as String? ?? 'panel',
      dnsServers: servers is List
          ? servers.whereType<String>().toList(growable: false)
          : const ['223.5.5.5'],
      dnsStrategy: json['dns_strategy'] as String? ?? 'prefer_ipv4',
      hosts: hosts,
      certPin: json['cert_pin'] as String? ?? '',
      themeMode: json['theme_mode'] as String? ?? 'dark',
      autoConnect: json['auto_connect'] as bool? ?? false,
      logLimit: (json['log_limit'] as num?)?.toInt() ?? 800,
      panelUrl: json['panel_url'] as String? ?? '',
      panelPin: json['panel_pin'] as String? ?? '',
    );
  }
}

/// 实时速率（字节/秒）。
class TrafficSample {
  const TrafficSample({this.up = 0, this.down = 0});

  final int up;
  final int down;
}

/// 一条日志。
class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  final DateTime time;
  final String level;
  final String message;

  /// 解析 sing-box 进程输出：`+0800 12:00:00 INFO ...`。
  factory LogEntry.parse(String line) {
    final now = DateTime.now();
    final text = line.trimRight();
    final match = RegExp(
      r'^(?:[+-]\d{4}\s+)?(\d{2}:\d{2}:\d{2})\s+(TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+(.*)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) {
      final level = text.contains('ERROR') || text.contains('FATAL')
          ? 'ERROR'
          : text.contains('WARN')
          ? 'WARN'
          : 'INFO';
      return LogEntry(time: now, level: level, message: text);
    }
    final parts = match.group(1)!.split(':').map(int.parse).toList();
    return LogEntry(
      time: DateTime(
        now.year,
        now.month,
        now.day,
        parts[0],
        parts[1],
        parts[2],
      ),
      level: match.group(2)!.toUpperCase(),
      message: match.group(3)!,
    );
  }

  /// 解析 Clash API `/logs` 的 JSON 消息。
  factory LogEntry.fromClash(Map<String, dynamic> json) {
    return LogEntry(
      time: DateTime.now(),
      level: (json['type'] as String? ?? 'info').toUpperCase(),
      message: json['payload'] as String? ?? '',
    );
  }
}

/// 一条活动连接。
class ConnectionRow {
  const ConnectionRow({
    required this.id,
    required this.host,
    required this.rule,
    required this.chains,
    required this.upload,
    required this.download,
    required this.start,
  });

  final String id;
  final String host;
  final String rule;
  final List<String> chains;
  final int upload;
  final int download;
  final DateTime? start;

  int get total => upload + download;

  factory ConnectionRow.fromJson(Map<String, dynamic> json) {
    final meta = json['metadata'];
    final metadata = meta is Map ? meta : const {};
    final chains = json['chains'];
    return ConnectionRow(
      id: json['id'] as String? ?? '',
      host: (metadata['host'] as String?)?.isNotEmpty == true
          ? metadata['host'] as String
          : '${metadata['destinationIP'] ?? ''}:${metadata['destinationPort'] ?? ''}',
      rule: json['rule'] as String? ?? '',
      chains: chains is List
          ? chains.whereType<String>().toList(growable: false)
          : const [],
      upload: (json['upload'] as num?)?.toInt() ?? 0,
      download: (json['download'] as num?)?.toInt() ?? 0,
      start: DateTime.tryParse(json['start'] as String? ?? ''),
    );
  }
}

/// `system` 栈在 Android 上会卡死、在 Windows 上容易超时，客户端只保留
/// mixed / gvisor 两种稳定值；旧配置里的 system 统一回落到 mixed。
String normalizeTunStack(String? value) =>
    value == 'gvisor' ? 'gvisor' : 'mixed';

/// 订阅里的一个节点（来自 sing-box outbounds）。
class SubscriptionNode {
  const SubscriptionNode({
    required this.tag,
    required this.type,
    required this.server,
    required this.port,
  });

  final String tag;
  final String type;
  final String server;
  final int port;

  String get endpoint {
    if (server.isEmpty) return '—';
    final host = server.contains(':') ? '[$server]' : server;
    return port > 0 ? '$host:$port' : host;
  }

  static SubscriptionNode? fromOutbound(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? '';
    if (type.isEmpty || type == 'direct' || type == 'block') return null;
    final server = json['server'] as String? ?? '';
    if (server.isEmpty) return null;
    return SubscriptionNode(
      tag: json['tag'] as String? ?? type,
      type: type,
      server: server,
      port: (json['server_port'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 用户自定义的一条分流规则。
class RouteRuleSetting {
  const RouteRuleSetting({
    required this.type,
    required this.value,
    required this.outbound,
  });

  /// domain_suffix / domain_keyword / ip_cidr
  final String type;
  final String value;

  /// direct / proxy / reject
  final String outbound;

  Map<String, dynamic> toJson() => {
    'type': type,
    'value': value,
    'outbound': outbound,
  };

  factory RouteRuleSetting.fromJson(Map<String, dynamic> json) {
    return RouteRuleSetting(
      type: json['type'] as String? ?? 'domain_suffix',
      value: json['value'] as String? ?? '',
      outbound: json['outbound'] as String? ?? 'direct',
    );
  }
}

/// 一条 SSH 主机配置（「配置」页手动添加）。
class SshHost {
  SshHost({
    required this.id,
    this.name = '',
    required this.host,
    this.port = 22,
    required this.username,
    this.password = '',
    this.fingerprint = '',
  });

  final String id;
  String name;
  String host;
  int port;
  String username;
  String password;

  /// 首次连接记录的主机密钥 SHA-256（十六进制），之后每次连接都必须一致。
  String fingerprint;

  /// 这台主机配置的本地端口转发规则。
  final List<SshForward> forwards = [];

  String get label => name.trim().isEmpty ? username + '@' + host : name;

  String get endpoint => username + '@' + host + ':' + port.toString();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'fingerprint': fingerprint,
    'forwards': forwards.map((item) => item.toJson()).toList(),
  };

  factory SshHost.fromJson(Map<String, dynamic> json) {
    return SshHost(
        id:
            json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? '',
        host: json['host'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        fingerprint: json['fingerprint'] as String? ?? '',
      )
      ..forwards.addAll(
        (json['forwards'] as List? ?? const []).whereType<Map>().map(
          (item) => SshForward.fromJson(Map<String, dynamic>.from(item)),
        ),
      );
  }
}

/// 一条本地端口转发规则：把 127.0.0.1:localPort 转发到远端 host:port。
class SshForward {
  SshForward({
    required this.id,
    this.label = '',
    required this.localPort,
    required this.host,
    required this.port,
  });

  final String id;
  String label;
  int localPort;
  String host;
  int port;

  String get title => label.trim().isEmpty ? summary : label.trim();

  String get summary => '127.0.0.1:$localPort → $host:$port';

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'local_port': localPort,
    'host': host,
    'port': port,
  };

  factory SshForward.fromJson(Map<String, dynamic> json) {
    return SshForward(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      label: json['label'] as String? ?? '',
      localPort: (json['local_port'] as num?)?.toInt() ?? 0,
      host: json['host'] as String? ?? '127.0.0.1',
      port: (json['port'] as num?)?.toInt() ?? 80,
    );
  }
}

/// 面板登录凭据：一个面板一条，登录时一键填入。
class PanelCredential {
  PanelCredential({
    required this.id,
    required this.panel,
    required this.username,
    this.password = '',
  });

  final String id;

  /// 面板地址，去掉协议和尾部斜杠，用作去重键。
  String panel;
  String username;
  String password;

  Map<String, dynamic> toJson() => {
    'id': id,
    'panel': panel,
    'username': username,
    'password': password,
  };

  factory PanelCredential.fromJson(Map<String, dynamic> json) {
    return PanelCredential(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      panel: json['panel'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
    );
  }
}
