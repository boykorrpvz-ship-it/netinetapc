import 'vpn_product.dart';

class OrderAccess {
  const OrderAccess({
    required this.orderId,
    required this.accessToken,
    required this.product,
  });

  final String orderId;
  final String accessToken;
  final VpnProduct product;

  factory OrderAccess.fromJson(Map<String, dynamic> json) {
    return OrderAccess(
      orderId: json['orderId'] as String,
      accessToken: json['accessToken'] as String,
      product: VpnProduct.fromApi(json['vpnType']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'orderId': orderId,
      'accessToken': accessToken,
      'vpnType': product.apiValue,
    };
  }

  static OrderAccess? fromUri(Uri uri) {
    final order =
        uri.queryParameters['order'] ?? uri.queryParameters['orderId'];
    final token =
        uri.queryParameters['token'] ?? uri.queryParameters['accessToken'];
    final product = VpnProduct.fromApi(uri.queryParameters['vpnType']);

    if (order == null || token == null || order.isEmpty || token.isEmpty) {
      return null;
    }

    return OrderAccess(orderId: order, accessToken: token, product: product);
  }

  OrderAccess copyWith({
    String? orderId,
    String? accessToken,
    VpnProduct? product,
  }) {
    return OrderAccess(
      orderId: orderId ?? this.orderId,
      accessToken: accessToken ?? this.accessToken,
      product: product ?? this.product,
    );
  }
}
