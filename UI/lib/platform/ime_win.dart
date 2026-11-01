import 'dart:convert';
import 'dart:io';

import '../security/dpapi.dart';
import '../utils/app_paths.dart';

/// Windows 系统输入法（TSF）的状态。
class ImeWinStatus {
  const ImeWinStatus({
    required this.packaged,
    required this.registered,
    required this.enabled,
  });

  final bool packaged;
  final bool registered;
  final bool enabled;

  static const unavailable =
      ImeWinStatus(packaged: false, registered: false, enabled: false);
}

/// Windows 输入法的选项（写到 %APPDATA%\\HorseBox\\ime.ini，由 TSF DLL 读取）。
class ImeWinConfig {
  const ImeWinConfig({
    this.candidates = 6,
    this.fuzzy = true,
    this.sentence = true,
    this.learn = true,
    this.traditional = false,
    this.english = false,
    this.theme = 'light',
    this.accent = 0xFF0078D7,
    this.palette = false,
    this.bg = 0xFF1B1C1E,
    this.fg = 0xFFEDEDEF,
    this.border = 0xFF5A5A5A,
  });

  final int candidates;

  /// 模糊音：zh/z、ch/c、sh/s 等近似拼音也算命中。
  final bool fuzzy;

  /// 句子模式：长串拼音整句断词，而不是一个字一个字凑。
  final bool sentence;

  /// 词频记忆：记住选过的词。
  final bool learn;

  /// 繁体：开启后候选和上屏都转成繁体（和简/英切换无关）。
  final bool traditional;

  /// 英文联想：英文模式下也弹候选框；关掉则字母直接进输入框。
  final bool english;

  /// 候选窗明暗：light / dark / system（跟随 Windows 应用模式）。
  final String theme;

  /// 选中候选的高亮色（ARGB）。
  final int accent;

  /// 打开后忽略明暗，直接用下面的三色。
  final bool palette;

  final int bg;
  final int fg;
  final int border;

  ImeWinConfig copyWith({
    int? candidates,
    bool? fuzzy,
    bool? sentence,
    bool? learn,
    bool? traditional,
    bool? english,
    String? theme,
    int? accent,
    bool? palette,
    int? bg,
    int? fg,
    int? border,
  }) =>
      ImeWinConfig(
        candidates: candidates ?? this.candidates,
        fuzzy: fuzzy ?? this.fuzzy,
        sentence: sentence ?? this.sentence,
        learn: learn ?? this.learn,
        traditional: traditional ?? this.traditional,
        english: english ?? this.english,
        theme: theme ?? this.theme,
        accent: accent ?? this.accent,
        palette: palette ?? this.palette,
        bg: bg ?? this.bg,
        fg: fg ?? this.fg,
        border: border ?? this.border,
      );
}

/// 输入法词频记忆的规模：单字几条、词语几条。
class ImeLearnStats {
  const ImeLearnStats({this.chars = 0, this.words = 0});

  final int chars;
  final int words;

  int get total => chars + words;
}

/// Windows 输入法的安装/启停。安装、卸载需要管理员（内部用 UAC 提权）。
class ImeWin {
  ImeWin._();

  static bool get supported => Platform.isWindows;

  static String get _imeDir {
    final dir = File(Platform.resolvedExecutable).parent.path;
    return dir + '\\ime';
  }

  static String get _dll => _imeDir + '\\horsebox-ime.dll';
  static String get _ctl => _imeDir + '\\horsebox-imectl.exe';

  /// 和 App 的数据目录保持一致：改过目录就跟着走，不再写死 %APPDATA%\HorseBox
  static String get _baseDir => windowsDataDirSync();

  static String get _ini => _baseDir + '\\ime.ini';

  /// 老版本把配置写在默认目录，仅供清理时一并删掉
  static String get _legacyIni {
    final appData = Platform.environment['APPDATA'] ?? '';
    return appData + '\\HorseBox\\ime.ini';
  }

  static String get _learned => _baseDir + '\\ime_learned.txt';

  static String get _legacyLearned {
    final appData = Platform.environment['APPDATA'] ?? '';
    return appData + '\\HorseBox\\ime_learned.txt';
  }

  static bool get packaged =>
      supported && File(_dll).existsSync() && File(_ctl).existsSync();

  static Future<ImeWinStatus> status() async {
    if (!supported) return ImeWinStatus.unavailable;
    if (!packaged) {
      return const ImeWinStatus(packaged: false, registered: false, enabled: false);
    }
    try {
      final r = await Process.run(_ctl, ['status'], stdoutEncoding: utf8, stderrEncoding: utf8);
      final out = r.stdout.toString();
      final reg = RegExp(r'registered=(\d)').firstMatch(out)?.group(1) == '1';
      final en = RegExp(r'enabled=(\d)').firstMatch(out)?.group(1) == '1';
      return ImeWinStatus(packaged: true, registered: reg, enabled: en);
    } catch (_) {
      return const ImeWinStatus(packaged: true, registered: false, enabled: false);
    }
  }

  static const _tip =
      '0804:{6C1F0A3E-9A2B-4C77-8E31-2F5C4B7D9A10}{3F1A7B2C-5D4E-4A6B-9C21-7E8D4F0A5B6C}';

  static Future<bool> install() async {
    final ok = await _elevated(['install', _dll]);
    await _addToUserList();
    return ok;
  }

  static Future<bool> uninstall() async {
    await _removeFromUserList();
    return _elevated(['uninstall', _dll]);
  }

  static Future<bool> enable() => _addToUserList();
  static Future<bool> disable() => _removeFromUserList();

