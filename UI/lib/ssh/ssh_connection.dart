import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

/// 一条 SSH 连接：shell 通道 + 复用的 SFTP 通道。
///
/// 只做连接管理和字节搬运，界面状态由页面自己维护。
class SshConnection {
  SSHClient? _client;
  SSHSession? _shell;
  SftpClient? _sftp;

  bool get isConnected => _shell != null;

  Future<SSHSession> connect(
    SshHost host, {
    required Future<bool> Function(String type, Uint8List fingerprint)
    verifyHostKey,
  }) async {
    final socket = await SSHSocket.connect(
      host.host,
      host.port,
      timeout: const Duration(seconds: 15),
    );
    final client = SSHClient(
      socket,
      username: host.username,
      onPasswordRequest: () => host.password,
      onVerifyHostKey: verifyHostKey,
    );
    _client = client;
    final shell = await client.shell(
      pty: const SSHPtyConfig(type: 'xterm-256color', width: 100, height: 30),
    );
    _shell = shell;
    return shell;
  }

  void write(List<int> data) {
    _shell?.stdin.add(Uint8List.fromList(data));
  }

  void resize(int cols, int rows) {
    _shell?.resizeTerminal(cols, rows);
  }

  /// 建立一条本地到远端的转发通道（每次连接开一条）。
  Future<SSHForwardChannel> forwardLocal(String host, int port) {
    final client = _client;
    if (client == null) throw StateError('SSH 未连接');
    return client.forwardLocal(host, port);
  }

  Future<SftpClient> sftp() async {
    final cached = _sftp;
    if (cached != null) return cached;
    final client = _client;
    if (client == null) throw StateError('SSH 未连接');
    final opened = await client.sftp();
    _sftp = opened;
    return opened;
  }

  Future<void> close() async {
    final sftpClient = _sftp;
    _sftp = null;
    if (sftpClient != null) {
      try {
        await sftpClient.close();
      } catch (_) {}
    }
    try {
      _shell?.close();
    } catch (_) {}
    _shell = null;
    _client?.close();
    _client = null;
  }
}
