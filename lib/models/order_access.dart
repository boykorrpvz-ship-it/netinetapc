class OrderAccess {
  const OrderAccess({
    required this.orderId,
    required this.accessToken,
  });

  final String orderId;
  final String accessToken;

  factory OrderAccess.fromJson(Map<String, dynamic> json) {
    return OrderAccess(
      orderId: json['orderId'] as String,
      accessToken: json['accessToken'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'orderId': orderId,
      'accessToken': accessToken,
    };
  }

  static OrderAccess? fromUri(Uri uri) {
    final order = uri.queryParameters['order'] ?? uri.queryParameters['orderId'];
    final token = uri.queryParameters['token'] ?? uri.queryParameters['accessToken'];

    if (order == null || token == null || order.isEmpty || token.isEmpty) {
      return null;
    }

    return OrderAccess(orderId: order, accessToken: token);
  }
}
