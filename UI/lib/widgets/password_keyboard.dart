import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'masked_field.dart';

/// 内置键盘的默认高度。宿主据此让页面让位。
const double kPasswordKeyboardHeight = 240;

/// 键盘的输出目标：原生输入框写 controller，WebView 走 JS。
abstract class PasswordKeySink {
  void insert(String text);

  void backspace();

  void clear();

  void paste(String text) => insert(text);
}

/// 全局单例：同一时刻只允许一个键盘。
class PasswordKeyboard {
  PasswordKeyboard._();

  static final ValueNotifier<_KeySession?> _session = ValueNotifier(null);

  static bool get isOpen => _session.value != null;

  static void show(
    PasswordKeySink sink, {
    String title = '输入密码',
    double height = kPasswordKeyboardHeight,
    VoidCallback? onSystem,
    bool terminal = false,
    VoidCallback? onEnter,
  }) {
    _session.value = _KeySession(
      sink,
      title,
      height,
      onSystem,
      terminal,
      onEnter,
    );
  }

  static void hide() {
    _session.value = null;
  }
}

class _KeySession {
  _KeySession(
    this.sink,
    this.title,
    this.height,
    this.onSystem,
    this.terminal,
    this.onEnter,
  );

  final PasswordKeySink sink;
  final String title;
  final double height;
  final bool terminal;
  final VoidCallback? onEnter;

  /// 非空时在键盘顶部显示「中文」按钮：切回系统输入法打中文。
  final VoidCallback? onSystem;
}

/// 把内置键盘固定在屏幕底部，并让整个 App（含弹窗）少掉这块高度，
/// 表现和系统输入法一致：内容被顶上去，不是浮在界面上。
class PasswordKeyboardHost extends StatelessWidget {
  const PasswordKeyboardHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_KeySession?>(
      valueListenable: PasswordKeyboard._session,
      builder: (context, session, _) {
        final height = session?.height ?? 0.0;
        return PopScope(
          canPop: session == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) PasswordKeyboard.hide();
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(bottom: height),
                  child: child,
                ),
              ),
              if (session != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: session.height,
                  child: Material(
                    color: const Color(0xFF252526),
                    child: _PasswordKeypad(
                      session: session,
                      onClose: PasswordKeyboard.hide,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ControllerSink extends PasswordKeySink {
  _ControllerSink(this.controller);

  final TextEditingController controller;

  @override
  void insert(String text) {
    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  @override
  void backspace() {
    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    if (start != end) {
      controller.value = TextEditingValue(
        text: value.text.replaceRange(start, end, ''),
        selection: TextSelection.collapsed(offset: start),
      );
      return;
    }
    if (start == 0) return;
    var cut = start - 1;
    final code = value.text.codeUnitAt(cut);
    if (code >= 0xDC00 && code <= 0xDFFF && cut > 0) cut -= 1;
    controller.value = TextEditingValue(
      text: value.text.replaceRange(cut, start, ''),
      selection: TextSelection.collapsed(offset: cut),
    );
  }

  @override
  void clear() => controller.clear();
}

/// 密码框：安卓上点一下打开内置键盘；桌面端有物理键盘，维持直接输入。
class SecretField extends StatelessWidget {
  const SecretField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.onSubmitted,
  });

  final MaskedTextController controller;
  final String? label;
  final String? hint;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!Platform.isAndroid) {
      return TextField(
        controller: controller,
        obscureText: false,
        autocorrect: true,
        enableSuggestions: true,
        keyboardType: TextInputType.text,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onSubmitted: onSubmitted,
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => PasswordKeyboard.show(
            _ControllerSink(controller),
            title: label ?? '输入密码',
            onEnter: onSubmitted == null
                ? null
                : () => onSubmitted!(controller.text),
          ),
          child: InputDecorator(
            isEmpty: value.text.isEmpty,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              suffixIcon: Icon(
                Icons.dialpad,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ),
            child: Text(
              '•' * value.text.length,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, letterSpacing: 1.4),
            ),
          ),
        );
      },
    );
  }
}

class _PasswordKeypad extends StatefulWidget {
  const _PasswordKeypad({required this.session, required this.onClose});

  final _KeySession session;
  final VoidCallback onClose;

  @override
  State<_PasswordKeypad> createState() => _PasswordKeypadState();
}

class _PasswordKeypadState extends State<_PasswordKeypad> {
  bool _shift = false;
  bool _symbols = false;

  PasswordKeySink get _sink => widget.session.sink;

