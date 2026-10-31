import 'dart:convert';
import 'dart:io';

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
    this.traditional = false,
    this.theme = 'light',
  });

  final int candidates;
  final bool traditional;
  final String theme;
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

  static String get _ini {
    final appData = Platform.environment['APPDATA'] ?? '';
    return appData + '\\HorseBox\\ime.ini';
  }

  static String get _learned {
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
      final f = File(_ini);
      if (!f.existsSync()) return const ImeWinConfig();
      final map = <String, String>{};
      for (final line in f.readAsLinesSync()) {
        final i = line.indexOf('=');
        if (i <= 0) continue;
        map[line.substring(0, i).trim()] = line.substring(i + 1).trim();
      }
      return ImeWinConfig(
        candidates: int.tryParse(map['candidates'] ?? '') ?? 6,
        traditional: (map['traditional'] ?? '0') == '1',
        theme: map['theme'] ?? 'light',
      );
    } catch (_) {
      return const ImeWinConfig();
    }
  }

  static Future<void> writeConfig(ImeWinConfig c) async {
    final f = File(_ini);
    await f.parent.create(recursive: true);
    final sb = StringBuffer()
      ..writeln('candidates=${c.candidates}')
      ..writeln('traditional=${c.traditional ? 1 : 0}')
      ..writeln('theme=${c.theme}');
    await f.writeAsString(sb.toString());
  }

  static Future<void> clearLearning() async {
    try {
      final f = File(_learned);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}