  // AddLanguageProfile 在本机是 no-op，用官方 cmdlet 真正写入用户输入法列表。
  static Future<bool> _addToUserList() async {
    final script = r"$tip='" + _tip + r"'; $l=Get-WinUserLanguageList; "
        r"$z=$l|Where-Object {$_.LanguageTag -eq 'zh-Hans-CN'}; "
        r"if(-not($z.InputMethodTips -contains $tip)){$z.InputMethodTips.Add($tip)}; "
        r"Set-WinUserLanguageList -LanguageList $l -Force";
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-Command', script]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _removeFromUserList() async {
    final script = r"$tip='" + _tip + r"'; $l=Get-WinUserLanguageList; "
        r"$z=$l|Where-Object {$_.LanguageTag -eq 'zh-Hans-CN'}; "
        r"$z.InputMethodTips.Remove($tip); "
        r"Set-WinUserLanguageList -LanguageList $l -Force";
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-Command', script]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _elevated(List<String> args) async {
    final quoted = args.map((a) => "'" + a.replaceAll("'", "''") + "'").join(',');
    final ps = "Start-Process -FilePath '" +
        _ctl +
        "' -ArgumentList " +
        quoted +
        ' -Verb RunAs -Wait';
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-Command', ps]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openLanguageSettings() async {
    if (!supported) return;
    try {
      await Process.run('cmd', ['/c', 'start', '', 'ms-settings:regionlanguage']);
    } catch (_) {}
  }

  static ImeWinConfig readConfig() {
    try {
      // 改过数据目录时，新位置还没有就回退读默认目录里的老配置
      var f = File(_ini);
      if (!f.existsSync() && _legacyIni != _ini) {
        final legacy = File(_legacyIni);
        if (legacy.existsSync()) f = legacy;
      }
      if (!f.existsSync()) return const ImeWinConfig();
      final map = <String, String>{};
      for (final line in f.readAsLinesSync()) {
        final i = line.indexOf('=');
        if (i <= 0) continue;
        map[line.substring(0, i).trim()] = line.substring(i + 1).trim();
      }
      int hex(String key, int fallback) {
        final raw = (map[key] ?? '').replaceAll('#', '').trim();
        final value = int.tryParse(raw, radix: 16);
        if (value == null) return fallback;
        return raw.length <= 6 ? (0xFF000000 | value) : value;
      }

      final theme = switch (map['theme']) {
        'dark' => 'dark',
        'system' => 'system',
        _ => 'light',
      };
      return ImeWinConfig(
        candidates: int.tryParse(map['candidates'] ?? '') ?? 6,
        fuzzy: (map['fuzzy'] ?? '1') == '1',
        sentence: (map['sentence'] ?? '1') == '1',
        learn: (map['learn'] ?? '1') == '1',
        traditional: (map['traditional'] ?? '0') == '1',
        english: (map['english'] ?? '0') == '1',
        theme: theme,
        accent: hex('accent', 0xFF0078D7),
        palette: (map['palette'] ?? '0') == '1',
        bg: hex('bg', 0xFF1B1C1E),
        fg: hex('fg', 0xFFEDEDEF),
        border: hex('border', 0xFF5A5A5A),
      );
    } catch (_) {
      return const ImeWinConfig();
    }
  }

  static Future<void> writeConfig(ImeWinConfig c) async {
    final f = File(_ini);
    await f.parent.create(recursive: true);
    String hex(int argb) =>
        argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    final sb = StringBuffer()
      ..writeln('candidates=${c.candidates}')
      ..writeln('fuzzy=${c.fuzzy ? 1 : 0}')
      ..writeln('sentence=${c.sentence ? 1 : 0}')
      ..writeln('learn=${c.learn ? 1 : 0}')
      ..writeln('traditional=${c.traditional ? 1 : 0}')
      ..writeln('english=${c.english ? 1 : 0}')
      ..writeln('theme=${c.theme}')
      ..writeln('accent=${hex(c.accent)}')
      ..writeln('palette=${c.palette ? 1 : 0}')
      ..writeln('bg=${hex(c.bg)}')
      ..writeln('fg=${hex(c.fg)}')
      ..writeln('border=${hex(c.border)}');
    await f.writeAsString(sb.toString());
  }

  /// 读 ime_learned.txt（DPAPI 密文）统计学会了多少字、多少词。
  static Future<ImeLearnStats> learningStats() async {
    if (!Dpapi.supported) return const ImeLearnStats();
    try {
      var file = File(_learned);
      if (!file.existsSync() && _legacyLearned != _learned) {
        file = File(_legacyLearned);
      }
      if (!file.existsSync()) return const ImeLearnStats();
      final plain = Dpapi.unprotect(await file.readAsBytes());
      if (plain == null) return const ImeLearnStats();
      var chars = 0;
      var words = 0;
      for (final line in utf8.decode(plain, allowMalformed: true).split('\n')) {
        final parts = line.split('\t');
        if (parts.length < 2) continue;
        final word = parts[1];
        if (word.isEmpty) continue;
        // 一个字符算单字，两个及以上算词语
        if (word.runes.length == 1) {
          chars++;
        } else {
          words++;
        }
      }
      return ImeLearnStats(chars: chars, words: words);
    } catch (_) {
      return const ImeLearnStats();
    }
  }

  /// 写盘后让 imectl 确认一遍：输入法会在下一次按键时读到新配置。
  static Future<bool> applyNow(ImeWinConfig c) async {
    await writeConfig(c);
    if (!packaged) return false;
    try {
      final r = await Process.run(
        _ctl,
        ['status'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 5));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearLearning() async {
    for (final path in {_learned, _legacyLearned}) {
      try {
        final f = File(path);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
  }
}
