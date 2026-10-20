import 'package:flutter/material.dart';

/// 密码框：输入法看到的是普通文本框（不会切成「安全键盘」），界面上仍然显示圆点。
///
/// obscureText 会让 Android 把输入类型标成密码，华为/小米这类输入法会据此启用
/// 安全键盘、禁用联想和部分符号键。这里改成普通文本 + 自绘掩码。
class MaskedTextController extends TextEditingController {
  MaskedTextController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return TextSpan(style: style, text: '•' * text.length);
  }
}

class MaskedTextField extends StatelessWidget {
  const MaskedTextField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.autofocus = false,
    this.onSubmitted,
  });

  final MaskedTextController controller;
  final String? label;
  final String? hint;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: false,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.text,
      decoration: InputDecoration(labelText: label, hintText: hint),
      onSubmitted: onSubmitted,
    );
  }
}
