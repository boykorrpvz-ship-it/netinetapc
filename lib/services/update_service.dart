import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// A newer release found on GitHub.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    this.notes,
  });

  final String version;
  final String downloadUrl;
  final String? notes;
}

/// Checks GitHub Releases for a newer installer and downloads/launches it.
/// Windows-only; no-ops elsewhere.
class UpdateService {
  /// Returns info about a newer release, or null if up to date / unavailable.
  Future<UpdateInfo?> checkForUpdate() async {
    if (!Platform.isWindows) {
      return null;
    }
    try {
      final resp = await http.get(
        Uri.parse(
          'https://api.github.com/repos/${AppConfig.updateRepo}/releases/latest',
        ),
        // GitHub requires a User-Agent; the Accept header pins the API version.
        headers: const {
          'User-Agent': 'netineta-updater',
          'Accept': 'application/vnd.github+json',
        },
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['draft'] == true || data['prerelease'] == true) {
        return null;
      }
      final latest = _normalize((data['tag_name'] ?? '').toString());
      if (latest.isEmpty || !_isNewer(latest, AppConfig.appVersion)) {
        return null;
      }
      // Pick the first .exe asset (the installer).
      final assets = (data['assets'] as List?) ?? const [];
      String? url;
      for (final asset in assets) {
        final name = (asset['name'] ?? '').toString().toLowerCase();
        if (name.endsWith('.exe')) {
          url = (asset['browser_download_url'] ?? '').toString();
          break;
        }
      }
      if (url == null || url.isEmpty) {
        return null;
      }
      final notes = data['body']?.toString();
      return UpdateInfo(
        version: latest,
        downloadUrl: url,
        notes: notes != null && notes.trim().isNotEmpty ? notes.trim() : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Downloads the installer to a temp file, reporting 0..1 progress.
  Future<File?> downloadInstaller(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        return null;
      }
      final total = response.contentLength ?? 0;
      final file = File(
        '${Directory.systemTemp.path}\\netineta-update-'
        '${DateTime.now().millisecondsSinceEpoch}.exe',
      );
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call(received / total);
        }
      }
      await sink.close();
      return file;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Launches the downloaded installer (it closes the running app and updates
  /// it) and returns; the caller should then quit so files can be replaced.
  Future<bool> launchInstaller(File installer) async {
    try {
      await Process.start(
        installer.path,
        const [],
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  String _normalize(String version) {
    var s = version.trim();
    if (s.startsWith('v') || s.startsWith('V')) {
      s = s.substring(1);
    }
    final plus = s.indexOf('+');
    if (plus >= 0) {
      s = s.substring(0, plus);
    }
    return s;
  }

  bool _isNewer(String latest, String current) {
    final l = _parts(latest);
    final c = _parts(_normalize(current));
    for (var i = 0; i < 3; i++) {
      if (l[i] > c[i]) {
        return true;
      }
      if (l[i] < c[i]) {
        return false;
      }
    }
    return false;
  }

  List<int> _parts(String version) {
    final raw = version.split('.');
    int at(int i) => i < raw.length
        ? (int.tryParse(raw[i].replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        : 0;
    return [at(0), at(1), at(2)];
  }
}
