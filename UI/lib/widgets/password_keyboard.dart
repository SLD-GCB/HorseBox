import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ime/pinyin_engine.dart';
import 'masked_field.dart';

/// 内置键盘的默认高度。宿主据此让页面让位。
const double kPasswordKeyboardHeight = 282;

/// 内置键盘的可配置项，由设置页写入（AppState 初始化/保存时同步）。
class KeyboardConfig {
  KeyboardConfig._();

  /// 打开键盘时默认中文输入。
  static bool chinese = false;

  /// 候选词数量。
  static int candidates = 5;

  /// 模糊音：zh/z、ch/c、sh/s 互通。
  static bool fuzzy = true;

  /// 整句切分（长拼音串自动分词）。
  static bool sentence = true;

  /// full = 全键盘，nine = 九宫格。
  static String layout = 'full';

  /// 全 App 使用内置键盘：不再提供切回系统输入法的入口。
  static bool global = false;
}

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

  /// 当前正在接收输入的 sink；输入框用它判断自己是不是“活动的那一个”。
  static PasswordKeySink? get activeSink => _session.value?.sink;

  /// 键盘开关变化的监听，供输入框刷新光标/高亮。
  static Listenable get changes => _session;

  static void show(
    PasswordKeySink sink, {
    double height = kPasswordKeyboardHeight,
    VoidCallback? onSystem,
    bool terminal = false,
    VoidCallback? onEnter,
    bool? chinese,
  }) {
    _session.value = _KeySession(
      sink,
      height,
      onSystem,
      terminal,
      onEnter,
      chinese,
    );
  }

  static void hide() {
    _session.value = null;
  }
}

class _KeySession {
  _KeySession(
    this.sink,
    this.height,
    this.onSystem,
    this.terminal,
    this.onEnter,
    this.chinese,
  );

  final PasswordKeySink sink;
  final double height;
  final bool terminal;
  final VoidCallback? onEnter;

  /// 非空时在键盘顶部显示「⌨」按钮：切回系统输入法。
  final VoidCallback? onSystem;

