import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

/// 离线拼音词库：全拼 / 首字母 / 模糊音 / 九宫格 / 整句切分。
///
/// 词库来自 rime-pinyin-simp（Apache-2.0），只做了格式转换：
/// 每行「全拼 / 首字母 / 词 / 权重」，制表符分隔，整体 gzip。
class PinyinEngine {
  PinyinEngine._(this._entries, this._syllables) {
    for (final entry in _entries) {
      final list = _exact.putIfAbsent(entry.code, () => <String>[]);
      if (list.length < 24 && !list.contains(entry.word)) list.add(entry.word);
      final fuzzy = _fuzzyOf(entry.code);
      if (fuzzy != entry.code) {
        final fuzzyList = _fuzzy.putIfAbsent(fuzzy, () => <String>[]);
        if (fuzzyList.length < 24 && !fuzzyList.contains(entry.word)) {
          fuzzyList.add(entry.word);
        }
      }
      final digits = _digitsOf(entry.code);
      final t9List = _t9.putIfAbsent(digits, () => <String>[]);
      if (t9List.length < 40 && !t9List.contains(entry.word)) {
        t9List.add(entry.word);
      }
      final best = _top[entry.code];
      if (best == null || best.weight < entry.weight) {
        _top[entry.code] = entry;
      }
    }
  }

  final List<_Entry> _entries;
  final Set<String> _syllables;
  final Map<String, List<String>> _exact = {};
  final Map<String, List<String>> _fuzzy = {};
  final Map<String, List<String>> _t9 = {};
  final Map<String, _Entry> _top = {};

  static PinyinEngine? _instance;
  static Future<PinyinEngine>? _loading;

  int get entryCount => _entries.length;

  static Future<PinyinEngine> instance() {
    final ready = _instance;
    if (ready != null) return Future.value(ready);
    return _loading ??= _load();
  }

