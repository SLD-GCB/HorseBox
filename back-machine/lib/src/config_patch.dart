import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

/// 生成客户端运行配置时的参数。
class ClientConfigOptions {
  const ClientConfigOptions({
    required this.mixedPort,
    required this.clashPort,
    this.logLevel = 'info',
    this.enableTun = true,
    this.enableIpv6 = true,
    this.tunStack = 'mixed',
    this.tunMtu = 9000,
    this.allowLan = false,
    this.dnsMode = 'panel',
    this.dnsServers = const [],
    this.dnsStrategy = 'prefer_ipv4',
    this.hosts = const {},
    this.selectedNode = '',
    this.rulesDir = '',
    this.customRules = const [],
    this.dnsCnDirect = false,
  });

  final int mixedPort;
  final int clashPort;
  final String logLevel;
  final bool enableTun;

  /// 是否允许 IPv6。Windows 上很多网络没有可用 IPv6，
  /// DNS 返回 AAAA 后直连会报 network is unreachable。
  final bool enableIpv6;
  final String tunStack;
  final int tunMtu;
  final bool allowLan;
  final String dnsMode;
  final List<String> dnsServers;
  final String dnsStrategy;
  final Map<String, List<String>> hosts;

  /// 手动选择的节点 tag；空字符串表示自动选择。
  final String selectedNode;

  /// 放 geosite-cn.srs / geoip-cn.srs 的目录；为空则不加内置中国直连。
  final String rulesDir;
  final List<RouteRuleSetting> customRules;

  /// 为 true 时国内域名走系统 DNS 直连，其余走面板 dns-proxy；
  /// 仅在 Windows 开启，避免安卓走 local 解析器。
  final bool dnsCnDirect;
}

/// 把面板下发的 sing-box 配置补成可直接运行的客户端配置。
String patchClientConfig(String raw, ClientConfigOptions opts) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('面板返回的配置不是 JSON 对象');
  }
  final root = Map<String, dynamic>.from(decoded);

  root['log'] = <String, dynamic>{
    'level': opts.logLevel,
    'timestamp': true,
  };

  final experimental = _asMap(root['experimental']);
  experimental['clash_api'] = <String, dynamic>{
    'external_controller': '127.0.0.1:${opts.clashPort}',
  };
  // 缓存文件对客户端没有价值，却会在内核被强杀后留下文件锁。
  experimental['cache_file'] = <String, dynamic>{'enabled': false};
  root['experimental'] = experimental;

  final inbounds = _asList(root['inbounds'])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
  inbounds.removeWhere((item) => item['type'] == 'mixed');

  final tun = inbounds.where((item) => item['type'] == 'tun').firstOrNull;
  if (opts.enableTun) {
    if (tun != null) {
      tun['stack'] = opts.tunStack;
      tun['mtu'] = opts.tunMtu;
      tun['auto_route'] = true;
      tun['strict_route'] = true;
      if (!opts.enableIpv6) _dropIpv6Address(tun);
    } else {
      inbounds.insert(0, <String, dynamic>{
        'type': 'tun',
        'tag': 'tun-in',
        'address': [
          '172.19.0.1/30',
          if (opts.enableIpv6) 'fdfe:dcba:9876::1/126',
        ],
        'mtu': opts.tunMtu,
        'auto_route': true,
        'strict_route': true,
        'stack': opts.tunStack,
      });
    }
  } else {
    inbounds.removeWhere((item) => item['type'] == 'tun');
  }

  inbounds.add(<String, dynamic>{
    'type': 'mixed',
    'tag': 'mixed-in',
    'listen': opts.allowLan ? '0.0.0.0' : '127.0.0.1',
    'listen_port': opts.mixedPort,
  });
  root['inbounds'] = inbounds;

  if (opts.dnsMode == 'custom' && opts.dnsServers.isNotEmpty) {
    _ensureDnsDirectOutbound(root);
  }
  _patchDns(root, opts);
  _applyProxySelection(root, opts.selectedNode);
  _applyRouteRules(root, opts);

  return const JsonEncoder.withIndent('  ').convert(root);
}

