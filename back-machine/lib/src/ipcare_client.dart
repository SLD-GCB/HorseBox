import 'dart:convert';
import 'dart:io';

import 'pinned_http.dart' as pinned;

/// IP 养护设置�?class IpCareSettings {
  const IpCareSettings({
    required this.targetRegion,
    required this.detectMode,
    required this.detectIntervalSeconds,
    required this.warmMode,
    required this.notifyCN,
    required this.notifyFail,
  });

  final String targetRegion;
  final String detectMode;
  final int detectIntervalSeconds;
  final String warmMode;
  final bool notifyCN;
  final bool notifyFail;

  factory IpCareSettings.fromJson(Map<String, dynamic> json) => IpCareSettings(
        targetRegion: json['target_region'] as String? ?? 'US',
        detectMode: json['detect_mode'] as String? ?? 'manual',
        detectIntervalSeconds:
            (json['detect_interval_seconds'] as num?)?.toInt() ?? 86400,
        warmMode: json['warm_mode'] as String? ?? 'manual',
        notifyCN: json['notify_cn'] as bool? ?? true,
        notifyFail: json['notify_fail'] as bool? ?? true,
      );
}

/// 一次检测结果�?class IpCareCheck {
  const IpCareCheck({
    required this.id,
    required this.ip,
    required this.googleRegion,
    required this.targetRegion,
    required this.isCN,
    required this.trustScore,
    required this.latencyMs,
    required this.error,
    required this.createdAt,
  });

  final int id;
  final String ip;
  final String googleRegion;
  final String targetRegion;
  final bool isCN;
  final int trustScore;
  final int latencyMs;
  final String error;
  final int createdAt;

  factory IpCareCheck.fromJson(Map<String, dynamic> json) => IpCareCheck(
        id: (json['id'] as num?)?.toInt() ?? 0,
        ip: json['ip'] as String? ?? '',
        googleRegion: json['google_region'] as String? ?? '',
        targetRegion: json['target_region'] as String? ?? '',
        isCN: json['is_cn'] as bool? ?? false,
        trustScore: (json['trust_score'] as num?)?.toInt() ?? -1,
        latencyMs: (json['latency_ms'] as num?)?.toInt() ?? 0,
        error: json['error'] as String? ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      );
}

/// 一次纠偏任务�?class IpCareJob {
  const IpCareJob({
    required this.id,
    required this.status,
    required this.requests,
    required this.error,
    required this.createdAt,
    required this.finishedAt,
  });

  final int id;
  final String status;
  final int requests;
  final String error;
  final int createdAt;
  final int finishedAt;

  factory IpCareJob.fromJson(Map<String, dynamic> json) => IpCareJob(
        id: (json['id'] as num?)?.toInt() ?? 0,
        status: json['status'] as String? ?? '',
        requests: (json['requests'] as num?)?.toInt() ?? 0,
        error: json['error'] as String? ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        finishedAt: (json['finished_at'] as num?)?.toInt() ?? 0,
      );
}

/// IP 养护聚合状态�?class IpCareStatus {
  const IpCareStatus({
    required this.ip,
    required this.googleRegion,
    required this.targetRegion,
    required this.isCN,
    required this.trustScore,
    required this.lastCheck,
    required this.lastWarm,
    required this.busy,
    required this.lastError,
    required this.settings,
    this.last,
  });

  final String ip;
  final String googleRegion;
  final String targetRegion;
  final bool isCN;
  final int trustScore;
  final int lastCheck;
  final int lastWarm;
  final bool busy;
  final String lastError;
  final IpCareSettings settings;
  final IpCareCheck? last;

  factory IpCareStatus.fromJson(Map<String, dynamic> json) {
    final rawSettings = json['settings'];
    final rawLast = json['last'];
    return IpCareStatus(
      ip: json['ip'] as String? ?? '',
      googleRegion: json['google_region'] as String? ?? '',
      targetRegion: json['target_region'] as String? ?? '',
      isCN: json['is_cn'] as bool? ?? false,
      trustScore: (json['trust_score'] as num?)?.toInt() ?? -1,
      lastCheck: (json['last_check'] as num?)?.toInt() ?? 0,
      lastWarm: (json['last_warm'] as num?)?.toInt() ?? 0,
      busy: json['busy'] as bool? ?? false,
      lastError: json['last_error'] as String? ?? '',
      settings: rawSettings is Map
          ? IpCareSettings.fromJson(Map<String, dynamic>.from(rawSettings))
          : const IpCareSettings(
              targetRegion: 'US',
              detectMode: 'manual',
              detectIntervalSeconds: 86400,
              warmMode: 'manual',
              notifyCN: true,
              notifyFail: true,
            ),
      last: rawLast is Map
          ? IpCareCheck.fromJson(Map<String, dynamic>.from(rawLast))
          : null,
    );
  }
}

