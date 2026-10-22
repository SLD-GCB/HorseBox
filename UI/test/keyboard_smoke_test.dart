import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:horsebox/widgets/password_keyboard.dart';

class _Sink extends PasswordKeySink {
  final StringBuffer buffer = StringBuffer();

  @override
  void insert(String text) => buffer.write(text);

  @override
  void backspace() {}

  @override
  void clear() => buffer.clear();
}

void main() {
  testWidgets('keypad renders keys', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    PasswordKeyboard.show(_Sink());
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PasswordKeyboardHost(child: child ?? const SizedBox()),
        home: const Scaffold(body: Center(child: Text('page'))),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('q'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
  });
}
