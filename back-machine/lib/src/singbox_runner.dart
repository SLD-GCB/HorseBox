import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Windows 端 sing-box 子进程管理。
///
/// Android 走 VpnService + libbox，不使用这个类。
class SingBoxRunner {
  SingBoxRunner({
    required this.binaryPath,
    required this.workDir,
    this.encrypt,
  });

  final String binaryPath;
  final String workDir;

  /// 落盘配置的加密（Windows 传 DPAPI）。为 null 时保持明文，仅供调试。
  final List<int>? Function(List<int>)? encrypt;

  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<int> _exits = StreamController<int>.broadcast();
  Process? _process;
  File? _runtimeFile;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  Stream<String> get logs => _logs.stream;
  Stream<int> get exits => _exits.stream;
  bool get running => _process != null;

  Future<void> start(String configJson, {required int clashPort}) async {
    final dir = Directory(workDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    // 落盘的 config.json 里是节点地址和密码，不留明文：加密保存一份，内核吃的临时文件跑完就删
    final configFile = File(p.join(workDir, 'config.json'));
    final seal = encrypt;
    if (seal != null) {
      final sealed = seal(utf8.encode(configJson));
      if (sealed != null) {
        await configFile.writeAsBytes(sealed, flush: true);
      }
    } else {
      await configFile.writeAsString(configJson, flush: true);
    }

    await _sweepRuntimeConfigs();

    await killStale(clashPort: clashPort, workDir: workDir);

    final runtime = File(p.join(workDir, 'config-${DateTime.now().microsecondsSinceEpoch}.json'));
    await runtime.writeAsString(configJson, flush: true);
    _runtimeFile = runtime;

    final process = await Process.start(
      binaryPath,
      ['run', '-c', runtime.path],
      workingDirectory: workDir,
      runInShell: false,
    );

    // 内核是异步启动的：必须等它真把配置读进去（Clash 端口能应答）再删，
    // 删早了内核会报 "cannot find the file specified" 直接起不来
    unawaited(_wipeAfterReady(runtime, clashPort));
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
        final rt = _runtimeFile;
        _runtimeFile = null;
        if (rt != null) await _wipe(rt);
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
    final rt = _runtimeFile;
    _runtimeFile = null;
    if (rt != null) await _wipe(rt);
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

  /// 等内核真的起来了再删临时明文配置；没起来就留着，下次启动前统一清理。
  Future<void> _wipeAfterReady(File file, int clashPort) async {
    for (var i = 0; i < 90; i++) {
      if (await isAlive(clashPort)) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!await isAlive(clashPort)) {
      _emit('内核未就绪，临时配置保留到下次启动');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    await _wipe(file);
  }

  /// 内核起来后删掉临时明文配置；被占用就重试几秒。
  Future<void> _wipe(File file) async {
    for (var i = 0; i < 25; i++) {
      try {
        if (await file.exists()) await file.delete();
        if (!await file.exists()) return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _emit('临时配置未能删除，下次启动会清理');
  }

  /// 清掉上次崩溃留下的明文临时配置。
  Future<void> _sweepRuntimeConfigs() async {
    try {
      final dir = Directory(workDir);
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is! File) continue;
        if (!name.startsWith('config-') || !name.endsWith('.json')) continue;
        // 一分钟内的不删：可能是刚启动、内核还没读完的那个
        final stamp = int.tryParse(
          name.substring(7, name.length - 5),
        );
        if (stamp != null) {
          final age = DateTime.now().microsecondsSinceEpoch - stamp;
          if (age < const Duration(seconds: 60).inMicroseconds) continue;
        }
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

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