  static const _digits = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
  static const _rowQ = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
  static const _rowA = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
  static const _rowZ = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];

  static const _sym1 = ['!', '@', '#', '\$', '%', '^', '&', '*', '(', ')'];
  static const _sym2 = ['-', '_', '=', '+', '[', ']', '{', '}', ';', ':'];
  static const _sym3 = ["'", '"', ',', '.', '/', '\\', '|', '<', '>', '?'];
  static const _sym4 = ['~', '`', '€', '£', '¥', '§', '°', '±', '×', '÷'];

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isNotEmpty) _sink.paste(text);
  }

  Widget _key(
    String label, {
    VoidCallback? onTap,
    int flex = 1,
    bool accent = false,
    double fontSize = 15,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Material(
          color: accent ? const Color(0xFF2563EB) : const Color(0xFF3A3A3C),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Center(
              child: Text(
                label,
                style: TextStyle(fontSize: fontSize, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _letter(String char) {
    final label = _shift ? char.toUpperCase() : char;
    return _key(
      label,
      onTap: () {
        _sink.insert(label);
        if (_shift) setState(() => _shift = false);
      },
    );
  }

  Widget _row(List<Widget> keys, {double horizontal = 0}) => Expanded(
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontal),
      child: Row(children: keys),
    ),
  );

  List<Widget> _letterRows() {
    return [
      _row(
        _digits
            .map((item) => _key(item, onTap: () => _sink.insert(item)))
            .toList(),
      ),
      _row(_rowQ.map(_letter).toList()),
      _row(_rowA.map(_letter).toList(), horizontal: 15),
      _row([
        _key(
          '⇧',
          flex: 2,
          accent: _shift,
          onTap: () => setState(() => _shift = !_shift),
        ),
        ..._rowZ.map(_letter),
        _key('⌫', flex: 2, onTap: _sink.backspace),
      ]),
      _row([
        _key(
          '?123',
          flex: 3,
          fontSize: 13,
          onTap: () => setState(() => _symbols = true),
        ),
        _key('空格', flex: 5, fontSize: 13, onTap: () => _sink.insert(' ')),
        if (widget.session.terminal)
          _key('↵', flex: 2, fontSize: 15, onTap: () => _sink.insert('\r'))
        else if (widget.session.onEnter != null)
          _key(
            '↵',
            flex: 2,
            fontSize: 15,
            onTap: () {
              final enter = widget.session.onEnter!;
              widget.onClose();
              enter();
            },
          ),
        _key('完成', flex: 3, accent: true, fontSize: 13, onTap: widget.onClose),
      ]),
    ];
  }

  List<Widget> _symbolRows() {
    Widget plain(String item) => _key(item, onTap: () => _sink.insert(item));

    return [
      _row(_sym1.map(plain).toList()),
      _row(_sym2.map(plain).toList()),
      _row(_sym3.map(plain).toList()),
      _row(_sym4.map(plain).toList()),
      _row([
        _key(
          'ABC',
          flex: 3,
          fontSize: 13,
          onTap: () => setState(() => _symbols = false),
        ),
        _key('空格', flex: 4, fontSize: 13, onTap: () => _sink.insert(' ')),
        _key('⌫', flex: 2, onTap: _sink.backspace),
        if (widget.session.terminal)
          _key('↵', flex: 2, fontSize: 15, onTap: () => _sink.insert('\r'))
        else if (widget.session.onEnter != null)
          _key(
            '↵',
            flex: 2,
            fontSize: 15,
            onTap: () {
              final enter = widget.session.onEnter!;
              widget.onClose();
              enter();
            },
          ),
        _key('完成', flex: 3, accent: true, fontSize: 13, onTap: widget.onClose),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 34,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Text(
                widget.session.title,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const Spacer(),
              if (widget.session.onSystem != null)
                TextButton(
                  onPressed: () {
                    final action = widget.session.onSystem!;
                    PasswordKeyboard.hide();
                    action();
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('中文', style: TextStyle(fontSize: 12)),
                ),
              TextButton(
                onPressed: _paste,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('粘贴', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: _sink.clear,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('清空', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: widget.onClose,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('收起', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
        Expanded(
          child: Column(children: _symbols ? _symbolRows() : _letterRows()),
        ),
        SizedBox(height: MediaQuery.viewPaddingOf(context).bottom),
      ],
    );
  }
}

/// 通用输入框：默认走内置键盘；键盘顶部「中文」切回系统输入法，
/// 系统键盘收起后自动回到内置键盘。密码框不要用它（用 [SecretField]）。
class KeyField extends StatefulWidget {
  const KeyField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.onSubmitted,
    this.keyboardType,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final bool autofocus;

  @override
  State<KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends State<KeyField> {
  final FocusNode _focus = FocusNode();
  bool _system = false;

  /// 切系统输入法时我们会先失焦再聚焦，这期间不能被当成“用户收起了键盘”。
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_switching) return;
    // 系统键盘收起（失焦）后，下次点一下仍回到内置键盘。
    if (!_focus.hasFocus && _system && mounted) {
      setState(() => _system = false);
    }
  }

  void _openBuiltIn() {
    PasswordKeyboard.show(
      _ControllerSink(widget.controller),
      title: widget.label ?? '输入',
      onEnter: widget.onSubmitted == null
          ? null
          : () => widget.onSubmitted!(widget.controller.text),
      onSystem: () {
        if (!mounted) return;
        setState(() {
          _switching = true;
          _system = true;
        });
        // 已经有焦点时 requestFocus 不会重新拉起输入法，先失焦再聚焦；
        // 这期间 _switching 挡住焦点监听，避免又把 _system 复位。
        _focus.unfocus();
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          _focus.requestFocus();
          // 个别机型在 readOnly 刚放开时不会自动弹键盘，显式再要一次。
          await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
          if (mounted) setState(() => _switching = false);
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      readOnly: !_system,
      keyboardType: widget.keyboardType ?? TextInputType.text,
      textInputAction: TextInputAction.done,
      onTap: () {
        if (_system) return;
        _openBuiltIn();
      },
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        suffixIcon: _system
            ? IconButton(
                tooltip: '用内置键盘',
                onPressed: () {
                  setState(() => _system = false);
                  _focus.unfocus();
                  _openBuiltIn();
                },
                icon: Icon(
                  Icons.dialpad,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              )
            : Icon(Icons.dialpad, size: 18, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
