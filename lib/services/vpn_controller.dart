import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/stored_vpn_profile.dart';
import '../models/vless_profile.dart';
import '../models/vpn_product.dart';

enum VpnState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  unsupported,
  error,
}

class VpnController {
  static const _channel = MethodChannel('shop.ironvpn/vpn');

  Future<String?> stableDeviceId() async {
    try {
      final value = await _channel.invokeMethod<String>('deviceId');
      final normalized = value?.trim();
      return normalized == null || normalized.isEmpty ? null : normalized;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> prepare() async {
    try {
      return await _channel.invokeMethod<bool>('prepare') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<VpnState> status() async {
    try {
      final raw = await _channel.invokeMethod<String>('status');
      return _stateFromString(raw);
    } on MissingPluginException {
      return VpnState.unsupported;
    } catch (_) {
      return VpnState.error;
    }
  }

  Future<VpnState> start({
    required StoredVpnProfile profile,
    required bool routeRussianServicesDirect,
  }) async {
    final protocol = profile.product.apiValue;
    final configPayload = switch (profile.product) {
      VpnProduct.vless => profile.vlessProfile.toSingBoxConfigJson(
          routeRussianServicesDirect: routeRussianServicesDirect,
        ),
      VpnProduct.amneziaWg => profile.payload,
    };

    try {
      final raw = await _channel.invokeMethod<String>('start', {
        'profileName': profile.name,
        'protocol': protocol,
        'configJson': configPayload,
        'rawLink': profile.payload,
        'routeRussianServicesDirect': routeRussianServicesDirect,
      });
      var state = _stateFromString(raw);
      for (var attempt = 0; attempt < 40; attempt++) {
        if (state == VpnState.connected ||
            state == VpnState.unsupported ||
            state == VpnState.error) {
          return state;
        }

        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await status();
      }
      return state;
    } on MissingPluginException {
      return VpnState.unsupported;
    } catch (_) {
      return VpnState.error;
    }
  }

  Future<VpnState> stop() async {
    try {
      final raw = await _channel.invokeMethod<String>('stop');
      var state = _stateFromString(raw);
      for (var attempt = 0; attempt < 30; attempt++) {
        if (state == VpnState.disconnected ||
            state == VpnState.unsupported ||
            state == VpnState.error) {
          return state;
        }

        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = await status();
      }
      return state;
    } on MissingPluginException {
      return VpnState.unsupported;
    } catch (_) {
      return VpnState.error;
    }
  }

  String exportConfig(VlessProfile profile, bool routeRussianServicesDirect) {
    return const JsonEncoder.withIndent('  ').convert(
      profile.toSingBoxConfig(
        routeRussianServicesDirect: routeRussianServicesDirect,
      ),
    );
  }

  VpnState _stateFromString(String? value) {
    return switch (value) {
      'connecting' => VpnState.connecting,
      'connected' => VpnState.connected,
      'disconnecting' => VpnState.disconnecting,
      'unsupported' => VpnState.unsupported,
      'error' => VpnState.error,
      _ => VpnState.disconnected,
    };
  }
}
