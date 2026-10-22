import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

void main() {
  const raw = '''
{
  "log": {"level": "info"},
  "dns": {
    "servers": [
      {"type": "local", "tag": "dns-direct"},
      {"type": "https", "tag": "dns-proxy", "server": "1.1.1.1"}
    ],
    "final": "dns-proxy",
    "rules": []
  },
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "mtu": 9000, "auto_route": true, "strict_route": true, "stack": "mixed"},
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080}
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"rules": [], "final": "direct", "default_domain_resolver": "dns-direct"},
  "experimental": {"cache_file": {"enabled": true}}
}
''';

  test('配置补丁写入端口、Clash API、DNS 与 hosts', () {
    final text = patchClientConfig(
      raw,
      const ClientConfigOptions(
        mixedPort: 7890,
        clashPort: 19090,
        enableTun: true,
        tunStack: 'gvisor',
        tunMtu: 1400,
        dnsMode: 'custom',
        dnsServers: ['223.5.5.5', 'https://dns.alidns.com/dns-query'],
        hosts: {
          'nas.home': ['192.168.1.10'],
        },
      ),
    );
    final cfg = jsonDecode(text) as Map<String, dynamic>;

    expect(cfg['experimental']['cache_file']['enabled'], isFalse);
    expect(
      cfg['experimental']['clash_api']['external_controller'],
      '127.0.0.1:19090',
    );

    final inbounds = (cfg['inbounds'] as List).cast<Map>();
    final tun = inbounds.firstWhere((item) => item['type'] == 'tun');
    expect(tun['stack'], 'gvisor');
    expect(tun['mtu'], 1400);
    final mixed = inbounds.firstWhere((item) => item['type'] == 'mixed');
    expect(mixed['listen_port'], 7890);
    expect(mixed['listen'], '127.0.0.1');

    final dns = cfg['dns'] as Map;
    expect(dns['final'], 'horsebox-dns-0');
    final servers = (dns['servers'] as List).cast<Map>();
    expect(
      servers.any(
        (item) =>
            item['tag'] == 'horsebox-dns-0' && item['server'] == '223.5.5.5',
      ),
      isTrue,
    );
    expect(servers.any((item) => item['tag'] == 'horsebox-hosts'), isTrue);
    final rules = (dns['rules'] as List).cast<Map>();
    expect(rules.first['server'], 'horsebox-hosts');
  });

  test('关闭 TUN 后只保留 mixed 入站', () {
    final text = patchClientConfig(
      raw,
      const ClientConfigOptions(
        mixedPort: 7891,
        clashPort: 19091,
        enableTun: false,
      ),
    );
    final cfg = jsonDecode(text) as Map<String, dynamic>;
    final inbounds = (cfg['inbounds'] as List).cast<Map>();
    expect(inbounds.any((item) => item['type'] == 'tun'), isFalse);
    expect(inbounds.any((item) => item['type'] == 'mixed'), isTrue);
  });

  test('关闭 IPv6 后不写 AAAA，并去掉 TUN 的 IPv6 地址', () {
    final text = patchClientConfig(
      raw,
      const ClientConfigOptions(
        mixedPort: 7892,
        clashPort: 19092,
        enableIpv6: false,
      ),
    );
    final cfg = jsonDecode(text) as Map<String, dynamic>;
    expect((cfg['dns'] as Map)['strategy'], 'ipv4_only');
    final tun = (cfg['inbounds'] as List).cast<Map>().firstWhere(
      (item) => item['type'] == 'tun',
    );
    expect(
      (tun['address'] as List).whereType<String>().any(
        (item) => item.contains(':'),
      ),
      isFalse,
    );
  });

  test('多节点生成自动组和手动选择组', () {
    const multi = '''
{
  "dns": {"servers": [{"type": "local", "tag": "dns-direct"}], "final": "dns-direct", "rules": []},
  "inbounds": [],
  "outbounds": [
    {"type": "shadowsocks", "tag": "香港01", "server": "1.1.1.1", "server_port": 443},
    {"type": "shadowsocks", "tag": "日本01", "server": "2.2.2.2", "server_port": 443},
    {"type": "urltest", "tag": "proxy", "outbounds": ["香港01", "日本01"], "url": "http://www.gstatic.com/generate_204"},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [], "final": "proxy"},
  "experimental": {}
}
''';
    final text = patchClientConfig(
      multi,
      const ClientConfigOptions(
        mixedPort: 7890,
        clashPort: 19090,
        selectedNode: '日本01',
      ),
    );
    final cfg = jsonDecode(text) as Map<String, dynamic>;
    final outbounds = (cfg['outbounds'] as List).cast<Map>();
    final auto = outbounds.firstWhere((item) => item['tag'] == 'auto');
    final selector = outbounds.firstWhere((item) => item['tag'] == 'proxy');
    expect(auto['type'], 'urltest');
    expect(selector['type'], 'selector');
    expect(selector['default'], '日本01');
    expect(selector['outbounds'], contains('auto'));
    expect(selector['outbounds'], contains('日本01'));
  });

  test('内置中国直连和自定义规则写入 route', () {
    final text = patchClientConfig(
      raw,
      const ClientConfigOptions(
        mixedPort: 7890,
        clashPort: 19090,
        rulesDir: '/data/rules',
        customRules: [
          RouteRuleSetting(
            type: 'domain_suffix',
            value: 'example.com',
            outbound: 'proxy',
          ),
        ],
      ),
    );
    final cfg = jsonDecode(text) as Map<String, dynamic>;
    final route = cfg['route'] as Map;
    final sets = (route['rule_set'] as List).cast<Map>();
    expect(sets.any((item) => item['tag'] == 'geosite-cn'), isTrue);
    expect(sets.any((item) => item['tag'] == 'geoip-cn'), isTrue);
    final rules = (route['rules'] as List).cast<Map>();
    expect(
      rules.any(
        (item) => item['domain_suffix'] != null && item['outbound'] == 'proxy',
      ),
      isTrue,
    );
    expect(
      rules.any(
        (item) =>
            (item['rule_set'] as List?)?.contains('geosite-cn') == true &&
            item['outbound'] == 'direct',
      ),
      isTrue,
    );
  });

  test('自定义 DNS 使用非空直连出站', () {
    final text = patchClientConfig(
      raw,
      const ClientConfigOptions(
        mixedPort: 7890,
        clashPort: 19090,
        dnsMode: 'custom',
        dnsServers: ['223.5.5.5'],
      ),
    );
    final cfg = jsonDecode(text) as Map<String, dynamic>;
    final outbounds = (cfg['outbounds'] as List).cast<Map>();
    expect(
      outbounds.any((item) => item['tag'] == 'horsebox-dns-direct'),
      isTrue,
    );
    final dns = cfg['dns'] as Map;
    final server = (dns['servers'] as List).cast<Map>().firstWhere(
      (item) => item['tag'] == 'horsebox-dns-0',
    );
    expect(server['detour'], 'horsebox-dns-direct');
  });

  test('Windows 国内域名走系统 DNS 并启用 resolve', () {
    final text = patchClientConfig(
      raw,
      const ClientConfigOptions(
        mixedPort: 7890,
        clashPort: 19090,
        rulesDir: '/data/rules',
        dnsCnDirect: true,
      ),
    );
    final cfg = jsonDecode(text) as Map<String, dynamic>;
    final dns = cfg['dns'] as Map;
    expect(dns['final'], 'dns-proxy');
    final dnsRules = (dns['rules'] as List).cast<Map>();
    expect(
      dnsRules.any(
        (item) =>
            (item['rule_set'] as List?)?.contains('geosite-cn') == true &&
            item['server'] == 'dns-direct',
      ),
      isTrue,
    );
    final route = cfg['route'] as Map;
    final rules = (route['rules'] as List).cast<Map>();
    expect(rules.any((item) => item['action'] == 'resolve'), isTrue);
  });

  test('Google 下载域名强制走代理且优先于国内直连', () {
    final withProxy = raw.replaceFirst(
      '"outbounds": [{"type": "direct", "tag": "direct"}]',
      '"outbounds": [{"type": "shadowsocks", "tag": "proxy", "server": "1.1.1.1", "server_port": 8388, "method": "aes-128-gcm", "password": "x"}, {"type": "direct", "tag": "direct"}]',
    );
    final text = patchClientConfig(
      withProxy,
      const ClientConfigOptions(
        mixedPort: 7890,
        clashPort: 19090,
        rulesDir: '/data/rules',
      ),
    );
    final cfg = jsonDecode(text) as Map<String, dynamic>;
    final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();
    final googleIndex = rules.indexWhere(
      (item) => (item['domain_suffix'] as List?)?.contains('gvt1.com') == true,
    );
    final cnIndex = rules.indexWhere(
      (item) => (item['rule_set'] as List?)?.contains('geosite-cn') == true,
    );
    expect(googleIndex, greaterThanOrEqualTo(0));
    expect(cnIndex, greaterThan(googleIndex));
    expect(rules[googleIndex]['outbound'], 'proxy');

    final ipIndex = rules.indexWhere(
      (item) => (item['ip_cidr'] as List?)?.contains('142.250.0.0/15') == true,
    );
    expect(ipIndex, greaterThanOrEqualTo(0));
    expect(cnIndex, greaterThan(ipIndex));
    expect(rules[ipIndex]['outbound'], 'proxy');
  });

  test('system 栈回落到 mixed', () {
    expect(normalizeTunStack('system'), 'mixed');
    expect(normalizeTunStack('gvisor'), 'gvisor');
    expect(normalizeTunStack(null), 'mixed');
  });

  test('裸 IPv6 自动补方括号', () {
    expect(normalizeDnsServer('2400:3200::1'), '[2400:3200::1]');
    expect(normalizeDnsServer('udp://2400:3200::1'), 'udp://[2400:3200::1]');
    expect(
      normalizeDnsServer('https://dns.alidns.com/dns-query'),
      'https://dns.alidns.com/dns-query',
    );
  });
}
