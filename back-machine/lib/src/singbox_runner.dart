import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Windows 端 sing-box 子进程管理。
///
/// Android 走 VpnService + libbox，不使用这个类。
class SingBoxRunner {
  SingBoxRunner({required this.binaryPath, required this.workDir});

  final String binaryPath;
  final String workDir;

  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<int> _exits = StreamController<int>.broadcast();
  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  Stream<String> get logs => _logs.stream;
  Stream<int> get exits => _exits.stream;
  bool get running => _process != null;

  Future<void> start(String configJson, {required int clashPort}) async {
    final dir = Directory(workDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final configFile = File(p.join(workDir, 'config.json'));
    await configFile.writeAsString(configJson, flush: true);

    await killStale(clashPort: clashPort, workDir: workDir);

    final process = await Process.start(
      binaryPath,
      ['run', '-c', configFile.path],
      workingDirectory: workDir,
      runInShell: false,
    );
    _process = process;
    _emit('内核已启动，PID ${process.pid}');

    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_emit);
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_emit);

    unawaited(
      process.exitCode.then((code) async {
        _emit('内核退出 code=$code');
        if (identical(_process, process)) {
          _process = null;
        }
        if (!_exits.isClosed) _exits.add(code);
        await _cleanupSubscriptions();
        await _removePidFile();
      }),
    );

    await _writePidFile(process.pid, clashPort);
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process != null) {
      // Windows 上 Process.kill 是 TerminateProcess，立即生效；
      // 不再等 exitCode，避免 UI 卡 3 秒。
      process.kill();
      _emit('内核已停止');
      unawaited(process.exitCode.then((_) {}).catchError((Object _) {}));
    }
    await _cleanupSubscriptions();
    await _removePidFile();
  }

  /// 清理上一轮残留的内核，只杀真正占着 Clash 端口的那个进程。
  static Future<void> killStale({
    required int clashPort,
    required String workDir,
  }) async {
    await _killFromPidFile(clashPort, workDir);
    // 没有 pid 记录时，再按端口探测一次；能返回 sing-box 版本才认定是内核。
    if (await _probeClash(clashPort)) {
      await _killByPort(clashPort);
    }
  }

  static Future<void> _killFromPidFile(int clashPort, String workDir) async {
    final file = File(p.join(workDir, 'horsebox-core.pid'));
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      final port = (data['port'] as num?)?.toInt();
      final pid = (data['pid'] as num?)?.toInt();
      if (pid != null &&
          port != null &&
          port == clashPort &&
          await _probeClash(port)) {
        await _killPid(pid);
      }
    } catch (_) {
      // 记录损坏时忽略
    }
    try {
      await file.delete();
    } catch (_) {}
  }

  static Future<void> _killByPort(int clashPort) async {
    if (!Platform.isWindows) return;
    // Windows 上按端口找 PID：只匹配 LISTENING 且本地地址是 127.0.0.1 的记录。
    try {
      final result = await Process.run('netstat', ['-ano', '-p', 'tcp']);
      final lines = (result.stdout as String).split('\n');
      for (final line in lines) {
        if (!line.contains('127.0.0.1:$clashPort') ||
            !line.contains('LISTENING')) {
          continue;
        }
        final parts = line.trim().split(RegExp(r'\s+'));
        final pid = int.tryParse(parts.last);
        if (pid != null) await _killPid(pid);
      }
    } catch (_) {}
  }

  static Future<void> _killPid(int pid) async {
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '$pid', '/F']);
      } else {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
    } catch (_) {}
  }

  static Future<bool> _probeClash(int port) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 600);
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/version'))
          .timeout(const Duration(milliseconds: 800));
      final response = await request.close().timeout(
        const Duration(milliseconds: 800),
      );
      final body = await response.transform(utf8.decoder).join();
      return response.statusCode == 200 && body.contains('sing-box');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 探测某个端口上是不是 sing-box（用于等待内核就绪）。
  static Future<bool> isAlive(int port) => _probeClash(port);

  Future<void> _writePidFile(int pid, int clashPort) async {
    final file = File(p.join(workDir, 'horsebox-core.pid'));
    await file.writeAsString(
      jsonEncode({'pid': pid, 'port': clashPort}),
      flush: true,
    );
  }

  Future<void> _removePidFile() async {
    try {
      final file = File(p.join(workDir, 'horsebox-core.pid'));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _cleanupSubscriptions() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
  }

  void _emit(String line) {
    if (line.trim().isEmpty) return;
    if (!_logs.isClosed) _logs.add(line);
  }
}
