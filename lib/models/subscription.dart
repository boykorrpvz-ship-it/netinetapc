class Subscription {
  const Subscription({
    required this.orderId,
    required this.status,
    required this.tariffName,
    required this.priceRub,
    required this.deviceName,
    required this.expiresAt,
    required this.vpnLink,
  });

  final String orderId;
  final String status;
  final String tariffName;
  final int priceRub;
  final String deviceName;
  final String? expiresAt;
  final String? vpnLink;

  bool get isFulfilled => status == 'fulfilled' && vpnLink != null && vpnLink!.isNotEmpty;

  factory Subscription.fromJson(Map<String, dynamic> json) {
    return Subscription(
      orderId: json['orderId'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      tariffName: json['tariffName'] as String? ?? '',
      priceRub: (json['priceRub'] as num?)?.toInt() ?? 0,
      deviceName: json['deviceName'] as String? ?? '',
      expiresAt: json['expiresAt'] as String?,
      vpnLink: json['vpnLink'] as String?,
    );
  }

  static Subscription pickPrimary(Map<String, dynamic> json) {
    final orders = json['orders'];
    if (orders is List) {
      final fulfilled = orders
          .whereType<Map>()
          .map((item) => Subscription.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => item.isFulfilled)
          .toList();

      if (fulfilled.isNotEmpty) {
        return fulfilled.first;
      }
    }

    return Subscription.fromJson(json);
  }
}