/// 多节点时把面板的 urltest 改成「自动组 + 手动选择组」。
///
/// 最终 route.final 仍指向 proxy（selector），所以切换节点不需要改路由；
/// Clash API 可以直接对 proxy 这个组做 PUT 切换和节点测速。
void _applyProxySelection(Map<String, dynamic> root, String selected) {
  final raw = _asList(root['outbounds'])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
  final nodes = <Map<String, dynamic>>[];
  final others = <Map<String, dynamic>>[];
  for (final outbound in raw) {
    final type = outbound['type'];
    if (type == 'urltest' || type == 'selector') continue;
    if (type == 'direct' || type == 'block') {
      others.add(outbound);
    } else {
      nodes.add(outbound);
    }
  }
  if (nodes.length < 2) return;

  final tags = nodes.map((item) => item['tag']).whereType<String>().toList();
  // 节点名和组名冲突时保持原配置，避免生成重复 tag 的非法配置。
  if (tags.length != nodes.length || tags.contains('auto') || tags.contains('proxy')) {
    return;
  }

  root['outbounds'] = [
    ...nodes,
    ...others,
    <String, dynamic>{
      'type': 'urltest',
      'tag': 'auto',
      'outbounds': tags,
      'url': 'http://www.gstatic.com/generate_204',
      'interval': '3m',
      'tolerance': 50,
    },
    <String, dynamic>{
      'type': 'selector',
      'tag': 'proxy',
      'outbounds': ['auto', ...tags],
      'default': tags.contains(selected) ? selected : 'auto',
    },
  ];
}

void _patchDns(Map<String, dynamic> root, ClientConfigOptions opts) {
  final dns = _asMap(root['dns']);
  final servers = _asList(dns['servers'])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .where((item) => item['tag'] != 'horsebox-hosts' && !('${item['tag']}'.startsWith('horsebox-dns-')))
      .toList();

  final rules = _asList(dns['rules'])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .where((item) => item['server'] != 'horsebox-hosts')
      .toList();

  final custom = <Map<String, dynamic>>[];
  if (opts.dnsMode == 'custom') {
    for (var i = 0; i < opts.dnsServers.length; i++) {
      final server = _serverFromUri(opts.dnsServers[i], i);
      if (server != null) custom.add(server);
    }
  }

  if (opts.hosts.isNotEmpty) {
    final predefined = <String, List<String>>{};
    opts.hosts.forEach((domain, ips) {
      final clean = ips
          .map((ip) => ip.trim())
          .where((ip) => ip.isNotEmpty)
          .toList(growable: false);
      if (domain.trim().isNotEmpty && clean.isNotEmpty) {
        predefined[domain.trim()] = clean;
      }
    });
    if (predefined.isNotEmpty) {
      servers.insert(0, <String, dynamic>{
        'type': 'hosts',
        'tag': 'horsebox-hosts',
        'predefined': predefined,
      });
      rules.insert(0, <String, dynamic>{
        'domain': predefined.keys.toList(),
        'server': 'horsebox-hosts',
      });
    }
  }

  if (custom.isNotEmpty) {
    servers.insertAll(0, custom);
    final cnTag = custom.first['tag'] as String;
    // Windows 上国内域名用自定义 DNS 直连，国外仍走面板的代理 DNS，
    // 避免一刀切后 YouTube 等境外域名被国内 DNS 污染。
    if (opts.dnsCnDirect) {
      final anchor = dns['final'];
      if (anchor is String && anchor.isNotEmpty && anchor != cnTag) {
        final cnRules = <Map<String, dynamic>>[];
        if (opts.rulesDir.isNotEmpty) {
          cnRules.add({'rule_set': ['geosite-cn'], 'server': cnTag});
        }
        cnRules.add({'domain_suffix': ['.cn'], 'server': cnTag});
        rules.insertAll(0, cnRules);
        dns['final'] = anchor;
      } else {
        dns['final'] = cnTag;
      }
    } else {
      dns['final'] = cnTag;
    }
    dns['strategy'] = opts.dnsStrategy;
  } else if (opts.dnsCnDirect) {
    // 面板 DNS 模式下，国内域名交给系统解析器，避免 DoH 从境外返回 CDN 地址。
    final hasDirect = servers.any((item) => item['tag'] == 'dns-direct');
    if (hasDirect) {
      final cnRules = <Map<String, dynamic>>[];
      if (opts.rulesDir.isNotEmpty) {
        cnRules.add({'rule_set': ['geosite-cn'], 'server': 'dns-direct'});
      }
      cnRules.add({'domain_suffix': ['.cn'], 'server': 'dns-direct'});
      rules.insertAll(0, cnRules);
    }
  }

  dns['servers'] = servers;
  if (rules.isNotEmpty) dns['rules'] = rules;
  // Windows 无可用 IPv6 时只查 A 记录，避免 AAAA 导致 network is unreachable。
  if (!opts.enableIpv6) dns['strategy'] = 'ipv4_only';
  root['dns'] = dns;
}

