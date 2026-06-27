import 'dart:convert';
import 'dart:io';

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
  static Process? _windowsProcess;
  static bool _windowsRunning = false;

  Future<String?> stableDeviceId() async {
    if (Platform.isWindows) {
      return _windowsStableDeviceId();
    }

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
    if (Platform.isWindows) {
      return true;
    }

    try {
      return await _channel.invokeMethod<bool>('prepare') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<VpnState> status() async {
    if (Platform.isWindows) {
      return _windowsRunning ? VpnState.connected : VpnState.disconnected;
    }

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
    if (Platform.isWindows) {
      return _startWindows(
        profile: profile,
        routeRussianServicesDirect: routeRussianServicesDirect,
      );
    }

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
    if (Platform.isWindows) {
      return _stopWindows();
    }

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

  Future<int?> testLatency(StoredVpnProfile profile) async {
    if (profile.product != VpnProduct.vless) {
      return null;
    }

    Socket? socket;
    final vless = profile.vlessProfile;
    final stopwatch = Stopwatch()..start();
    try {
      socket = await Socket.connect(
        vless.host,
        vless.port,
        timeout: const Duration(seconds: 4),
      );
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
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

  Future<VpnState> _startWindows({
    required StoredVpnProfile profile,
    required bool routeRussianServicesDirect,
  }) async {
    if (profile.product != VpnProduct.vless) {
      return VpnState.unsupported;
    }

    await _stopWindows();

    try {
      final exePath = await _findWindowsSingBox();
      if (exePath == null) {
        return VpnState.unsupported;
      }

      final workDir = _windowsWorkDir();
      await workDir.create(recursive: true);

      final configFile = File(_join(workDir.path, 'config.json'));
      final desktopConfig = _migrateConfigForDesktop(
        profile.vlessProfile.toSingBoxConfig(
          routeRussianServicesDirect: routeRussianServicesDirect,
        ),
      );
      await configFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(desktopConfig),
      );

      final logFile = File(_join(workDir.path, 'sing-box.log'));
      final process = await Process.start(
        exePath,
        ['run', '-c', configFile.path],
        workingDirectory: workDir.path,
        runInShell: false,
        // The bundled desktop sing-box (>= 1.13) still accepts the shared
        // config's remaining legacy bits (DNS server + dial domain resolver)
        // only when these opt-ins are set. Migrating the shared generator would
        // break the older libbox used on mobile, so we relax it here instead.
        environment: const {
          'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
          'ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER': 'true',
        },
      );

      _windowsProcess = process;
      _windowsRunning = true;

      process.stdout
          .transform(utf8.decoder)
          .listen((chunk) => _appendWindowsLog(logFile, chunk));
      process.stderr
          .transform(utf8.decoder)
          .listen((chunk) => _appendWindowsLog(logFile, chunk));
      process.exitCode.then((code) {
        if (identical(_windowsProcess, process)) {
          _windowsProcess = null;
          _windowsRunning = false;
        }
        _appendWindowsLog(logFile, '\nprocess exited: $code\n');
        return code;
      });

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return _windowsRunning ? VpnState.connected : VpnState.error;
    } catch (_) {
      _windowsRunning = false;
      _windowsProcess = null;
      return VpnState.error;
    }
  }

  Future<VpnState> _stopWindows() async {
    final process = _windowsProcess;
    _windowsProcess = null;
    _windowsRunning = false;

    if (process == null) {
      return VpnState.disconnected;
    }

    try {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 4),
        onTimeout: () => -1,
      );
    } catch (_) {
      try {
        await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
      } catch (_) {}
    }

    return VpnState.disconnected;
  }

  Future<String?> _windowsStableDeviceId() async {
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKLM\SOFTWARE\Microsoft\Cryptography',
        '/v',
        'MachineGuid',
      ]);
      final output = '${result.stdout}\n${result.stderr}';
      final match =
          RegExp(r'MachineGuid\s+REG_SZ\s+([^\s]+)').firstMatch(output);
      final guid = match?.group(1)?.trim();
      if (guid != null && guid.isNotEmpty) {
        return 'windows-$guid';
      }
    } catch (_) {}

    final computerName = Platform.environment['COMPUTERNAME']?.trim();
    if (computerName != null && computerName.isNotEmpty) {
      return 'windows-${computerName.toLowerCase()}';
    }

    return null;
  }

  Future<String?> _findWindowsSingBox() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final userProfile = Platform.environment['USERPROFILE'] ?? '';

    final candidates = [
      _join(exeDir, 'data', 'flutter_assets', 'assets', 'bin', 'windows',
          'sing-box.exe'),
      _join(Directory.current.path, 'assets', 'bin', 'windows', 'sing-box.exe'),
      if (userProfile.isNotEmpty)
        _join(
          userProfile,
          'AppData',
          'Local',
          'Microsoft',
          'WinGet',
          'Packages',
          'SagerNet.sing-box_Microsoft.Winget.Source_8wekyb3d8bbwe',
          'sing-box-1.13.13-windows-amd64',
          'sing-box.exe',
        ),
    ];

    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        return candidate;
      }
    }

    try {
      final result = await Process.run('where', ['sing-box']);
      if (result.exitCode == 0) {
        final first = (result.stdout as String)
            .split(RegExp(r'\r?\n'))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .firstOrNull;
        if (first != null && await File(first).exists()) {
          return first;
        }
      }
    } catch (_) {}

    return null;
  }

  Directory _windowsWorkDir() {
    final appData = Platform.environment['APPDATA'];
    final root = appData == null || appData.trim().isEmpty
        ? Directory.systemTemp.path
        : appData;
    return Directory(_join(root, 'netineta', 'sing-box'));
  }

  // The bundled desktop sing-box (>= 1.13) removed several legacy fields the
  // shared mobile config still emits. Rewrite just those for the desktop run so
  // the shared generator keeps working with the older libbox on mobile.
  Map<String, dynamic> _migrateConfigForDesktop(Map<String, dynamic> config) {
    final result = Map<String, dynamic>.from(config);

    // Inbounds: drop the legacy `sniff` flag (sniffing is a route action now).
    result['inbounds'] = (result['inbounds'] as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map)..remove('sniff'))
        .toList();

    // Outbounds: drop the legacy `block` outbound (rejection is a route action).
    result['outbounds'] = (result['outbounds'] as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .where((outbound) => outbound['type'] != 'block')
        .toList();

    // Route: turn sniffing on via an action rule and convert any
    // `outbound: block` rule into the `reject` action.
    final route = Map<String, dynamic>.from(result['route'] as Map);
    final rules = <Map<String, dynamic>>[
      {'action': 'sniff'},
    ];
    for (final entry in (route['rules'] as List)) {
      final rule = Map<String, dynamic>.from(entry as Map);
      if (rule['outbound'] == 'block') {
        rule.remove('outbound');
        rule['action'] = 'reject';
      }
      rules.add(rule);
    }
    route['rules'] = rules;
    result['route'] = route;

    return result;
  }

  void _appendWindowsLog(File file, String chunk) {
    try {
      file.writeAsStringSync(chunk, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  String _join(String first, String second,
      [String? third,
      String? fourth,
      String? fifth,
      String? sixth,
      String? seventh,
      String? eighth,
      String? ninth,
      String? tenth]) {
    final parts = [
      first,
      second,
      third,
      fourth,
      fifth,
      sixth,
      seventh,
      eighth,
      ninth,
      tenth,
    ].whereType<String>().where((part) => part.isNotEmpty).toList();
    return parts.join(Platform.pathSeparator);
  }
}
