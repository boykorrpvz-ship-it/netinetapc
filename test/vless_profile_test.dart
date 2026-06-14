import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironvpn_mobile/models/vless_profile.dart';

void main() {
  test('parses VLESS Reality link and creates sing-box config', () {
    final profile = VlessProfile.parse(
      'vless://11111111-2222-3333-4444-555555555555@example.com:8443'
      '?type=tcp&encryption=none&security=reality'
      '&pbk=public-key&fp=chrome&sni=www.icloud.com&sid=abcd'
      '&spx=%2F&flow=xtls-rprx-vision#IronVPN',
    );

    expect(profile.name, 'IronVPN');
    expect(profile.uuid, '11111111-2222-3333-4444-555555555555');
    expect(profile.host, 'example.com');
    expect(profile.port, 8443);
    expect(profile.sni, 'www.icloud.com');

    final config =
        jsonDecode(profile.toSingBoxConfigJson()) as Map<String, dynamic>;
    final outbound =
        (config['outbounds'] as List).first as Map<String, dynamic>;
    final route = config['route'] as Map<String, dynamic>;
    final rules = route['rules'] as List<dynamic>;
    final dnsRule = rules.first as Map<String, dynamic>;

    expect(outbound['type'], 'vless');
    expect(outbound['server'], 'example.com');
    expect(outbound['server_port'], 8443);
    expect(outbound['uuid'], profile.uuid);
    expect(dnsRule['protocol'], 'dns');
    expect(dnsRule['action'], 'hijack-dns');
  });

  test('parses VLESS WebSocket TLS link and creates transport config', () {
    final profile = VlessProfile.parse(
      'vless://11111111-2222-3333-4444-555555555555@157-22-172-133.sslip.io:443'
      '?type=ws&encryption=none&security=tls&path=%2Fironvpn-ws'
      '&fp=chrome&sni=157-22-172-133.sslip.io&alpn=http%2F1.1#IronVPN',
    );

    expect(profile.type, 'ws');
    expect(profile.security, 'tls');
    expect(profile.transportPath, '/ironvpn-ws');
    expect(profile.alpn, 'http/1.1');
    expect(profile.flow, isEmpty);

    final config =
        jsonDecode(profile.toSingBoxConfigJson()) as Map<String, dynamic>;
    final outbound =
        (config['outbounds'] as List).first as Map<String, dynamic>;
    final tls = outbound['tls'] as Map<String, dynamic>;
    final transport = outbound['transport'] as Map<String, dynamic>;

    expect(outbound['server'], '157.22.172.133');
    expect(outbound['server_port'], 443);
    expect(outbound.containsKey('flow'), isFalse);
    expect(tls['enabled'], true);
    expect(tls['server_name'], '157-22-172-133.sslip.io');
    expect(tls['alpn'], ['http/1.1']);
    expect(tls.containsKey('reality'), isFalse);
    expect(transport['type'], 'ws');
    expect(transport['path'], '/ironvpn-ws');
  });
}
