import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/order_access.dart';
import '../models/vless_profile.dart';

class ProfileStore {
  static const _profileKey = 'ironvpn.profile';
  static const _orderAccessKey = 'ironvpn.order_access';
  static const _directRuKey = 'ironvpn.route_ru_direct';

  Future<VlessProfile?> loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profileKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    return VlessProfile.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
  }

  Future<void> saveProfile(VlessProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileKey, profile.encode());
  }

  Future<void> clearProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_profileKey);
  }

  Future<OrderAccess?> loadOrderAccess() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_orderAccessKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    return OrderAccess.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
  }

  Future<void> saveOrderAccess(OrderAccess access) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_orderAccessKey, jsonEncode(access.toJson()));
  }

  Future<void> clearOrderAccess() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_orderAccessKey);
  }

  Future<bool> loadRouteRussianServicesDirect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_directRuKey) ?? true;
  }

  Future<void> saveRouteRussianServicesDirect(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_directRuKey, value);
  }

}
