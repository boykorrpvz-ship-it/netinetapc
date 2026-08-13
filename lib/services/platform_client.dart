import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// HTTP client that tags every request to our API with the client platform and
/// version. Lets the server count active users per platform (Windows/Android/…)
/// without any personal data — just a platform label and app version header.
class PlatformHttpClient extends http.BaseClient {
  PlatformHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  static String get platformLabel {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'other';
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['X-Client-Platform'] = platformLabel;
    request.headers['X-Client-Version'] = AppConfig.appVersion;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
