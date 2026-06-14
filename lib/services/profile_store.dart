import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/order_access.dart';
import '../models/stored_vpn_profile.dart';
import '../models/vless_profile.dart';
import '../models/vpn_product.dart';

class ProfileStore {
  static const _secureStorage = FlutterSecureStorage();
  static const _profileKey = 'ironvpn.profile';
  static const _orderAccessKey = 'ironvpn.order_access';
  static const _directRuKey = 'ironvpn.route_ru_direct';
  static const _selectedProductKey = 'ironvpn.selected_product';
  static const _installIdKey = 'ironvpn.install_id';
  static const _paymentUrlPrefix = 'ironvpn.pending_payment_url.';
  static const _renewalAccessPrefix = 'ironvpn.pending_renewal_access.';
  static const _renewalUrlPrefix = 'ironvpn.pending_renewal_payment_url.';
  static const _accountTokenKey = 'ironvpn.account_token';
  static const _accountEmailKey = 'ironvpn.account_email';

  String _profileKeyFor(VpnProduct product) =>
      '$_profileKey.${product.apiValue}';

  String _orderAccessKeyFor(VpnProduct product) =>
      '$_orderAccessKey.${product.apiValue}';

  String _paymentUrlKeyFor(VpnProduct product) =>
      '$_paymentUrlPrefix${product.apiValue}';

  String _renewalAccessKeyFor(VpnProduct product) =>
      '$_renewalAccessPrefix${product.apiValue}';

  String _renewalUrlKeyFor(VpnProduct product) =>
      '$_renewalUrlPrefix${product.apiValue}';

  Future<StoredVpnProfile?> loadVpnProfile(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getString(_profileKeyFor(product));

    if ((raw == null || raw.isEmpty) && product == VpnProduct.vless) {
      raw = prefs.getString(_profileKey);
      if (raw != null && raw.isNotEmpty) {
        final legacy = VlessProfile.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
        final migrated = StoredVpnProfile(
          product: VpnProduct.vless,
          name: legacy.name,
          payload: legacy.rawLink,
        );
        await saveVpnProfile(migrated);
        return migrated;
      }
    }

    if (raw == null || raw.isEmpty) {
      return null;
    }

    return StoredVpnProfile.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
  }

  Future<void> saveVpnProfile(StoredVpnProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _profileKeyFor(profile.product), jsonEncode(profile.toJson()));
  }

  Future<void> clearVpnProfile(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_profileKeyFor(product));
  }

  Future<OrderAccess?> loadOrderAccess(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getString(_orderAccessKeyFor(product));

    if ((raw == null || raw.isEmpty) && product == VpnProduct.vless) {
      raw = prefs.getString(_orderAccessKey);
      if (raw != null && raw.isNotEmpty) {
        final legacy = OrderAccess.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        ).copyWith(product: VpnProduct.vless);
        await saveOrderAccess(legacy);
        return legacy;
      }
    }

    if (raw == null || raw.isEmpty) {
      return null;
    }

    return OrderAccess.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    ).copyWith(product: product);
  }

  Future<void> saveOrderAccess(OrderAccess access) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _orderAccessKeyFor(access.product), jsonEncode(access.toJson()));
  }

  Future<void> clearOrderAccess(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_orderAccessKeyFor(product));
  }

  Future<void> clearAllVpnAccess() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.remove(_profileKey);
    await prefs.remove(_orderAccessKey);

    for (final product in VpnProduct.values) {
      await prefs.remove(_profileKeyFor(product));
      await prefs.remove(_orderAccessKeyFor(product));
      await prefs.remove(_paymentUrlKeyFor(product));
      await prefs.remove(_renewalAccessKeyFor(product));
      await prefs.remove(_renewalUrlKeyFor(product));
    }
  }

  Future<bool> loadRouteRussianServicesDirect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_directRuKey) ?? true;
  }

  Future<void> saveRouteRussianServicesDirect(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_directRuKey, value);
  }

  Future<VpnProduct> loadSelectedProduct() async {
    final prefs = await SharedPreferences.getInstance();
    return VpnProduct.fromApi(prefs.getString(_selectedProductKey));
  }

  Future<void> saveSelectedProduct(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedProductKey, product.apiValue);
  }

  Future<String> loadOrCreateInstallId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_installIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final random = Random.secure();
    final id = List<int>.generate(8, (_) => random.nextInt(256))
        .map((item) => item.toRadixString(16).padLeft(2, '0'))
        .join();
    await prefs.setString(_installIdKey, id);
    return id;
  }

  Future<Uri?> loadPendingPaymentUrl(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_paymentUrlKeyFor(product));
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return Uri.tryParse(raw);
  }

  Future<void> savePendingPaymentUrl(VpnProduct product, Uri url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_paymentUrlKeyFor(product), url.toString());
  }

  Future<void> clearPendingPaymentUrl(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_paymentUrlKeyFor(product));
  }

  Future<OrderAccess?> loadPendingRenewalAccess(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_renewalAccessKeyFor(product));

    if (raw == null || raw.isEmpty) {
      return null;
    }

    return OrderAccess.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    ).copyWith(product: product);
  }

  Future<void> savePendingRenewalAccess(OrderAccess access) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _renewalAccessKeyFor(access.product),
      jsonEncode(access.toJson()),
    );
  }

  Future<void> clearPendingRenewalAccess(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_renewalAccessKeyFor(product));
  }

  Future<Uri?> loadPendingRenewalPaymentUrl(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_renewalUrlKeyFor(product));
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return Uri.tryParse(raw);
  }

  Future<void> savePendingRenewalPaymentUrl(VpnProduct product, Uri url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_renewalUrlKeyFor(product), url.toString());
  }

  Future<void> clearPendingRenewalPaymentUrl(VpnProduct product) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_renewalUrlKeyFor(product));
  }

  Future<String?> loadAccountToken() async {
    final token = await _secureStorage.read(key: _accountTokenKey);
    return token == null || token.isEmpty ? null : token;
  }

  Future<void> saveAccount({
    required String token,
    required String email,
  }) async {
    await _secureStorage.write(key: _accountTokenKey, value: token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accountEmailKey, email);
  }

  Future<String?> loadAccountEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString(_accountEmailKey);
    return email == null || email.isEmpty ? null : email;
  }

  Future<void> clearAccount() async {
    await _secureStorage.delete(key: _accountTokenKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accountEmailKey);
  }
}
