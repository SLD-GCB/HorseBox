import 'package:flutter/material.dart';

/// 密码框：输入法看到的是普通文本框（不会切成「安全键盘」），界面上仍然显示圆点。
///
/// 输入法判断「敏感输入」看的是 Android 的 inputType 标志，任一命中就切安全键盘：
///   obscureText: true      -> TYPE_TEXT_VARIATION_PASSWORD
///   enableSuggestions:false -> TYPE_TEXT_FLAG_NO_SUGGESTIONS
///   autocorrect: false      -> TYPE_TEXT_FLAG_AUTO_CORRECT 缺失
/// 所以这三项必须一起放开，只放开其中一个照样会弹。掩码由 [MaskedTextController]
/// 自绘，不依赖 obscureText，因此不影响显示。
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
      autocorrect: true,
      enableSuggestions: true,
      keyboardType: TextInputType.text,
      decoration: InputDecoration(labelText: label, hintText: hint),
      onSubmitted: onSubmitted,
    );
  }
}