  /// 是否默认中文；null 表示跟随全局设置（密码框会显式传 false）。
  final bool? chinese;
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
class SecretField extends StatefulWidget {
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
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  /// 固定一个 sink 实例：键盘靠它判断“当前输入的是哪个框”。
  late final _ControllerSink _sink = _ControllerSink(widget.controller);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!Platform.isAndroid) {
      return TextField(
        controller: widget.controller,
        obscureText: false,
        autocorrect: true,
        enableSuggestions: true,
        keyboardType: TextInputType.text,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
        ),
        onSubmitted: widget.onSubmitted,
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        return ListenableBuilder(
          listenable: PasswordKeyboard.changes,
          builder: (context, _) {
            final active = identical(PasswordKeyboard.activeSink, _sink);
            return InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => PasswordKeyboard.show(
                _sink,

                chinese: false,
                onEnter: widget.onSubmitted == null
                    ? null
                    : () => widget.onSubmitted!(widget.controller.text),
              ),
              child: InputDecorator(
                isEmpty: value.text.isEmpty,
                isFocused: active,
                decoration: InputDecoration(
                  labelText: widget.label,
                  hintText: widget.hint,
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: scheme.primary, width: 1.4),
                  ),
                  suffixIcon: Icon(
                    Icons.dialpad,
                    size: 18,
                    color: active ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      '•' * value.text.length,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, letterSpacing: 1.4),
                    ),
                    if (active) const _Caret(),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 内置键盘打开时的闪烁光标：用户能看清正在往哪个框里输入。
class _Caret extends StatefulWidget {
  const _Caret();

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final on = _controller.value < 0.55;
        return Container(
          width: 1.6,
          height: 16,
          margin: const EdgeInsets.only(left: 2),
          color: on ? color : color.withValues(alpha: 0),
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

  /// 中文模式：字母先攒进拼音缓冲，选候选项后才写进输入框。
  bool _zh = false;
  String _buffer = '';
  List<String> _candidates = const [];
  PinyinEngine? _engine;

  @override
  void initState() {
    super.initState();
    // 终端里默认英文，免得输入命令时被拼音拦一层。
    _zh =
        (widget.session.chinese ?? KeyboardConfig.chinese) &&
        !widget.session.terminal;
    if (_zh) _warmUp();
  }

  void _warmUp() {
    if (_engine != null) return;
    PinyinEngine.instance().then((engine) {
      if (!mounted) return;
      setState(() {
        _engine = engine;
        _candidates = _lookup(_buffer);
      });
    });
  }

  /// 九宫格按数字查，全键盘按拼音查。
  List<String> _lookup(String buffer) {
    final engine = _engine;
    if (engine == null || buffer.isEmpty) return const [];
    if (_nine) {
      return engine.t9Candidates(buffer, limit: KeyboardConfig.candidates);
    }
    return engine.candidates(
      buffer,
      limit: KeyboardConfig.candidates,
      fuzzy: KeyboardConfig.fuzzy,
      sentence: KeyboardConfig.sentence,
    );
  }

  bool get _nine => KeyboardConfig.layout == 'nine' && _zh;

  void _type(String text) {
    if (!_zh) {
      _sink.insert(text);
      return;
    }
    setState(() {
      _buffer += text;
      _candidates = _lookup(_buffer);
    });
  }

  void _commit(String word) {
    if (word.isEmpty) return;
    _sink.insert(word);
    setState(() {
      _buffer = '';
      _candidates = const [];
    });
  }

  void _backspace() {
    if (_zh && _buffer.isNotEmpty) {
      setState(() {
        _buffer = _buffer.substring(0, _buffer.length - 1);
        _candidates = _lookup(_buffer);
      });
      return;
    }
    _sink.backspace();
  }

  void _space() {
    if (_zh && _buffer.isNotEmpty) {
      _commit(_candidates.isNotEmpty ? _candidates.first : _buffer);
      return;
    }
    _sink.insert(' ');
  }

  /// 切到英文前先把拼音落进输入框，避免丢字。
  void _commitPending() {
    if (!_zh || _buffer.isEmpty) return;
    _sink.insert(_candidates.isNotEmpty ? _candidates.first : _buffer);
    setState(() {
      _buffer = '';
      _candidates = const [];
    });
  }

  void _toggleLang() {
    if (_zh) _commitPending();
    setState(() {
      _zh = !_zh;
      _buffer = '';
      _candidates = const [];
      _shift = false;
    });
    if (_zh) _warmUp();
  }

  PasswordKeySink get _sink => widget.session.sink;

  static const _digits = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
  static const _rowQ = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
  static const _rowA = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
  static const _rowZ = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];

  static const _sym1 = ['!', '@', '#', '\$', '%', '^', '&', '*', '(', ')'];
  static const _sym2 = ['-', '_', '=', '+', '[', ']', '{', '}', ';', ':'];
  static const _sym3 = ["'", '"', ',', '.', '/', '\\', '|', '<', '>', '?'];
  static const _sym4 = ['~', '`', '€', '£', '¥', '§', '°', '±', '×', '÷'];

  Widget _key(
    String label, {
    VoidCallback? onTap,
    int flex = 1,
    bool accent = false,
    double fontSize = 15,
    Widget? child,
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
              child:
                  child ??
                  Text(
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
    if (_zh) {
      return _key(char, onTap: () => _type(char));
    }
    final label = _shift ? char.toUpperCase() : char;
    return _key(
      label,
      onTap: () {
        _type(label);
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

  /// 九宫格：3×4，按数字查库，只用于中文。
  List<Widget> _nineRows() {
    const keys = <(String, String)>[
      ('1', '.,?!'),
      ('2', 'abc'),
      ('3', 'def'),
      ('4', 'ghi'),
      ('5', 'jkl'),
      ('6', 'mno'),
      ('7', 'pqrs'),
      ('8', 'tuv'),
      ('9', 'wxyz'),
    ];
    Widget cell((String, String) item) {
      return _key(
        '',
        onTap: () => _type(item.$1),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              item.$1,
              style: const TextStyle(fontSize: 18, color: Colors.white),
            ),
            Text(
              item.$2,
              style: const TextStyle(fontSize: 9, color: Colors.white54),
            ),
          ],
        ),
      );
    }

    return [
      _row(keys.take(3).map(cell).toList()),
      _row(keys.skip(3).take(3).map(cell).toList()),
      _row(keys.skip(6).take(3).map(cell).toList()),
      _row([
        _key(
          '?123',
          flex: 2,
          fontSize: 13,
          onTap: () => setState(() => _symbols = true),
        ),
        _key('空格', flex: 4, fontSize: 13, onTap: _space),
        _key('⌫', flex: 2, onTap: _backspace),
        _key('完成', flex: 2, accent: true, fontSize: 13, onTap: widget.onClose),
      ]),
    ];
  }

  List<Widget> _letterRows() {
    return [
      _row(
        _digits.map((item) => _key(item, onTap: () => _type(item))).toList(),
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
        _key('⌫', flex: 2, onTap: _backspace),
      ]),
      _row([
        _key(
          '?123',
          flex: 3,
          fontSize: 13,
          onTap: () => setState(() => _symbols = true),
        ),
        _key('空格', flex: 5, fontSize: 13, onTap: _space),
        if (widget.session.terminal)
          _key(
            '↵',
            flex: 2,
            fontSize: 15,
            onTap: () {
              _commitPending();
              _sink.insert('\r');
            },
          )
        else if (widget.session.onEnter != null)
          _key(
            '↵',
            flex: 2,
            fontSize: 15,
            onTap: () {
              _commitPending();
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
        _key('空格', flex: 4, fontSize: 13, onTap: _space),
        _key('⌫', flex: 2, onTap: _backspace),
        if (widget.session.terminal)
          _key(
            '↵',
            flex: 2,
            fontSize: 15,
            onTap: () {
              _commitPending();
              _sink.insert('\r');
            },
          )
        else if (widget.session.onEnter != null)
          _key(
            '↵',
            flex: 2,
            fontSize: 15,
            onTap: () {
              _commitPending();
              final enter = widget.session.onEnter!;
              widget.onClose();
              enter();
            },
          ),
        _key('完成', flex: 3, accent: true, fontSize: 13, onTap: widget.onClose),
      ]),
    ];
  }

  Widget _candidateBar() {
    if (!_zh) {
      return Container(
        height: 36,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: const Text(
          '英文输入 · 点左侧「中」切到拼音',
          style: TextStyle(fontSize: 11, color: Colors.white38),
        ),
      );
    }
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _buffer.isEmpty ? '拼音' : _buffer,
              style: const TextStyle(fontSize: 12.5, color: Colors.white70),
            ),
          ),
          Expanded(
            child: _candidates.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _engine == null
                          ? '词库加载中…'
                          : (_buffer.isEmpty ? '输入拼音选词' : '没有候选，空格直接上屏'),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white38,
                      ),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    itemCount: _candidates.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 6),
                    itemBuilder: (context, index) {
                      final word = _candidates[index];
                      return InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () {
                          _commit(word);
                        },
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF3A3A3C),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            word,
                            style: const TextStyle(
                              fontSize: 15,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 34,
          child: Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: _toggleLang,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _zh ? '中' : '英',
                  style: TextStyle(
                    fontSize: 12,
                    color: _zh ? const Color(0xFF60A5FA) : Colors.white70,
                  ),
                ),
              ),
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
                  child: const Text('⌨', style: TextStyle(fontSize: 13)),
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
        _candidateBar(),
        Expanded(
          child: Column(
            children: _symbols
                ? _symbolRows()
                : (_nine ? _nineRows() : _letterRows()),
          ),
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
  late final _ControllerSink _sink = _ControllerSink(widget.controller);
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
    _focus.requestFocus();
    PasswordKeyboard.show(
      _sink,

      onEnter: widget.onSubmitted == null
          ? null
          : () => widget.onSubmitted!(widget.controller.text),
      onSystem: KeyboardConfig.global
          ? null
          : () {
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
                await SystemChannels.textInput.invokeMethod<void>(
                  'TextInput.show',
                );
                if (mounted) setState(() => _switching = false);
              });
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 桌面端有物理键盘，直接用原生输入框，不弹内置键盘。
    if (!Platform.isAndroid) {
      return TextField(
        controller: widget.controller,
        keyboardType: widget.keyboardType ?? TextInputType.text,
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
        ),
      );
    }
    // 内置键盘模式下用 TextInputType.none 压住系统输入法，
    // 同时保持可编辑，光标（caret）才能显示出来。
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        return ListenableBuilder(
          listenable: PasswordKeyboard.changes,
          builder: (context, _) {
            final active = identical(PasswordKeyboard.activeSink, _sink);
            return TextField(
              controller: widget.controller,
              focusNode: _focus,
              keyboardType: _system
                  ? (widget.keyboardType ?? TextInputType.text)
                  : TextInputType.none,
              textInputAction: TextInputAction.done,
              showCursor: true,
              cursorWidth: 1.6,
              onTap: () {
                if (_system) return;
                _openBuiltIn();
              },
              onSubmitted: widget.onSubmitted,
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.hint,
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: scheme.primary, width: 1.4),
                ),
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
                    : Icon(
                        Icons.dialpad,
                        size: 18,
                        color: active
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
              ),
            );
          },
        );
      },
    );
  }
}
