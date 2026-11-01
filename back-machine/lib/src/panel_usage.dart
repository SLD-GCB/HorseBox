import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'pinned_http.dart' as pinned;

/// 面板侧的用量快照：已用 / 配额 / 到期，全部以面板返回为准。
class PanelUsage {
  const PanelUsage({
    required this.usedBytes,
    required this.quotaBytes,
    required this.expireAt,
    required this.fetchedAt,
    this.nodes = 0,
    this.account = '',
  });

  /// 已用流量（上下行之和）。
  final int usedBytes;

  /// 配额；0 表示不限。
  final int quotaBytes;

  /// 到期时间；null 表示不限期。
  final DateTime? expireAt;

  /// 这次数据是什么时候从面板取回来的。
  final DateTime fetchedAt;

  /// 该用户名下的节点数量。
  final int nodes;

  /// 面板里的用户名。
  final String account;

  bool get unlimited => quotaBytes <= 0;

  bool get expired => expireAt != null && expireAt!.isBefore(DateTime.now());

  /// 距离到期还有几天；不限期返回 null，已过期返回 0。
  int? get daysLeft {
    final expire = expireAt;
    if (expire == null) return null;
    final diff = expire.difference(DateTime.now());
    if (diff.isNegative) return 0;
    return diff.inDays;
  }

  Map<String, dynamic> toJson() => {
    'used_bytes': usedBytes,
    'quota_bytes': quotaBytes,
    'expire_at': expireAt?.toUtc().toIso8601String(),
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    'nodes': nodes,
    'account': account,
  };

  factory PanelUsage.fromJson(Map<String, dynamic> json) {
    return PanelUsage(
      usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
      quotaBytes: (json['quota_bytes'] as num?)?.toInt() ?? 0,
      expireAt: _parseTime(json['expire_at']),
      fetchedAt: _parseTime(json['fetched_at']) ?? DateTime.now(),
      nodes: (json['nodes'] as num?)?.toInt() ?? 0,
      account: json['account'] as String? ?? '',
    );
  }

  static DateTime? _parseTime(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }
}

class PanelUsageException implements Exception {
  PanelUsageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 用面板管理员账号读 /api/clients，取当前订阅令牌对应的那一条（或几条）。
class PanelUsageClient {
  /// 从订阅地址里取令牌：`https://面板/sub/<令牌>?target=singbox`。
  static String subTokenOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return '';
    final segments = uri.pathSegments.where((item) => item.isNotEmpty).toList();
    if (segments.isEmpty) return '';
    final index = segments.lastIndexOf('sub');
    if (index >= 0 && index + 1 < segments.length) return segments[index + 1];
    return '';
  }

