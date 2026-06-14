import 'vpn_product.dart';

class Subscription {
  const Subscription({
    required this.orderId,
    required this.status,
    required this.product,
    required this.tariffName,
    required this.priceRub,
    required this.deviceName,
    required this.deviceCount,
    required this.expiresAt,
    required this.expiresMs,
    required this.vpnLink,
    required this.vpnConfig,
    required this.subscriptionUrl,
    required this.accessToken,
    required this.isTrial,
    required this.serverActive,
  });

  final String orderId;
  final String status;
  final VpnProduct product;
  final String tariffName;
  final int priceRub;
  final String deviceName;
  final int deviceCount;
  final String? expiresAt;
  final int? expiresMs;
  final String? vpnLink;
  final String? vpnConfig;
  final String? subscriptionUrl;
  final String? accessToken;
  final bool isTrial;
  final bool serverActive;

  String? get accessPayload {
    final config = vpnConfig?.trim();
    if (config != null && config.isNotEmpty) {
      return config;
    }

    final link = vpnLink?.trim();
    if (link != null && link.isNotEmpty) {
      return link;
    }

    return null;
  }

  bool get isFulfilled =>
      status == 'fulfilled' &&
      accessPayload != null &&
      accessPayload!.isNotEmpty;

  bool get isActive {
    if (!isFulfilled) {
      return false;
    }

    final expiry = expiresMs;
    if (expiry != null && expiry > 0) {
      return expiry > DateTime.now().millisecondsSinceEpoch;
    }

    return serverActive;
  }

  factory Subscription.fromJson(Map<String, dynamic> json) {
    final product = VpnProduct.fromApi(json['vpnType']);

    return Subscription(
      orderId: json['orderId'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      product: product,
      tariffName: json['tariffName'] as String? ?? '',
      priceRub: (json['priceRub'] as num?)?.toInt() ?? 0,
      deviceName: json['deviceName'] as String? ?? '',
      deviceCount: (json['deviceCount'] as num?)?.toInt() ?? 1,
      expiresAt: json['expiresAt'] as String?,
      expiresMs: (json['expiresMs'] as num?)?.toInt(),
      vpnLink: json['vpnLink'] as String?,
      vpnConfig: json['vpnConfig'] as String? ?? json['awgConfig'] as String?,
      subscriptionUrl: json['subscriptionUrl'] as String?,
      accessToken: json['accessToken'] as String?,
      isTrial: json['trial'] as bool? ?? json['orderType'] == 'trial',
      serverActive: json['active'] as bool? ?? false,
    );
  }

  static Subscription pickPrimary(
    Map<String, dynamic> json, {
    VpnProduct? product,
  }) {
    final orders = json['orders'];
    if (orders is List) {
      final fulfilled = orders
          .whereType<Map>()
          .map((item) => Subscription.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => product == null || item.product == product)
          .where((item) => item.isActive)
          .toList();

      if (fulfilled.isNotEmpty) {
        return fulfilled.first;
      }
    }

    return Subscription.fromJson(json);
  }
}