  static Future<PinyinEngine> _load() async {
    final data = await rootBundle.load('assets/ime/pinyin.tsv.gz');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final text = utf8.decode(gzip.decode(bytes));
    final entries = <_Entry>[];
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty) continue;
      final parts = line.split('\t');
      if (parts.length < 4) continue;
      final weight = int.tryParse(parts[3]);
      if (weight == null) continue;
      entries.add(_Entry(parts[0], parts[1], parts[2], weight));
    }
    final syllableText = await rootBundle.loadString(
      'assets/ime/syllables.txt',
    );
    final syllables = const LineSplitter()
        .convert(syllableText)
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
    final engine = PinyinEngine._(entries, syllables);
    _instance = engine;
    _loading = null;
    return engine;
  }

  /// 拼音候选：整句 → 精确 → 前缀 → 首字母。
  List<String> candidates(
    String buffer, {
    int limit = 5,
    bool fuzzy = false,
    bool sentence = true,
  }) {
    if (buffer.isEmpty || limit <= 0) return const [];
    final result = <String>[];
    void add(String word) {
      if (result.length >= limit) return;
      if (word.isNotEmpty && !result.contains(word)) result.add(word);
    }

    if (sentence && buffer.length >= 6) {
      final line = _sentence(buffer);
      if (line != null && line != buffer) add(line);
    }

    final exact = _exact[buffer];
    if (exact != null) {
      for (final word in exact) {
        add(word);
        if (result.length >= limit) return result;
      }
    }
    if (fuzzy) {
      final fuzzyList = _fuzzy[_fuzzyOf(buffer)];
      if (fuzzyList != null) {
        for (final word in fuzzyList) {
          add(word);
          if (result.length >= limit) return result;
        }
      }
    }
    for (final entry in _entries) {
      if (result.length >= limit) break;
      if (entry.code.length <= buffer.length) continue;
      if (!entry.code.startsWith(buffer)) continue;
      add(entry.word);
    }
    if (result.length < limit && buffer.length >= 2) {
      for (final entry in _entries) {
        if (result.length >= limit) break;
        if (entry.initials != buffer) continue;
        add(entry.word);
      }
    }
    return result;
  }

  /// 九宫格候选：输入是数字串。
  List<String> t9Candidates(String digits, {int limit = 7}) {
    if (digits.isEmpty || limit <= 0) return const [];
    final result = <String>[];
    final exact = _t9[digits];
    if (exact != null) {
      for (final word in exact) {
        if (result.length >= limit) break;
        if (!result.contains(word)) result.add(word);
      }
    }
    if (result.length < limit) {
      for (final entry in _entries) {
        if (result.length >= limit) break;
        final code = _digitsOf(entry.code);
        if (code.length <= digits.length) continue;
        if (!code.startsWith(digits)) continue;
        if (!result.contains(entry.word)) result.add(entry.word);
      }
    }
    return result;
  }

  /// 整句切分：把拼音串按词库切成若干词，用词频做动态规划。
  String? _sentence(String buffer) {
    final n = buffer.length;
    const missing = -1e18;
    const unreachable = 1 << 30;
    // 先比“切成几个词”（越少越好），再比词频之和：没有语言模型时，
    // 这样能避免把「北京」拆成「被/及/嗯」这类更“高频”的碎字。
    final counts = List<int>.filled(n + 1, unreachable);
    final scores = List<double>.filled(n + 1, missing);
    final back = List<int>.filled(n + 1, -1);
    final words = List<String?>.filled(n + 1, null);
    counts[0] = 0;
    scores[0] = 0;
    for (var end = 1; end <= n; end++) {
      for (var start = 0; start < end; start++) {
        if (counts[start] == unreachable) continue;
        final seg = buffer.substring(start, end);
        if (!_readableAsSyllables(seg)) continue;
        final best = _top[seg];
        if (best == null) continue;
        final nextCount = counts[start] + 1;
        final nextScore = scores[start] + math.log(best.weight.toDouble() + 1);
        final better =
            nextCount < counts[end] ||
            (nextCount == counts[end] && nextScore > scores[end]);
        if (better) {
          counts[end] = nextCount;
          scores[end] = nextScore;
          back[end] = start;
          words[end] = best.word;
        }
      }
    }
    if (counts[n] == unreachable) return null;
    final parts = <String>[];
    var index = n;
    while (index > 0) {
      final word = words[index];
      if (word == null) return null;
      parts.insert(0, word);
      index = back[index];
    }
    return parts.join();
  }

  /// 这段字母能不能完整切成合法音节（防止把乱七八糟的串拼成句子）。
  bool _readableAsSyllables(String code) {
    if (code.isEmpty) return false;
    var index = 0;
    while (index < code.length) {
      var matched = 0;
      for (var len = math.min(6, code.length - index); len >= 1; len--) {
        if (_syllables.contains(code.substring(index, index + len))) {
          matched = len;
          break;
        }
      }
      if (matched == 0) return false;
      index += matched;
    }
    return true;
  }

  /// zh/z、ch/c、sh/s 视为同一类，用于模糊音匹配。
  String _fuzzyOf(String code) {
    var out = code;
    for (final pair in const [
      ['zh', 'z'],
      ['ch', 'c'],
      ['sh', 's'],
    ]) {
      out = out.replaceAll(pair[0], pair[1]);
    }
    return out;
  }

  /// 九宫格数字：abc→2，def→3，…，wxyz→9。
  String _digitsOf(String code) {
    final buffer = StringBuffer();
    for (final unit in code.codeUnits) {
      final letter = String.fromCharCode(unit);
      buffer.write(_t9Map[letter] ?? '');
    }
    return buffer.toString();
  }

  static const _t9Map = <String, String>{
    'a': '2',
    'b': '2',
    'c': '2',
    'd': '3',
    'e': '3',
    'f': '3',
    'g': '4',
    'h': '4',
    'i': '4',
    'j': '5',
    'k': '5',
    'l': '5',
    'm': '6',
    'n': '6',
    'o': '6',
    'p': '7',
    'q': '7',
    'r': '7',
    's': '7',
    't': '8',
    'u': '8',
    'v': '8',
    'w': '9',
    'x': '9',
    'y': '9',
    'z': '9',
  };
}

class _Entry {
  const _Entry(this.code, this.initials, this.word, this.weight);

  final String code;
  final String initials;
  final String word;
  final int weight;
}
