import 'package:flutter_test/flutter_test.dart';
import 'package:horsebox/ime/pinyin_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('离线词库能给出合理候选', () async {
    final engine = await PinyinEngine.instance();
    expect(engine.entryCount, greaterThan(10000));

    expect(engine.candidates('nihao', limit: 5), contains('你好'));
    expect(engine.candidates('zhongguo', limit: 5), contains('中国'));
    expect(engine.candidates('shurufa', limit: 5), contains('输入法'));
    expect(engine.candidates('zhongg', limit: 5), contains('中国'));
    expect(engine.candidates('nh', limit: 5), isNotEmpty);
    expect(engine.candidates('', limit: 5), isEmpty);
  });

  test('模糊音 zh/z ch/c sh/s 互通', () async {
    final engine = await PinyinEngine.instance();
    expect(engine.candidates('zongguo', limit: 8, fuzzy: true), contains('中国'));
    expect(
      engine.candidates('shenzhen', limit: 8, fuzzy: true),
      contains('深圳'),
    );
    expect(engine.candidates('cangsha', limit: 8, fuzzy: true), contains('长沙'));
    // 不开模糊音时，错拼不应误命中
    expect(
      engine.candidates('zongguo', limit: 8, fuzzy: false),
      isNot(contains('中国')),
    );
  });

  test('整句切分', () async {
    final engine = await PinyinEngine.instance();
    final list = engine.candidates('woaibeijing', limit: 5, sentence: true);
    expect(list.first, contains('我'));
    expect(list.join(), contains('北京'));
  });

  test('扩充后的词库覆盖更多词组', () async {
    final watch = Stopwatch()..start();
    final engine = await PinyinEngine.instance();
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(5000));
    expect(engine.entryCount, greaterThan(120000));
    expect(engine.candidates('weixin', limit: 6), contains('微信'));
    expect(engine.candidates('liulanqi', limit: 6), contains('浏览器'));
    expect(engine.candidates('dayinji', limit: 6), contains('打印机'));
    expect(engine.candidates('bilibili', limit: 6), isNotEmpty);
  });

  test('九宫格数字候选', () async {
    final engine = await PinyinEngine.instance();
    // nihao -> 64426
    expect(engine.t9Candidates('64426', limit: 7), contains('你好'));
    expect(engine.t9Candidates('', limit: 7), isEmpty);
  });
}
