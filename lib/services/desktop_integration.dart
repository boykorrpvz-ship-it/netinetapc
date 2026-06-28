import 'dart:io';

/// Windows-only desktop integrations: launch-at-logon and opening the log
/// folder. All methods are no-ops on other platforms.
class DesktopIntegration {
  static const _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runValueName = 'netineta';

  /// Registers (or removes) the app in the current user's Run key so it starts
  /// at logon. Passes --autostart so the app can start minimized to the tray.
  static Future<void> setAutostart(bool enabled) async {
    if (!Platform.isWindows) {
      return;
    }
    if (enabled) {
      final exe = Platform.resolvedExecutable;
      await Process.run('reg', [
        'add',
        _runKey,
        '/v',
        _runValueName,
        '/t',
        'REG_SZ',
        '/d',
        '"$exe" --autostart',
        '/f',
      ]);
    } else {
      await Process.run('reg', [
        'delete',
        _runKey,
        '/v',
        _runValueName,
        '/f',
      ]);
    }
  }

  static Future<bool> isAutostartEnabled() async {
    if (!Platform.isWindows) {
      return false;
    }
    final result = await Process.run(
      'reg',
      ['query', _runKey, '/v', _runValueName],
    );
    return result.exitCode == 0;
  }

  /// Opens the folder that holds the runtime config and logs in Explorer.
  static Future<void> openLogsFolder() async {
    if (!Platform.isWindows) {
      return;
    }
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.trim().isEmpty) {
      return;
    }
    final dir = '$appData\\netineta\\sing-box';
    await Directory(dir).create(recursive: true);
    await Process.run('explorer', [dir]);
  }
}
