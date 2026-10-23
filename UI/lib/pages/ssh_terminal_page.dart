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
import '../widgets/password_keyboard.dart';
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
  final ScrollController _scroll = ScrollController();
  final SshConnection _conn = SshConnection();
  late final SshForwarder _forwarder = SshForwarder(_conn);
  final FocusNode _focus = FocusNode();
  final GlobalKey<TerminalViewState> _viewKey = GlobalKey<TerminalViewState>();
  StreamSubscription<Uint8List>? _stdout;

  String _status = '连接中';
  String? _error;
  Timer? _longPress;
  bool _menuOpen = false;
  Offset _downPosition = Offset.zero;
  bool _pointerMoved = false;
  bool _draggingSelection = false;
  double _swipeAccum = 0;

  /// Android 的选区光标：base/extent 是两端的单元格坐标，拖动时改写其中一个。
  CellOffset? _selBase;
  CellOffset? _selExtent;
  bool _selectionActive = false;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (data) => _conn.write(utf8.encode(data));
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) =>
        _conn.resize(width, height);
    _focus.addListener(_onFocusChanged);
    KeyboardConfig.builtin.addListener(_onBuiltinChanged);
    _systemInput = !KeyboardConfig.builtin.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _ensureInput();
      unawaited(_connect());
    });
  }

  @override
  void dispose() {
    KeyboardConfig.builtin.removeListener(_onBuiltinChanged);
    PasswordKeyboard.hide();
    _sysController.dispose();
    _sysFocus.dispose();
    _scroll.dispose();
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
    // 安卓用内置键盘，终端不需要再抢焦点；桌面才需要保持物理键盘输入。
    if (!Platform.isAndroid) _focus.requestFocus();
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
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _terminalArea()),
                  if (Platform.isAndroid)
                    Positioned.fill(child: _selectionLayer()),
                ],
              ),
            ),
            if (Platform.isAndroid) _keyBar(),
            if (Platform.isAndroid && _systemInput) _systemBar(),
          ],
        ),
      ),
    );
  }

  /// 终端本体 + 右键 / 长按菜单。
  Widget _terminalArea() {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: (_) => _longPress?.cancel(),
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        interactive: true,
        thickness: 6,
        radius: const Radius.circular(3),
        child: TerminalView(
          _terminal,
          key: _viewKey,
          scrollController: _scroll,
          controller: _terminalController,
          focusNode: _focus,
          autofocus: true,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          textStyle: const TerminalStyle(fontSize: 12.5),
          theme: TerminalThemes.defaultTheme,
          keyboardType: TextInputType.text,
          // 两端都不建输入法连接：桌面直接用物理键盘，安卓用 App 内置键盘。
          hardwareKeyboardOnly: true,
        ),
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
    _downPosition = event.position;
    _pointerMoved = false;
    _swipeAccum = 0;
    // 已经有选区时，点空白处先取消，避免光标一直挂在屏幕上。
    if (_selectionActive) {
      _clearSelection();
      return;
    }
    // 手机：长按选中手指下面那个词，然后出现两端可拖动的光标。
    final local = event.localPosition;
    _longPress?.cancel();
    _longPress = Timer(const Duration(milliseconds: 450), () {
      _startSelection(local);
      // 长按后手指不抬起来，继续拖就能扩选；vi / less 这类全屏程序里
      // 光靠两端光标不好拖，这个手势更顺手。
      _draggingSelection = true;
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_draggingSelection) {
      _extendSelection(event.localPosition);
      return;
    }
    if ((event.position - _downPosition).distance > 12) {
      _pointerMoved = true;
      _longPress?.cancel();
    }
    // vi / less 这类全屏程序用的是备用屏幕，终端没有可滚动的历史缓冲，
    // 滑动时改发 PgUp / PgDn，让程序自己翻页。
    if (_terminal.isUsingAltBuffer && !_selectionActive) {
      _swipeAccum += event.delta.dy;
      // 备用屏幕没有滚动缓冲，只能翻页；阈值放到 10px，滑一点就翻，
      // 手感接近连续滚动（一次滑动会连续发几十条）。
      // Ctrl+E / Ctrl+Y 是 vi、less 通用的「滚一行」，比整页翻动更跟手。
      while (_swipeAccum <= -8) {
        _swipeAccum += 8;
        _send('\x05');
      }
      while (_swipeAccum >= 8) {
        _swipeAccum -= 8;
        _send('\x19');
      }
    }
  }

  /// 长按后拖动：把选区另一端跟到手指所在的单元格。
  void _extendSelection(Offset local) {
    final view = _viewKey.currentState;
    final base = _selBase;
    if (view == null || base == null) return;
    final cell = view.renderTerminal.getCellOffset(local);
    setState(() => _selExtent = cell);
    _terminalController.setSelection(
      _terminal.buffer.createAnchorFromOffset(base),
      _terminal.buffer.createAnchorFromOffset(cell),
      mode: SelectionMode.line,
    );
  }

  /// 轻点终端：安卓弹出内置键盘；拖动（滚动）和长按（选字）不触发。
  void _onPointerUp(PointerUpEvent event) {
    _longPress?.cancel();
    _draggingSelection = false;
    if (!Platform.isAndroid) return;
    if (_pointerMoved || _selectionActive) return;
    _openKeypad();
  }

  void _openKeypad() {
    if (_systemInput || !KeyboardConfig.builtin.value) {
      _useSystemInput();
      return;
    }
    PasswordKeyboard.show(
      _TerminalSink(this),
      height: 240,
      terminal: true,
      onSystem: _useSystemInput,
    );
  }

  // ------------------------------------------------------ 系统输入法输入条

  bool _systemInput = false;
  final _sysController = TextEditingController();
  final _sysFocus = FocusNode();
  String _sysText = '';
  bool _sysResetting = false;

  static final _del = String.fromCharCode(127);
  static final _enter = String.fromCharCode(13);

  /// 设置里的「使用内置键盘」一变，终端立刻跟着切，不用退出重进。
  void _onBuiltinChanged() {
    if (!mounted) return;
    final useBuiltIn = KeyboardConfig.builtin.value;
    if (!useBuiltIn) {
      if (!_systemInput) _useSystemInput();
      return;
    }
    if (_systemInput) {
      PasswordKeyboard.hide();
      _sysFocus.unfocus();
      _sysResetting = true;
      _sysController.clear();
      _sysText = '';
      _sysResetting = false;
      setState(() => _systemInput = false);
    }
  }

  void _useSystemInput() {
    PasswordKeyboard.hide();
    setState(() => _systemInput = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sysFocus.requestFocus();
    });
  }

  void _useBuiltInInput() {
    setState(() => _systemInput = false);
    _sysFocus.unfocus();
    _sysResetting = true;
    _sysController.clear();
    _sysText = '';
    _sysResetting = false;
    _openKeypad();
  }

  /// 把输入框里的增量翻译成终端的按键：删几个发几个 DEL，新增的直接发。
  void _onSystemChanged(String next) {
    if (_sysResetting) return;
    final prev = _sysText;
    if (next == prev) return;
    var same = 0;
    while (same < prev.length &&
        same < next.length &&
        prev[same] == next[same]) {
      same++;
    }
    final removed = prev.length - same;
    for (var i = 0; i < removed; i++) {
      _send(_del);
    }
    final added = next.substring(same);
    if (added.isNotEmpty) _send(added);
    _sysText = next;
    if (_sysText.length > 160) {
      _sysResetting = true;
      _sysController.clear();
      _sysText = '';
      _sysResetting = false;
    }
  }

  Widget _systemBar() {
    return Container(
      color: const Color(0xFF262626),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _sysController,
              focusNode: _sysFocus,
              autofocus: true,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '系统键盘输入，回车发送',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              onChanged: _onSystemChanged,
              onSubmitted: (_) {
                _send(_enter);
                _sysResetting = true;
                _sysController.clear();
                _sysText = '';
                _sysResetting = false;
                _sysFocus.requestFocus();
              },
            ),
          ),
          TextButton(
            onPressed: _useBuiltInInput,
            child: const Text('内置', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _openMenu(Offset global) async {
    if (_menuOpen) return;
    _menuOpen = true;
    try {
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

  /// 长按起始：选中手指下的词，然后把两端光标交给用户拖。
  void _startSelection(Offset local) {
    final view = _viewKey.currentState;
    if (view == null) return;
    final cell = view.renderTerminal.getCellOffset(local);
    final word = _terminal.buffer.getWordBoundary(cell);
    final begin = word?.begin ?? cell;
    final end = word?.end ?? CellOffset(cell.x + 1, cell.y);
    // 先把键盘收起来，不然光标和工具条会被挡在下半屏。
    _focus.unfocus();
    setState(() {
      _selBase = begin;
      _selExtent = end;
      _selectionActive = true;
    });
    _terminalController.setSelection(
      _terminal.buffer.createAnchorFromOffset(begin),
      _terminal.buffer.createAnchorFromOffset(end),
      mode: SelectionMode.line,
    );
  }

  /// 拖动某一端光标：把手指位置换算成单元格，重设选区。
  void _moveHandle(bool isStart, Offset global) {
    final view = _viewKey.currentState;
    final box = _viewKey.currentContext?.findRenderObject() as RenderBox?;
    if (view == null || box == null) return;
    final cell = view.renderTerminal.getCellOffset(box.globalToLocal(global));
    final base = isStart ? cell : _selBase;
    final extent = isStart ? _selExtent : cell;
    if (base == null || extent == null) return;
    setState(() {
      _selBase = base;
      _selExtent = extent;
    });
    _terminalController.setSelection(
      _terminal.buffer.createAnchorFromOffset(base),
      _terminal.buffer.createAnchorFromOffset(extent),
      mode: SelectionMode.line,
    );
  }

  void _clearSelection() {
    _terminalController.clearSelection();
    setState(() {
      _selBase = null;
      _selExtent = null;
      _selectionActive = false;
    });
  }

  Future<void> _copySelection() async {
    final selection = _terminalController.selection;
    final text = selection == null ? '' : _terminal.buffer.getText(selection);
    if (text.isEmpty) {
      _toast('没有选中内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制');
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) return;
    _terminal.paste(text);
    _clearSelection();
    _focus.requestFocus();
  }

  /// 选区两端的圆形光标 + 悬浮工具条，只在安卓长按后出现。
  Widget _selectionLayer() {
    return IgnorePointer(
      ignoring: !_selectionActive,
      child: AnimatedBuilder(
        animation: _terminalController,
        builder: (context, _) {
          final base = _selBase;
          final extent = _selExtent;
          final view = _viewKey.currentState;
          if (!_selectionActive || base == null || extent == null) {
            return const SizedBox.shrink();
          }
          if (view == null) return const SizedBox.shrink();
          final render = view.renderTerminal;
          final lineHeight = render.lineHeight;
          return LayoutBuilder(
            builder: (context, constraints) {
              Offset point(CellOffset cell) {
                final offset = render.getOffset(cell);
                return Offset(
                  offset.dx.clamp(4.0, constraints.maxWidth - 20),
                  offset.dy.clamp(0.0, constraints.maxHeight - 20),
                );
              }

              final basePoint = point(base);
              final extentPoint = point(extent);
              final upper = basePoint.dy <= extentPoint.dy
                  ? basePoint
                  : extentPoint;
              final lower = basePoint.dy <= extentPoint.dy
                  ? extentPoint
                  : basePoint;
              final above = upper.dy > 52;
              return Stack(
                children: [
                  _handleDot(basePoint, isStart: true),
                  _handleDot(
                    extentPoint,
                    isStart: false,
                    lineHeight: lineHeight,
                  ),
                  Positioned(
                    left: (upper.dx - 76).clamp(
                      4.0,
                      constraints.maxWidth - 196,
                    ),
                    top: above ? upper.dy - 46 : lower.dy + lineHeight + 8,
                    child: _selectionToolbar(),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _handleDot(
    Offset at, {
    required bool isStart,
    double lineHeight = 16,
  }) {
    return Positioned(
      left: at.dx - 10,
      top: isStart ? at.dy - 20 : at.dy + lineHeight + 2,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => _moveHandle(isStart, details.globalPosition),
        child: SizedBox(
          width: 20,
          height: 20,
          child: Center(
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: const Color(0xFF3B82F6),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectionToolbar() {
    return Material(
      color: const Color(0xFF2D2D30),
      elevation: 6,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _toolbarButton('复制', _copySelection),
            _toolbarButton('粘贴', _pasteClipboard),
            _toolbarButton('取消', _clearSelection),
          ],
        ),
      ),
    );
  }

  Widget _toolbarButton(String label, VoidCallback onTap) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        foregroundColor: Colors.white,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
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

/// 内置键盘 -> SSH 字节流。
class _TerminalSink extends PasswordKeySink {
  _TerminalSink(this.state);

  final _SshTerminalPageState state;

  @override
  void insert(String text) => state._send(text);

  @override
  void backspace() => state._send('\x7f');

  @override
  void clear() {}

  @override
  void paste(String text) => state._terminal.paste(text);
}
