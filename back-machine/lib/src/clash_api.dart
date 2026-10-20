import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// 与内核的 Clash API 通信（只监听 127.0.0.1）。
class ClashApi {
  ClashApi({required this.port});

  final int port;

  Uri _uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(_uri(path)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: _uri(path));
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Clash API 返回格式错误');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  /// 内核版本，同时用作就绪探测。
  Future<String> version() async {
    final json = await _getJson(
      '/version',
      timeout: const Duration(seconds: 2),
    );
    return json['version'] as String? ?? 'sing-box';
  }

  /// 实时速率：WebSocket `/traffic`，每秒一条。
  Stream<TrafficSample> traffic() async* {
    final socket = await WebSocket.connect('ws://127.0.0.1:$port/traffic')
        .timeout(const Duration(seconds: 5));
    try {
      await for (final message in socket) {
        final decoded = jsonDecode(message as String);
        if (decoded is Map) {
          yield TrafficSample(
            up: (decoded['up'] as num?)?.toInt() ?? 0,
            down: (decoded['down'] as num?)?.toInt() ?? 0,
          );
        }
      }
    } finally {
      await socket.close();
    }
  }

  /// 内核日志流：WebSocket `/logs`。
  Stream<LogEntry> logs({String level = 'info'}) async* {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/logs?level=$level',
    ).timeout(const Duration(seconds: 5));
    try {
      await for (final message in socket) {
        final decoded = jsonDecode(message as String);
        if (decoded is Map<String, dynamic>) {
          yield LogEntry.fromClash(decoded);
        }
      }
    } finally {
      await socket.close();
    }
  }

  /// 当前活动连接。
  Future<List<ConnectionRow>> connections() async {
    final json = await _getJson('/connections');
    final list = json['connections'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((item) => ConnectionRow.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  /// 代理组/节点（用于展示当前节点名）。
  Future<List<Map<String, dynamic>>> proxies() async {
    final json = await _getJson('/proxies');
    final proxies = json['proxies'];
    if (proxies is! Map) return const [];
    return proxies.entries
        .where((entry) => entry.value is Map)
        .map(
          (entry) => <String, dynamic>{
            'name': entry.key,
            ...Map<String, dynamic>.from(entry.value as Map),
          },
        )
        .toList(growable: false);
  }

  /// 测试单个节点延迟（毫秒）。
  Future<int> delay(
    String name, {
    String url = 'http://www.gstatic.com/generate_204',
    int timeout = 5000,
  }) async {
    final path =
        '/proxies/${Uri.encodeComponent(name)}/delay'
        '?timeout=$timeout&url=${Uri.encodeComponent(url)}';
    final json = await _getJson(
      path,
      timeout: Duration(milliseconds: timeout + 1500),
    );
    final delay = (json['delay'] as num?)?.toInt();
    if (delay == null) throw const FormatException('测速没有返回延迟');
    return delay;
  }

  /// 手动切换某个 selector 的节点。
  Future<void> select(String group, String name) async {
    final client = HttpClient();
    try {
      final request = await client
          .putUrl(_uri('/proxies/${Uri.encodeComponent(group)}'))
          .timeout(const Duration(seconds: 5));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'name': name}));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw HttpException('切换节点失败：HTTP ${response.statusCode}');
      }
    } finally {
      client.close(force: true);
    }
  }
}
