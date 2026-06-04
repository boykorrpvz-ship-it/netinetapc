import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/create_payment_result.dart';
import '../models/order_access.dart';
import '../models/subscription.dart';

class IronVpnApi {
  const IronVpnApi({
    this.baseUrl = AppConfig.apiBaseUrl,
    http.Client? client,
  }) : _client = client;

  final String baseUrl;
  final http.Client? _client;

  Future<CreatePaymentResult> createPayment({
    required String tariffKey,
    required String deviceName,
    required String contact,
  }) async {
    final response = await _postJson('/api/create-payment.php', {
      'tariffKey': tariffKey,
      'deviceName': deviceName,
      'contact': contact,
    });

    return CreatePaymentResult.fromJson(response);
  }

  Future<Subscription> fetchSubscription(OrderAccess access) async {
    final uri = Uri.parse('$baseUrl/api/order.php').replace(
      queryParameters: {
        'order': access.orderId,
        'token': access.accessToken,
      },
    );

    final response = await _send((client) => client.get(uri));
    return Subscription.pickPrimary(response);
  }

  Future<void> sendRecoveryEmail(String email) async {
    await _postJson('/api/recover.php', {'email': email});
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$baseUrl$path');
    return _send(
      (client) => client.post(
        uri,
        headers: {'Content-Type': 'application/json; charset=utf-8'},
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
      final response = await request(client).timeout(const Duration(seconds: 20));
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