/// 面板 IP 养护 API 客户端，使用证书指纹 + 专用令牌�?class IpCareClient {
  IpCareClient({
    required String subscriptionUrl,
    required this.pin,
    required this.token,
  }) : base = _panelBase(subscriptionUrl);

  final String base;
  final String pin;
  final String token;

  static String _panelBase(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) {
      throw ArgumentError('订阅地址不是有效�?HTTPS 地址');
    }
    return Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    if (pin.length != 64) {
      throw StateError('缺少面板证书指纹');
    }
    if (token.isEmpty) {
      throw StateError('缺少 IP 养护令牌');
    }
    final client = pinned.createPinnedHttpClient(pin, connectionTimeout: timeout);
    try {
      final uri = Uri.parse('$base$path');
      final req = await client.openUrl(method, uri).timeout(timeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join().timeout(timeout);
      Map<String, dynamic> map;
      try {
        map = Map<String, dynamic>.from(jsonDecode(text) as Map);
      } catch (_) {
        throw StateError('面板返回格式错误（HTTP ${resp.statusCode}�?);
      }
      if (map['code'] != 0) {
        throw StateError(map['msg']?.toString() ?? '面板请求失败');
      }
      final data = map['data'];
      if (data is Map) return Map<String, dynamic>.from(data);
      return {'data': data};
    } finally {
      client.close(force: true);
    }
  }

  Future<IpCareStatus> status() async =>
      IpCareStatus.fromJson(await _request('GET', '/api/ip-care/status'));

  Future<IpCareCheck> check() async =>
      IpCareCheck.fromJson(await _request('POST', '/api/ip-care/check'));

  Future<IpCareJob> warm() async =>
      IpCareJob.fromJson(await _request('POST', '/api/ip-care/warm',
          timeout: const Duration(seconds: 95)));

  Future<FirewallStatus> firewallStatus() async => FirewallStatus.fromJson(
      await _request('GET', '/api/ip-care/firewall/status'));

  Future<FirewallGuardState> firewallGuard() async =>
      FirewallGuardState.fromJson(
          await _request('GET', '/api/ip-care/firewall/guard'));

  Future<List<String>> firewallLogs() async {
    final data = await _request('GET', '/api/ip-care/firewall/logs?lines=200');
    final lines = data['lines'];
    if (lines is! List) return const [];
    return lines.map((e) => e.toString()).toList();
  }

  Future<List<FirewallAttackSource>> firewallAttackSources() async {
    final data =
        await _request('GET', '/api/ip-care/firewall/attack-sources?limit=100');
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => FirewallAttackSource.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<FirewallAttackLog>> firewallAttackLogs() async {
    final data =
        await _request('GET', '/api/ip-care/firewall/attack-logs?limit=100');
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => FirewallAttackLog.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<ServerMetrics> systemMetrics() async =>
      ServerMetrics.fromJson(await _request('GET', '/api/ip-care/system/metrics'));

  Future<List<IpCareCheck>> history() async {
    final data = await _request('GET', '/api/ip-care/history?limit=50');
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => IpCareCheck.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<IpCareJob>> warmHistory() async {
    final data = await _request('GET', '/api/ip-care/warm/history?limit=50');
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => IpCareJob.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<IpCareSettings> saveSettings({
    required String targetRegion,
    required String detectMode,
    required String warmMode,
  }) async {
    final data = await _request('PUT', '/api/ip-care/settings', body: {
      'target_region': targetRegion,
      'detect_mode': detectMode,
      'warm_mode': warmMode,
      'notify_cn': true,
      'notify_fail': true,
    });
    return IpCareSettings.fromJson(data);
  }
}

class FirewallPortState {
  const FirewallPortState({
    required this.port,
    required this.protocol,
    required this.action,
    required this.protect,
    required this.auto,
    required this.comment,
  });

  final int port;
  final String protocol;
  final String action;
  final bool protect;
  final bool auto;
  final String comment;

  factory FirewallPortState.fromJson(Map<String, dynamic> json) =>
      FirewallPortState(
        port: (json['port'] as num?)?.toInt() ?? 0,
        protocol: json['protocol'] as String? ?? 'tcp',
        action: json['action'] as String? ?? 'allow',
        protect: json['protect'] as bool? ?? false,
        auto: json['auto'] as bool? ?? false,
        comment: json['comment'] as String? ?? '',
      );
}

class FirewallBanState {
  const FirewallBanState({
    required this.ip,
    required this.reason,
    required this.source,
    required this.permanent,
    required this.createdAt,
  });

  final String ip;
  final String reason;
  final String source;
  final bool permanent;
  final int createdAt;

  factory FirewallBanState.fromJson(Map<String, dynamic> json) =>
      FirewallBanState(
        ip: json['ip'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
        source: json['source'] as String? ?? '',
        permanent: json['permanent'] as bool? ?? false,
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      );
}

class FirewallAttackSource {
  const FirewallAttackSource({
    required this.ip,
    required this.port,
    required this.protocol,
    required this.count,
    required this.firstSeen,
    required this.lastSeen,
    required this.banned,
  });

  final String ip;
  final int port;
  final String protocol;
  final int count;
  final int firstSeen;
  final int lastSeen;
  final bool banned;

  factory FirewallAttackSource.fromJson(Map<String, dynamic> json) =>
      FirewallAttackSource(
        ip: json['ip'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 0,
        protocol: json['protocol'] as String? ?? 'tcp',
        count: (json['count'] as num?)?.toInt() ?? 0,
        firstSeen: (json['first_seen'] as num?)?.toInt() ?? 0,
        lastSeen: (json['last_seen'] as num?)?.toInt() ?? 0,
        banned: json['banned'] as bool? ?? false,
      );
}

class FirewallAttackLog {
  const FirewallAttackLog({
    required this.port,
    required this.protocol,
    required this.current,
    required this.limit,
    required this.baseline,
    required this.action,
    required this.sources,
    required this.createdAt,
  });

  final int port;
  final String protocol;
  final int current;
  final double limit;
  final double baseline;
  final String action;
  final String sources;
  final int createdAt;

  factory FirewallAttackLog.fromJson(Map<String, dynamic> json) =>
      FirewallAttackLog(
        port: (json['port'] as num?)?.toInt() ?? 0,
        protocol: json['protocol'] as String? ?? 'tcp',
        current: (json['current'] as num?)?.toInt() ?? 0,
        limit: (json['limit'] as num?)?.toDouble() ?? 0,
        baseline: (json['baseline'] as num?)?.toDouble() ?? 0,
        action: json['action'] as String? ?? 'watch',
        sources: json['sources'] as String? ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      );
}

class FirewallStatus {
  const FirewallStatus({
    required this.supported,
    required this.applied,
    required this.enabled,
    required this.autoProtect,
    required this.error,
    required this.ports,
    required this.bans,
  });

  final bool supported;
  final bool applied;
  final bool enabled;
  final bool autoProtect;
  final String error;
  final List<FirewallPortState> ports;
  final List<FirewallBanState> bans;

  factory FirewallStatus.fromJson(Map<String, dynamic> json) => FirewallStatus(
        supported: json['supported'] as bool? ?? false,
        applied: json['applied'] as bool? ?? false,
        enabled: json['enabled'] as bool? ?? false,
        autoProtect: json['auto_protect'] as bool? ?? false,
        error: json['error'] as String? ?? '',
        ports: (json['ports'] as List?)
                ?.whereType<Map>()
                .map((e) => FirewallPortState.fromJson(
                    Map<String, dynamic>.from(e)))
                .toList() ??
            const [],
        bans: (json['bans'] as List?)
                ?.whereType<Map>()
                .map((e) =>
                    FirewallBanState.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            const [],
      );
}

class FirewallPortGuard {
  const FirewallPortGuard({
    required this.protocol,
    required this.port,
    required this.current,
    required this.baseline,
    required this.limit,
    required this.floor,
    required this.ceiling,
    required this.status,
  });

  final String protocol;
  final int port;
  final int current;
  final double baseline;
  final double limit;
  final double floor;
  final double ceiling;
  final String status;

  factory FirewallPortGuard.fromJson(Map<String, dynamic> json) =>
      FirewallPortGuard(
        protocol: json['protocol'] as String? ?? 'tcp',
        port: (json['port'] as num?)?.toInt() ?? 0,
        current: (json['current'] as num?)?.toInt() ?? 0,
        baseline: (json['baseline'] as num?)?.toDouble() ?? 0,
        limit: (json['limit'] as num?)?.toDouble() ?? 0,
        floor: (json['floor'] as num?)?.toDouble() ?? 0,
        ceiling: (json['ceiling'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String? ?? 'normal',
      );
}

class FirewallGuardState {
  const FirewallGuardState({
    required this.updatedAt,
    required this.healthy,
    required this.running,
    required this.stale,
    required this.ports,
  });

  final int updatedAt;
  final bool healthy;
  final bool running;
  final bool stale;
  final List<FirewallPortGuard> ports;

  factory FirewallGuardState.fromJson(Map<String, dynamic> json) =>
      FirewallGuardState(
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
        healthy: json['healthy'] as bool? ?? false,
        running: json['running'] as bool? ?? false,
        stale: json['stale'] as bool? ?? true,
        ports: (json['ports'] as List?)
                ?.whereType<Map>()
                .map((e) =>
                    FirewallPortGuard.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            const [],
      );
}

class ServerMetrics {
  const ServerMetrics({
    required this.cpuPercent,
    required this.cpus,
    required this.memTotal,
    required this.memUsed,
    required this.memPercent,
    required this.diskTotal,
    required this.diskUsed,
    required this.diskPercent,
    required this.uptime,
  });

  final double cpuPercent;
  final int cpus;
  final int memTotal;
  final int memUsed;
  final double memPercent;
  final int diskTotal;
  final int diskUsed;
  final double diskPercent;
  final int uptime;

  factory ServerMetrics.fromJson(Map<String, dynamic> json) => ServerMetrics(
        cpuPercent: (json['cpu_percent'] as num?)?.toDouble() ?? 0,
        cpus: (json['cpus'] as num?)?.toInt() ?? 0,
        memTotal: (json['mem_total'] as num?)?.toInt() ?? 0,
        memUsed: (json['mem_used'] as num?)?.toInt() ?? 0,
        memPercent: (json['mem_percent'] as num?)?.toDouble() ?? 0,
        diskTotal: (json['disk_total'] as num?)?.toInt() ?? 0,
        diskUsed: (json['disk_used'] as num?)?.toInt() ?? 0,
        diskPercent: (json['disk_percent'] as num?)?.toDouble() ?? 0,
        uptime: (json['uptime'] as num?)?.toInt() ?? 0,
      );
}
