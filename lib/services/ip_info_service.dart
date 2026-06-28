import 'dart:convert';

import 'package:http/http.dart' as http;

/// Public IP + country as seen from the current network path. When the VPN is
/// up, the lookup travels through the tunnel and returns the exit IP/country.
class IpInfo {
  const IpInfo({required this.ip, this.country, this.countryCode});

  final String ip;
  final String? country;
  final String? countryCode;

  /// Country as a flag emoji from the ISO-3166 alpha-2 code, or '' if unknown.
  String get flag {
    final cc = countryCode;
    if (cc == null || cc.length != 2) {
      return '';
    }
    const base = 0x1F1E6; // Regional Indicator Symbol Letter A.
    final upper = cc.toUpperCase();
    return String.fromCharCodes([
      base + (upper.codeUnitAt(0) - 65),
      base + (upper.codeUnitAt(1) - 65),
    ]);
  }

  String get label {
    if (country != null && country!.isNotEmpty) {
      final f = flag;
      return '$ip · ${f.isNotEmpty ? '$f ' : ''}$country';
    }
    return ip;
  }
}

class IpInfoService {
  Future<IpInfo?> fetch() async {
    try {
      final resp = await http
          .get(Uri.parse(
            'http://ip-api.com/json/?fields=status,query,country,countryCode',
          ))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) {
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'success') {
        return null;
      }
      final ip = (data['query'] ?? '').toString();
      if (ip.isEmpty) {
        return null;
      }
      return IpInfo(
        ip: ip,
        country: data['country']?.toString(),
        countryCode: data['countryCode']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}
