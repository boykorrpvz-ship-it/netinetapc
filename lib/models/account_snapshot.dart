import 'subscription.dart';
import 'vpn_product.dart';

class AccountSnapshot {
  const AccountSnapshot({
    required this.email,
    required this.orders,
    required this.token,
    required this.tokenExpiresMs,
  });

  final String email;
  final List<Subscription> orders;
  final String? token;
  final int? tokenExpiresMs;

  factory AccountSnapshot.fromJson(Map<String, dynamic> json) {
    final account = json['account'];
    final accountMap = account is Map
        ? Map<String, dynamic>.from(account)
        : const <String, dynamic>{};
    final rawOrders = json['orders'];
    final orders = rawOrders is List
        ? rawOrders
            .whereType<Map>()
            .map((item) =>
                Subscription.fromJson(Map<String, dynamic>.from(item)))
            .toList()
        : <Subscription>[];

    return AccountSnapshot(
      email: accountMap['email'] as String? ?? '',
      orders: orders,
      token: json['token'] as String?,
      tokenExpiresMs: (json['tokenExpiresMs'] as num?)?.toInt(),
    );
  }

  Subscription? activeFor(VpnProduct product) {
    for (final order in orders) {
      if (order.product == product && order.isActive) {
        return order;
      }
    }
    return null;
  }
}
