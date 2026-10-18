import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 把内置的中国分流规则释放到数据目录，供 sing-box 以 local rule_set 读取。
Future<String> ensureCnRuleSets(String dataDir) async {
  final dir = Directory(p.join(dataDir, 'rules'));
  await dir.create(recursive: true);
  for (final name in const ['geosite-cn.srs', 'geoip-cn.srs']) {
    final data = await rootBundle.load('assets/rules/$name');
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }
  return dir.path;
}
