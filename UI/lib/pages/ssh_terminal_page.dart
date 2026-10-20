import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:horsebox_backend/horsebox_backend.dart';
import 'package:xterm/xterm.dart';

import '../ssh/ssh_connection.dart';
import '../ssh/ssh_forwarder.dart';
import '../state/app_state.dart';
import 'ssh_files_page.dart';
import 'ssh_forward_sheet.dart';

/// 一个主机的全屏终端：没有底部导航，退出靠左上角的返回。
class SshTerminalPage extends StatefulWidget {
  const SshTerminalPage({super.key, required this.state, required this.host});

  final AppState state;
  final SshHost host;

  @override
  State<SshTerminalPage> createState() => _SshTerminalPageState();
}

class _SshTerminalPageState extends State<SshTerminalPage> {
  final Terminal _terminal = Terminal(maxLines: 5000);
  final TerminalController _terminalController = TerminalController();
  final SshConnection _conn = SshConnection();
  late final SshForwarder _forwarder = SshForwarder(_conn);
  final FocusNode _focus = FocusNode();
  final GlobalKey<TerminalViewState> _viewKey = GlobalKey<TerminalViewState>();
  StreamSubscription<Uint8List>? _stdout;

  String _status = '连接中';
  String? _error;
  Timer? _longPress;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (data) => _conn.write(utf8.encode(data));
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) =>
        _conn.resize(width, height);
    _focus.addListener(_onFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _ensureInput();
      unawaited(_connect());
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _stdout?.cancel();
    _forwarder.stopAll();
    _conn.close();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focus.hasFocus) _ensureInput();
  }

  /// xterm 的字符输入走的是输入法连接，只 requestFocus 还不够：
  /// 必须再调一次 requestKeyboard() 建立 TextInput 连接，否则只能按功能键、打不出字。
  void _ensureInput() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_focus.hasFocus) _focus.requestFocus();
      _viewKey.currentState?.requestKeyboard();
    });
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _viewKey.currentState?.requestKeyboard();
    });
  }

  Future<void> _connect() async {
    setState(() {
      _status = '连接中';
      _error = null;
    });
    try {
      final shell = await _conn.connect(
        widget.host,
        verifyHostKey: _verifyHostKey,
      );
      _stdout = shell.stdout.listen((data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
      });
      shell.done.then((_) {
        if (!mounted) return;
        setState(() => _status = '已断开');
      });
      if (!mounted) return;
      setState(() => _status = '已连接');
      _focus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '连接失败';
        _error = _friendly(e);
      });
    }
  }

  /// 首次连接记下主机密钥；之后必须完全一致，否则拒绝。
  Future<bool> _verifyHostKey(String type, Uint8List fingerprint) async {
    final hex = fingerprint
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final known = widget.host.fingerprint;
    if (known.isEmpty) {
      await widget.state.saveSshFingerprint(widget.host.id, hex);
      return true;
    }
    if (known.toLowerCase() == hex.toLowerCase()) return true;
    if (mounted) {
      setState(() {
        _error =
            '主机密钥和上次不一致，连接已拒绝。\n'
            '上次：$known\n'
            '这次：$hex\n'
            '确认换过机器或重装过系统，就到「配置」里重置这台主机的指纹。';
      });
    }
    return false;
  }

  String _friendly(Object error) {
    var text = error.toString();
    if (text.startsWith('Exception: ')) text = text.substring(11);
    return text;
  }

  void _send(String data) {
    _conn.write(utf8.encode(data));
    _focus.requestFocus();
  }

  Future<void> _openForwards() async {
    if (!_conn.isConnected) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: SshForwardSheet(
          state: widget.state,
          host: widget.host,
          forwarder: _forwarder,
        ),
      ),
    );
  }

  Future<void> _openFiles() async {
    if (!_conn.isConnected) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            SshFilesPage(conn: _conn, title: widget.host.label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: SafeArea(
        child: Column(
          children: [
            _topBar(scheme),
            if (_error != null) _errorBar(scheme),
            Expanded(child: _terminalArea()),
            if (Platform.isAndroid) _keyBar(),
          ],
        ),
      ),
    );
  }

  /// 终端本体 + 右键 / 长按菜单。
  Widget _terminalArea() {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: (_) => _longPress?.cancel(),
      onPointerUp: (_) => _longPress?.cancel(),
      onPointerCancel: (_) => _longPress?.cancel(),
      child: TerminalView(
        _terminal,
        key: _viewKey,
        controller: _terminalController,
        focusNode: _focus,
        autofocus: true,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        textStyle: const TerminalStyle(fontSize: 12.5),
        theme: TerminalThemes.defaultTheme,
        keyboardType: TextInputType.text,
        // 桌面端直接读硬件按键的 character，不走输入法连接：
        // 输入法连接拿不到普通字符，数字字母会打不进去。
        // Android 保持输入法模式，用的就是系统当前输入法。
        hardwareKeyboardOnly: !Platform.isAndroid,
      ),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    // 桌面：右键直接出菜单。
    if (event.buttons == kSecondaryButton) {
      unawaited(_openMenu(event.position));
      return;
    }
    if (event.kind != PointerDeviceKind.touch) return;
    // 手机：长按选中手指下面那个词，再出菜单。
    final position = event.position;
    final local = event.localPosition;
    _longPress?.cancel();
    _longPress = Timer(const Duration(milliseconds: 450), () {
      unawaited(_openMenu(position, selectAt: local));
    });
  }

  Future<void> _openMenu(Offset global, {Offset? selectAt}) async {
    if (_menuOpen) return;
    _menuOpen = true;
    try {
      if (selectAt != null) {
        _viewKey.currentState?.renderTerminal.selectWord(selectAt);
      }
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox?;
      if (overlay == null) return;
      final selection = _terminalController.selection;
      final selected = selection == null
          ? ''
          : _terminal.buffer.getText(selection);
      final hasSelection = selected.trim().isNotEmpty;
      final choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          global.dx,
          global.dy,
          overlay.size.width - global.dx,
          overlay.size.height - global.dy,
        ),
        items: [
          PopupMenuItem<String>(
            value: 'copy',
            enabled: hasSelection,
            child: const Text('复制'),
          ),
          const PopupMenuItem<String>(value: 'copyAll', child: Text('复制全部')),
          const PopupMenuItem<String>(value: 'paste', child: Text('粘贴')),
          if (hasSelection)
            const PopupMenuItem<String>(value: 'clear', child: Text('取消选中')),
        ],
      );
      if (!mounted || choice == null) return;
      if (choice == 'copy') {
        await Clipboard.setData(ClipboardData(text: selected));
        _toast('已复制');
      } else if (choice == 'copyAll') {
        await Clipboard.setData(
          ClipboardData(text: _terminal.buffer.getText()),
        );
        _toast('已复制全部内容');
      } else if (choice == 'paste') {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text ?? '';
        if (text.isNotEmpty) {
          _terminal.paste(text);
          _focus.requestFocus();
        }
      } else if (choice == 'clear') {
        _terminalController.clearSelection();
      }
    } finally {
      _menuOpen = false;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }

  Widget _topBar(ColorScheme scheme) {
    final connected = _status == '已连接';
    final endpoint = widget.host.endpoint;
    return Container(
      height: 44,
      color: const Color(0xFF252526),
      child: Row(
        children: [
          const SizedBox(width: 4),
          IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back, size: 18),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '$_status  ·  $endpoint',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: connected
                        ? const Color(0xFF0DBC79)
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '端口转发',
            onPressed: connected ? _openForwards : null,
            icon: const Icon(Icons.swap_horiz, size: 18),
          ),
          IconButton(
            tooltip: '文件传输',
            onPressed: connected ? _openFiles : null,
            icon: const Icon(Icons.folder_outlined, size: 18),
          ),
          IconButton(
            tooltip: '重新连接',
            onPressed: () {
              _stdout?.cancel();
              unawaited(_conn.close());
              unawaited(_connect());
            },
            icon: const Icon(Icons.refresh, size: 18),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _errorBar(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      color: scheme.error.withValues(alpha: 0.18),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Text(
        _error!,
        style: TextStyle(fontSize: 11.5, height: 1.5, color: scheme.error),
      ),
    );
  }

  /// 手机上必须有一行功能键，否则 Esc / Tab / 方向键 都没法用。
  Widget _keyBar() {
    const keys = <(String, String)>[
      ('esc', '\x1b'),
      ('tab', '\x09'),
      ('^C', '\x03'),
      ('^D', '\x04'),
      ('^Z', '\x1a'),
      ('←', '\x1b[D'),
      ('↑', '\x1b[A'),
      ('↓', '\x1b[B'),
      ('→', '\x1b[C'),
      ('~', '~'),
      ('/', '/'),
      ('-', '-'),
      ('|', '|'),
    ];
    return Container(
      height: 46,
      color: const Color(0xFF252526),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        itemCount: keys.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final entry = keys[index];
          return InkWell(
            onTap: () => _send(entry.$2),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              alignment: Alignment.center,
              constraints: const BoxConstraints(minWidth: 42),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3C),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                entry.$1,
                style: const TextStyle(fontSize: 12, color: Colors.white),
              ),
            ),
          );
        },
      ),
    );
  }
}
