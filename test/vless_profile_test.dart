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

    final config = jsonDecode(profile.toSingBoxConfigJson()) as Map<String, dynamic>;
    final outbound = (config['outbounds'] as List).first as Map<String, dynamic>;
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
}