  /// 面板基地址（`https://host[:port]`）；地址不合法时返回 null。
  static String? baseOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return null;
    if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  static Future<PanelUsage> fetch({
    required String base,
    required String username,
    required String password,
    required String subToken,
    String certPin = '',
    String totpSecret = '',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final uri = Uri.tryParse(root);
    if (uri == null || uri.host.isEmpty) {
      throw PanelUsageException('面板地址不正确');
    }
    final pin = pinned.normalizePin(certPin);
    final bool usePin = pin.length == 64 && uri.isScheme('https');
    final HttpClient client = usePin
        ? pinned.createPinnedHttpClient(pin, connectionTimeout: timeout)
        : (HttpClient()
            ..connectionTimeout = timeout
            // 没填指纹时和面板的「临时连接」同一策略：仍然走 TLS，
            // 但不校验证书链，否则自签面板第一次进来就查不到用量。
            ..badCertificateCallback = (_, host, port) =>
                host == uri.host && port == (uri.hasPort ? uri.port : 443));
    client.userAgent = 'HorseBox';

    try {
      final token = await _login(client, root, username, password, totpSecret, timeout);
      final rows = await _clients(client, root, token, timeout);
      return _aggregate(rows, subToken);
    } on PanelUsageException {
      rethrow;
    } on TlsException {
      throw PanelUsageException(usePin ? '面板证书与指纹不一致，无法查询用量' : '面板证书校验失败');
    } on TimeoutException {
      throw PanelUsageException('连接面板超时');
    } on SocketException catch (e) {
      throw PanelUsageException('无法连接面板：${e.message}');
    } on FormatException {
      throw PanelUsageException('面板返回的内容不是合法 JSON');
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _login(
    HttpClient client,
    String root,
    String username,
    String password,
    String totpSecret,
    Duration timeout,
  ) async {
    final body = await _postJson(
      client,
      Uri.parse('$root/api/auth/login'),
      {'username': username, 'password': password},
      timeout,
    );
    final data = body['data'];
    if (data is Map && data['two_factor_required'] == true) {
      final challenge = data['challenge'];
      if (challenge is! String || challenge.isEmpty) {
        throw PanelUsageException('面板返回的两步验证信息不完整');
      }
      if (totpSecret.trim().isEmpty) {
        throw PanelUsageException('面板已启用两步验证，请在设置里填写 TOTP 密钥');
      }
      final second = await _postJson(
        client,
        Uri.parse('$root/api/auth/login/2fa'),
        {'challenge': challenge, 'code': totpCode(totpSecret)},
        timeout,
      );
      return _tokenOf(second);
    }
    return _tokenOf(body);
  }

  static Future<Map<String, dynamic>> _postJson(
    HttpClient client,
    Uri uri,
    Map<String, dynamic> payload,
    Duration timeout,
  ) async {
    final request = await client.postUrl(uri).timeout(timeout);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);

    if (response.statusCode == HttpStatus.unauthorized ||
        response.statusCode == HttpStatus.forbidden) {
      throw PanelUsageException('面板账号、密码或动态码不正确');
    }
    if (response.statusCode != HttpStatus.ok) {
      throw PanelUsageException('面板登录失败（HTTP ${response.statusCode}）');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw PanelUsageException('面板登录返回格式不正确');
    return Map<String, dynamic>.from(decoded);
  }

  static String _tokenOf(Map<String, dynamic> body) {
    final data = body['data'];
    final token = data is Map ? data['token'] : body['token'];
    if (token is! String || token.isEmpty) {
      final message = body['msg'];
      throw PanelUsageException(
        message is String && message.isNotEmpty ? message : '面板没有返回登录令牌',
      );
    }
    return token;
  }

  /// 生成 6 位 TOTP 动态码（SHA-1 / 30 秒 / 6 位）。
  static String totpCode(String secret, {DateTime? now}) {
    final key = _base32Decode(secret);
    final seconds = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    final counter = seconds ~/ 30;
    final message = ByteData(8)..setUint64(0, counter, Endian.big);
    final digest = crypto.Hmac(crypto.sha1, key)
        .convert(message.buffer.asUint8List())
        .bytes;
    final offset = digest[19] & 0x0f;
    final binary = ((digest[offset] & 0x7f) << 24) |
        (digest[offset + 1] << 16) |
        (digest[offset + 2] << 8) |
        digest[offset + 3];
    return (binary % 1000000).toString().padLeft(6, '0');
  }

  static Uint8List _base32Decode(String secret) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final input = secret.toUpperCase().replaceAll(RegExp(r'\s+'), '').replaceAll('=', '');
    var buffer = 0;
    var bits = 0;
    final out = <int>[];
    for (final char in input.split('')) {
      final value = alphabet.indexOf(char);
      if (value < 0) continue;
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
      }
    }
    return Uint8List.fromList(out);
  }

  static Future<List<Map<String, dynamic>>> _clients(
    HttpClient client,
    String root,
    String token,
    Duration timeout,
  ) async {
    final request = await client
        .getUrl(Uri.parse('$root/api/clients'))
        .timeout(timeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw PanelUsageException('读取用量失败（HTTP ${response.statusCode}）');
    }
    final decoded = jsonDecode(body);
    final data = decoded is Map ? decoded['data'] : decoded;
    if (data is! List) throw PanelUsageException('面板返回的客户列表格式不正确');
    return data
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  /// 按订阅令牌筛选，然后把同一用户的多个节点合并成一个总量。
  static PanelUsage _aggregate(
    List<Map<String, dynamic>> rows,
    String subToken,
  ) {
    if (subToken.isEmpty) {
      throw PanelUsageException('订阅地址里没有令牌，无法按用户查询用量');
    }
    final target = subToken.toLowerCase();
    final matched = rows
        .where(
          (row) => (row['sub_token'] as String? ?? '').toLowerCase() == target,
        )
        .toList();
    if (matched.isEmpty) {
      throw PanelUsageException('面板里没有找到这个订阅对应的用户');
    }

    var used = 0;
    var quota = 0;
    var nodes = 0;
    DateTime? expire;
    for (final row in matched) {
      used += (row['used_up'] as num?)?.toInt() ?? 0;
      used += (row['used_down'] as num?)?.toInt() ?? 0;
      final rowQuota = (row['quota_bytes'] as num?)?.toInt() ?? 0;
      if (rowQuota > 0 && (quota == 0 || rowQuota < quota)) quota = rowQuota;
      final rawExpire = row['expire_at'];
      if (rawExpire is String && rawExpire.isNotEmpty) {
        final parsed = DateTime.tryParse(rawExpire)?.toLocal();
        if (parsed != null && (expire == null || parsed.isBefore(expire))) {
          expire = parsed;
        }
      }
      final inboundIds = row['inbound_ids'];
      nodes += inboundIds is List && inboundIds.isNotEmpty
          ? inboundIds.length
          : 1;
    }

    return PanelUsage(
      usedBytes: used,
      quotaBytes: quota,
      expireAt: expire,
      fetchedAt: DateTime.now(),
      nodes: nodes,
      account: matched.first['name'] as String? ?? '',
    );
  }
}
