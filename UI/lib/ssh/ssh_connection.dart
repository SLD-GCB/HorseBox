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

  Timer? _flushTimer;
  bool _flushing = false;

  void write(List<int> data) {
    final shell = _shell;
    if (shell == null) return;
    shell.stdin.add(Uint8List.fromList(data));
    // dartssh2 的 stdin 会先攒在通道里，等 flush 才真正发出去。
    // 但逐键 flush 会和通道的上传队列打架（连打几个键就可能把连接搞断），
    // 这里合并成 8ms 一次：既不会憋几秒，也不会每个字符都冲一次。
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 16), () async {
      final current = _shell;
      if (current == null || _flushing) return;
      _flushing = true;
      try {
        await current.flush();
      } catch (_) {
        // 连接已经断开时 flush 会抛，吞掉即可，不要影响输入流程。
      } finally {
        _flushing = false;
      }
    });
  }

  void resize(int cols, int rows) {
    // 键盘弹出时终端会被压得很扁，xterm 可能算出 0 行 0 列；
    // 给服务端发 0 尺寸会让部分 sshd 直接断开会话，这里兜个底。
    if (cols < 20 || rows < 5) return;
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
    _flushTimer?.cancel();
    _flushTimer = null;
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
