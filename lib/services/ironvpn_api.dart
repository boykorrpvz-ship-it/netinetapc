import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/account_snapshot.dart';
import '../models/create_payment_result.dart';
import '../models/order_access.dart';
import '../models/subscription.dart';
import '../models/vpn_product.dart';

class IronVpnApi {
  const IronVpnApi({
    this.baseUrl = AppConfig.apiBaseUrl,
    http.Client? client,
  }) : _client = client;

  final String baseUrl;
  final http.Client? _client;

  Future<AccountSnapshot> login({
    required String email,
    required String password,
  }) async {
    final response = await _postJson('/api/account-login.php', {
      'email': email,
      'password': password,
    });
    return AccountSnapshot.fromJson(response);
  }

  Future<void> requestPasswordReset(String email) async {
    await _postJson('/api/account-reset-request.php', {
      'email': email,
    });
  }

  Future<AccountSnapshot> resetPassword({
    required String email,
    required String password,
    required String code,
  }) async {
    final response = await _postJson('/api/account-reset.php', {
      'email': email,
      'password': password,
      'code': code,
    });
    return AccountSnapshot.fromJson(response);
  }

  Future<AccountSnapshot> fetchAccount(String token) async {
    final uri = Uri.parse('$baseUrl/api/account.php');
    final response = await _send(
      (client) => client.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'X-IronVPN-Token': token,
        },
      ),
    );
    return AccountSnapshot.fromJson(response);
  }

  Future<Subscription> claimTrial({
    required String installId,
    required String deviceName,
  }) async {
    final response = await _postJson('/api/app-trial.php', {
      'installId': installId,
      'deviceName': deviceName,
    });
    return Subscription.fromJson(response);
  }

  Future<CreatePaymentResult> createPayment({
    required VpnProduct product,
    required String tariffKey,
    required String deviceName,
    required String contact,
    String? accountToken,
  }) async {
    final response = await _postJson(
      '/api/create-payment.php',
      {
        'vpnType': product.apiValue,
        'tariffKey': tariffKey,
        'deviceName': deviceName,
        'contact': contact,
      },
      token: accountToken,
    );

    return CreatePaymentResult.fromJson(response, product: product);
  }

  Future<Subscription> fetchSubscription(OrderAccess access) async {
    final uri = Uri.parse('$baseUrl/api/order.php').replace(
      queryParameters: {
        'order': access.orderId,
        'token': access.accessToken,
      },
    );

    final response = await _send((client) => client.get(uri));
    return Subscription.pickPrimary(response, product: access.product);
  }

  Future<Subscription> fetchOrderDirect(OrderAccess access) async {
    final uri = Uri.parse('$baseUrl/api/order.php').replace(
      queryParameters: {
        'order': access.orderId,
        'token': access.accessToken,
      },
    );

    final response = await _send((client) => client.get(uri));
    return Subscription.fromJson(response);
  }

  Future<CreatePaymentResult> createRenewalPayment({
    required OrderAccess access,
    required String tariffKey,
  }) async {
    final response = await _postJson('/api/renew-payment.php', {
      'order': access.orderId,
      'token': access.accessToken,
      'targetOrder': access.orderId,
      'tariffKey': tariffKey,
      'vpnType': access.product.apiValue,
    });

    return CreatePaymentResult.fromJson(response, product: access.product);
  }

  Future<Subscription> refreshConfig(OrderAccess access) async {
    final response = await _postJson('/api/refresh-config.php', {
      'order': access.orderId,
      'token': access.accessToken,
      'vpnType': access.product.apiValue,
    });

    return Subscription.pickPrimary(response, product: access.product);
  }

  Future<void> sendRecoveryEmail(String email) async {
    await _postJson('/api/recover.php', {'email': email});
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload, {
    String? token,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    return _send(
      (client) => client.post(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          if (token != null && token.isNotEmpty)
            'Authorization': 'Bearer $token',
          if (token != null && token.isNotEmpty) 'X-IronVPN-Token': token,
        },
        body: jsonEncode(payload),
      ),
    );
  }

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function(http.Client client) request,
  ) async {
    final ownedClient = _client == null;
    final client = _client ?? http.Client();

    try {
      final response =
          await request(client).timeout(const Duration(seconds: 20));
      final decoded = jsonDecode(response.body);
      final data = decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = data['error'] as String? ?? 'Ошибка сервера';
        throw IronVpnApiException(message, response.statusCode);
      }

      return data;
    } on IronVpnApiException {
      rethrow;
    } catch (_) {
      throw const IronVpnApiException('Не удалось связаться с сервером', 0);
    } finally {
      if (ownedClient) {
        client.close();
      }
    }
  }
}

class IronVpnApiException implements Exception {
  const IronVpnApiException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}
