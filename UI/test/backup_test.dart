import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:horsebox/security/data_backup.dart';
import 'package:path/path.dart' as p;

void main() {
  test('备份可以导出、校验、恢复', () async {
    final root = await Directory.systemTemp.createTemp('hb_backup_');
    final dataDir = p.join(root.path, 'data');
    await Directory(dataDir).create(recursive: true);
    await File(p.join(dataDir, 'settings.json')).writeAsString(
      jsonEncode({
        'profiles': [
          {'id': '1'},
          {'id': '2'},
        ],
        'ssh_hosts': [
          {'id': 'h1'},
        ],
        'panel_credentials': [],
        'theme_mode': 'light',
        'accent': 0xFF3B82F6,
        'ime_chinese': true,
        'ime_layout': 'nine',
        'ime_fuzzy': false,
        'ime_sentence': true,
        'ime_global': true,
      }),
    );
    final keyBytes = List<int>.generate(32, (i) => i);
    await File(p.join(dataDir, 'secret.key'))
        .writeAsString(base64Encode(keyBytes));
    await Directory(p.join(dataDir, 'rules')).create(recursive: true);
    await File(p.join(dataDir, 'rules', 'a.srs')).writeAsString('rule');
    await File(p.join(dataDir, 'ime_learned.txt')).writeAsString('ni	你	8');

    final bytes = await BackupService.export(
      dataDir: dataDir,
      passphrase: 'pass12345',
    );
    final payload = await BackupService.inspect(
      bytes: bytes,
      passphrase: 'pass12345',
    );
    expect(payload.profiles, 2);
    expect(payload.sshHosts, 1);
    expect(payload.files.containsKey('rules/a.srs'), isTrue);
    // 整个数据目录都要进包，不只是 settings.json + rules
    expect(payload.files.containsKey('ime_learned.txt'), isTrue);
    // 4.2 之后新增的偏好也要能在备份清单里看到
    expect(payload.themeMode, 'light');
    expect(payload.accent, 0xFF3B82F6);
    expect(payload.imeChinese, isTrue);
    expect(payload.imeNine, isTrue);
    expect(payload.imeFuzzy, isFalse);
    expect(payload.imeGlobal, isTrue);

    await expectLater(
      BackupService.inspect(bytes: bytes, passphrase: 'wrongpass'),
      throwsA(isA<BackupException>()),
    );

    final backupDir = await BackupService.apply(
      dataDir: dataDir,
      payload: payload,
    );
    expect(Directory(backupDir).existsSync(), isTrue);
    final restored = jsonDecode(
      await File(p.join(dataDir, 'settings.json')).readAsString(),
    );
    expect((restored as Map)['profiles'], hasLength(2));
    expect(
      await File(p.join(dataDir, 'rules', 'a.srs')).readAsString(),
      'rule',
    );

    final second = await BackupService.apply(
      dataDir: dataDir,
      payload: payload,
    );
    expect(Directory(second).existsSync(), isTrue);

    await root.delete(recursive: true);
  });
}
