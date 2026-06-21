import 'subscription.dart';
import 'vless_profile.dart';
import 'vpn_product.dart';

class StoredVpnProfile {
  const StoredVpnProfile({
    required this.product,
    required this.name,
    required this.payload,
  });

  final VpnProduct product;
  final String name;
  final String payload;

  factory StoredVpnProfile.fromSubscription(Subscription subscription) {
    final payload = subscription.accessPayload;
    if (payload == null || payload.isEmpty) {
      throw const FormatException('Подписка пока не содержит конфиг.');
    }

    if (subscription.product == VpnProduct.vless) {
      final vless = VlessProfile.parse(payload);
      return StoredVpnProfile(
        product: VpnProduct.vless,
        name: vless.name,
        payload: payload,
      );
    }

    return StoredVpnProfile(
      product: VpnProduct.amneziaWg,
      name: subscription.deviceName.isEmpty
          ? 'netineta AWG'
          : 'netineta ${subscription.deviceName}',
      payload: payload,
    );
  }

  factory StoredVpnProfile.fromJson(Map<String, dynamic> json) {
    return StoredVpnProfile(
      product: VpnProduct.fromApi(json['vpnType']),
      name: json['name'] as String? ?? 'netineta',
      payload: json['payload'] as String? ?? json['rawLink'] as String? ?? '',
    );
  }

  VlessProfile get vlessProfile {
    if (product != VpnProduct.vless) {
      throw StateError('Это не VLESS-профиль.');
    }
    return VlessProfile.parse(payload);
  }

  Map<String, dynamic> toJson() {
    return {
      'vpnType': product.apiValue,
      'name': name,
      'payload': payload,
    };
  }
}
