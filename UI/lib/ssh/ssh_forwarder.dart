import 'dart:io';

import 'package:horsebox_backend/horsebox_backend.dart';

import 'ssh_connection.dart';

/// 本地端口转发：在 127.0.0.1:localPort 上监听，每条进来的连接各开一条
/// SSH 通道打到远端 host:port。
class SshForwarder {
  SshForwarder(this._conn);

  final SshConnection _conn;
  final Map<String, ServerSocket> _servers = {};
  final Map<String, int> _connections = {};

  bool isRunning(String id) => _servers.containsKey(id);

  int connectionCount(String id) => _connections[id] ?? 0;

  Future<void> start(SshForward rule, {void Function()? onChange}) async {
    if (_servers.containsKey(rule.id)) return;
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      rule.localPort,
    );
    _servers[rule.id] = server;
    _connections[rule.id] = 0;
    server.listen((socket) {
      _handle(socket, rule, onChange);
    });
    onChange?.call();
  }

  void _handle(Socket socket, SshForward rule, void Function()? onChange) {
    _connections[rule.id] = (_connections[rule.id] ?? 0) + 1;
    onChange?.call();
    var closed = false;
    void finish() {
      if (closed) return;
      closed = true;
      _connections[rule.id] = (_connections[rule.id] ?? 1) - 1;
      if (_connections[rule.id]! < 0) _connections[rule.id] = 0;
      onChange?.call();
    }

    _conn
        .forwardLocal(rule.host, rule.port)
        .then((channel) {
          socket.listen(
            (data) => channel.sink.add(data),
            onDone: () {
              channel.close();
              socket.destroy();
              finish();
            },
            onError: (Object _) {
              channel.close();
              socket.destroy();
              finish();
            },
          );
          channel.stream.listen(
            socket.add,
            onDone: () {
              socket.destroy();
              finish();
            },
            onError: (Object _) {
              socket.destroy();
              finish();
            },
          );
        })
        .catchError((Object _) {
          socket.destroy();
          finish();
        });
  }

  Future<void> stop(String id) async {
    final server = _servers.remove(id);
    _connections.remove(id);
    if (server != null) {
      try {
        await server.close();
      } catch (_) {}
    }
  }

  Future<void> stopAll() async {
    final servers = _servers.values.toList();
    _servers.clear();
    _connections.clear();
    for (final server in servers) {
      try {
        await server.close();
      } catch (_) {}
    }
  }
}
