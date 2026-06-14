import 'package:flutter_test/flutter_test.dart';
import 'package:ironvpn_mobile/models/order_access.dart';
import 'package:ironvpn_mobile/models/stored_vpn_profile.dart';
import 'package:ironvpn_mobile/models/vpn_product.dart';
import 'package:ironvpn_mobile/services/profile_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('logout cleanup removes locally stored VPN access for both products',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = ProfileStore();

    for (final product in VpnProduct.values) {
      await store.saveOrderAccess(
        OrderAccess(
          orderId: 'order-${product.apiValue}',
          accessToken: 'token-${product.apiValue}',
          product: product,
        ),
      );
      await store.saveVpnProfile(
        StoredVpnProfile(
          product: product,
          name: product.title,
          payload: product == VpnProduct.vless
              ? 'vless://00000000-0000-0000-0000-000000000000@example.com:443'
              : '[Interface]\nPrivateKey = test',
        ),
      );
      await store.savePendingPaymentUrl(
        product,
        Uri.parse('https://example.test/pay/${product.apiValue}'),
      );
    }

    await store.clearAllVpnAccess();

    for (final product in VpnProduct.values) {
      expect(await store.loadOrderAccess(product), isNull);
      expect(await store.loadVpnProfile(product), isNull);
      expect(await store.loadPendingPaymentUrl(product), isNull);
    }
  });
}
