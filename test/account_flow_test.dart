import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ironvpn_mobile/models/subscription.dart';
import 'package:ironvpn_mobile/models/vpn_product.dart';
import 'package:ironvpn_mobile/services/ironvpn_api.dart';

void main() {
  test('login returns active purchases for both VPN products', () async {
    final future =
        DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
    final client = MockClient((request) async {
      expect(request.url.path, '/api/account-login.php');
      expect(request.method, 'POST');
      return http.Response(
        jsonEncode({
          'account': {'email': 'user@example.com'},
          'token': 'account-session-token',
          'tokenExpiresMs': future,
          'orders': [
            {
              'orderId': 'vless-order',
              'accessToken': 'vless-access',
              'status': 'fulfilled',
              'active': true,
              'vpnType': 'vless',
              'tariffName': '1 месяц',
              'deviceName': 'Android',
              'expiresMs': future,
              'vpnLink': 'https://netineta.com/sub/test',
              'subscriptionUrl': 'https://netineta.com/sub/test',
              'directVpnLink': 'vless://test',
            },
            {
              'orderId': 'awg-order',
              'accessToken': 'awg-access',
              'status': 'fulfilled',
              'active': true,
              'vpnType': 'amneziawg',
              'tariffName': '3 месяца',
              'deviceName': 'Android',
              'expiresMs': future,
              'vpnConfig': '[Interface]\nPrivateKey = test',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final api = IronVpnApi(baseUrl: 'https://example.test', client: client);
    final snapshot =
        await api.login(email: 'user@example.com', password: 'password');

    expect(snapshot.email, 'user@example.com');
    expect(snapshot.token, 'account-session-token');
    expect(snapshot.activeFor(VpnProduct.vless)?.accessToken, 'vless-access');
    expect(snapshot.activeFor(VpnProduct.vless)?.accessPayload, 'vless://test');
    expect(
      snapshot.activeFor(VpnProduct.amneziaWg)?.accessToken,
      'awg-access',
    );
  });

  test('trial is active only before exact expiry time', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final active = Subscription.fromJson({
      'orderId': 'trial-active',
      'accessToken': 'trial-token',
      'status': 'fulfilled',
      'active': true,
      'trial': true,
      'vpnType': 'vless',
      'tariffName': 'Пробный доступ',
      'deviceName': 'Android',
      'expiresMs': now + 60000,
      'vpnLink': 'vless://trial',
    });
    final expired = Subscription.fromJson({
      'orderId': 'trial-expired',
      'accessToken': 'trial-token',
      'status': 'fulfilled',
      'active': false,
      'trial': true,
      'vpnType': 'vless',
      'tariffName': 'Пробный доступ',
      'deviceName': 'Android',
      'expiresMs': now - 60000,
      'vpnLink': 'vless://trial',
    });

    expect(active.isTrial, isTrue);
    expect(active.isActive, isTrue);
    expect(expired.isActive, isFalse);
  });

  test('password reset requests a code and returns an account session',
      () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount += 1;
      final payload = jsonDecode(request.body) as Map<String, dynamic>;

      if (request.url.path == '/api/account-reset-request.php') {
        expect(payload['email'], 'user@example.com');
        return http.Response(
          jsonEncode({'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      expect(request.url.path, '/api/account-reset.php');
      expect(payload, {
        'email': 'user@example.com',
        'password': 'new-password',
        'code': '123456',
      });
      return http.Response(
        jsonEncode({
          'account': {'email': 'user@example.com'},
          'token': 'new-session-token',
          'orders': <Map<String, dynamic>>[],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final api = IronVpnApi(baseUrl: 'https://example.test', client: client);
    await api.requestPasswordReset('user@example.com');
    final snapshot = await api.resetPassword(
      email: 'user@example.com',
      password: 'new-password',
      code: '123456',
    );

    expect(requestCount, 2);
    expect(snapshot.email, 'user@example.com');
    expect(snapshot.token, 'new-session-token');
  });
}