void _dropIpv6Address(Map<String, dynamic> tun) {
  final address = tun['address'];
  if (address is! List) return;
  tun['address'] = address
      .whereType<String>()
      .where((item) => !item.contains(':'))
      .toList(growable: false);
}


Map<String, dynamic>? _serverFromUri(String input, int index) {
  final raw = normalizeDnsServer(input);
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw.contains('://') ? raw : 'udp://$raw');
  if (uri == null || uri.host.isEmpty) return null;
  final type = switch (uri.scheme) {
    'https' => 'https',
    'tls' => 'tls',
    _ => 'udp',
  };
  return <String, dynamic>{
    'type': type,
    'tag': 'horsebox-dns-$index',
    'server': uri.host,
    if (uri.hasPort) 'server_port': uri.port,
    if (type == 'https' && uri.path.isNotEmpty) 'path': uri.path,
    // 自定义 DNS 一律直连解析，避免从代理节点所在地拿到错误的 CDN IP。
    'detour': 'horsebox-dns-direct',
  };
}

/// 裸 IPv6 自动补方括号：
///
///   2400:3200::1        -> [2400:3200::1]
///   udp://2400:3200::1  -> udp://[2400:3200::1]
///
/// 带端口时必须自己写方括号，因为 `::1:53` 本身也是合法 IPv6 地址。
String normalizeDnsServer(String input) {
  final value = input.trim();
  if (value.isEmpty) return value;
  var rest = value;
  var prefix = '';
  final schemeIndex = value.indexOf('://');
  if (schemeIndex >= 0) {
    prefix = value.substring(0, schemeIndex + 3);
    rest = value.substring(schemeIndex + 3);
  }
  if (rest.isEmpty || rest.startsWith('[') || rest.contains('/')) return value;

  final parsed = InternetAddress.tryParse(rest);
  if (parsed != null && parsed.type == InternetAddressType.IPv6) {
    return '$prefix[$rest]';
  }
  return value;
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

List<dynamic> _asList(Object? value) {
  if (value is List) return List<dynamic>.from(value);
  return <dynamic>[];
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}


void _applyRouteRules(Map<String, dynamic> root, ClientConfigOptions opts) {
  final route = _asMap(root['route']);
  final existing = _asList(route['rules'])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
  final ruleSets = _asList(route['rule_set'])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .where((item) => item['tag'] != 'geosite-cn' && item['tag'] != 'geoip-cn')
      .toList();

  final userRules = <Map<String, dynamic>>[];
  for (final rule in opts.customRules) {
    if (rule.value.trim().isEmpty) continue;
    final value = rule.value.trim();
    final action = <String, dynamic>{};
    switch (rule.type) {
      case 'domain_keyword':
        action['domain_keyword'] = [value];
      case 'ip_cidr':
        action['ip_cidr'] = [value];
      default:
        action['domain_suffix'] = [value];
    }
    if (rule.outbound == 'reject') {
      action['action'] = 'reject';
    } else {
      action['outbound'] = rule.outbound == 'proxy' ? 'proxy' : 'direct';
    }
    userRules.add(action);
  }

  final cnRules = <Map<String, dynamic>>[];
  if (opts.rulesDir.isNotEmpty) {
    ruleSets.add({
      'type': 'local',
      'tag': 'geosite-cn',
      'format': 'binary',
      'path': p.join(opts.rulesDir, 'geosite-cn.srs'),
    });
    ruleSets.add({
      'type': 'local',
      'tag': 'geoip-cn',
      'format': 'binary',
      'path': p.join(opts.rulesDir, 'geoip-cn.srs'),
    });
    cnRules.add({'rule_set': ['geosite-cn'], 'outbound': 'direct'});
    cnRules.add({'rule_set': ['geoip-cn'], 'outbound': 'direct'});
  }

  final priority = existing
      .where((item) => item['action'] == 'sniff' || item['action'] == 'hijack-dns')
      .toList();
  if (opts.dnsCnDirect) {
    // sing-box 1.12+ 不再自动解析域名；没有 resolve，geoip-cn 对域名目标不生效。
    priority.add({'action': 'resolve', 'strategy': 'prefer_ipv4'});
  }
  final rest = existing
      .where((item) => item['action'] != 'sniff' && item['action'] != 'hijack-dns')
      .toList();
  // Google 的下载重定向域名（redirector.gvt1.com 等）会被 geosite-cn 误判为
  // 国内域名，导致 Play 下载走直连超时；这里强制走代理覆盖内置规则。
  final googleRules = <Map<String, dynamic>>[];
  final outboundTags = _asList(root['outbounds'])
      .whereType<Map>()
      .map((item) => item['tag'])
      .whereType<String>()
      .toSet();
  if (outboundTags.contains('proxy')) {
    googleRules.add(<String, dynamic>{
      'domain_suffix': [
        'gvt1.com',
        'googlevideo.com',
        'googleapis.com',
        'google.com',
        'gstatic.com',
      ],
      'outbound': 'proxy',
    });
    // Play 下载会直接连 Google 的 IP，sniff 拿不到域名，必须按 IP 段兜底。
    googleRules.add(<String, dynamic>{
      'ip_cidr': [
        '142.250.0.0/15',
        '172.217.0.0/16',
        '216.58.192.0/19',
        '74.125.0.0/16',
        '108.177.0.0/17',
        '209.85.128.0/17',
        '64.233.160.0/19',
        '216.239.32.0/19',
      ],
      'outbound': 'proxy',
    });
  }

  route['rules'] = [
    ...priority,
    ...userRules,
    ...googleRules,
    ...cnRules,
    ...rest,
  ];
  if (ruleSets.isNotEmpty) route['rule_set'] = ruleSets;
  root['route'] = route;
}


/// 自定义 DNS 需要一个“非空”的 direct 出站，否则 sing-box 会拒绝
/// `detour` 到空 direct（detour to an empty direct outbound makes no sense）。
void _ensureDnsDirectOutbound(Map<String, dynamic> root) {
  final outbounds = _asList(root['outbounds'])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
  if (outbounds.any((item) => item['tag'] == 'horsebox-dns-direct')) {
    root['outbounds'] = outbounds;
    return;
  }
  outbounds.add(<String, dynamic>{
    'type': 'direct',
    'tag': 'horsebox-dns-direct',
    'tcp_fast_open': true,
  });
  root['outbounds'] = outbounds;
}
