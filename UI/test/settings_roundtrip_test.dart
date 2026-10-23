import 'package:flutter_test/flutter_test.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

void main() {
  test('设置序列化不丢字段（IME 相关）', () {
    final source = AppSettings().copyWith(
      imeChinese: true,
      imeCandidates: 7,
      imeFuzzy: false,
      imeSentence: false,
      imeLayout: 'nine',
      imeGlobal: true,
      imeHeight: 320,
      imeScale: 1.2,
      imeLearn: false,
      imeClipboard: false,
      imeAccentMode: 'custom',
      imeAccentColor: 0xFF3B82F6,
      imeDarkMode: 'system',
      imeBuiltin: false,
      imeAutocorrect: false,
      imeCustomPalette: true,
      imeBgColor: 0xFF101010,
      imeKeyColor: 0xFF202020,
      imeTextColor: 0xFFEEEEEE,
      imeSound: true,
      imeVibrate: false,
      imeVibrateAmplitude: 200,
    );
    final back = AppSettings.fromJson(source.toJson());
    expect(back.imeChinese, isTrue);
    expect(back.imeCandidates, 7);
    expect(back.imeFuzzy, isFalse);
    expect(back.imeSentence, isFalse);
    expect(back.imeLayout, 'nine');
    expect(back.imeGlobal, isTrue);
    expect(back.imeHeight, 320);
    expect(back.imeScale, 1.2);
    expect(back.imeLearn, isFalse);
    expect(back.imeClipboard, isFalse);
    expect(back.imeAccentMode, 'custom');
    expect(back.imeAccentColor, 0xFF3B82F6);
    expect(back.imeDarkMode, 'system');
    expect(back.imeBuiltin, isFalse);
    expect(back.imeAutocorrect, isFalse);
    expect(back.imeCustomPalette, isTrue);
    expect(back.imeBgColor, 0xFF101010);
    expect(back.imeKeyColor, 0xFF202020);
    expect(back.imeTextColor, 0xFFEEEEEE);
    expect(back.imeSound, isTrue);
    expect(back.imeVibrate, isFalse);
    expect(back.imeVibrateAmplitude, 200);
  });
}
