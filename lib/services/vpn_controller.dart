import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

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
  // AmneziaWG tunnel naming. The tunnel name is derived from the config file
  // name (netineta-awg.conf), and the Windows service name follows the official
  // amneziawg-windows scheme: "AmneziaWGTunnel$<name>".
  static const _awgTunnelName = 'netineta-awg';
  static const _awgServiceName = 'AmneziaWGTunnel\$netineta-awg';
  static Process? _windowsProcess;
  static bool _windowsRunning = false;
  // True while the AmneziaWG tunnel service (Windows) is installed/running.
  static bool _windowsAwgActive = false;

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
      if (await _isWindowsAwgServiceRunning()) {
        _windowsAwgActive = true;
        return VpnState.connected;
      }
      _windowsAwgActive = false;
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
    bool killSwitch = false,
  }) async {
    if (Platform.isWindows) {
      return _startWindows(
        profile: profile,
        routeRussianServicesDirect: routeRussianServicesDirect,
        killSwitch: killSwitch,
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
    final String host;
    final int port;
    if (profile.product == VpnProduct.vless) {
      final vless = profile.vlessProfile;
      host = vless.host;
      port = vless.port;
    } else {
      // AmneziaWG: probe the server endpoint parsed from the config.
      final endpoint = _awgEndpoint(profile.payload);
      if (endpoint == null) {
        return null;
      }
      host = endpoint.$1;
      port = endpoint.$2;
    }

    Socket? socket;
    final stopwatch = Stopwatch()..start();
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 4),
      );
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } on SocketException catch (error) {
      stopwatch.stop();
      // A refused connection still completed a full round-trip to the server,
      // so the elapsed time is a usable latency estimate. AmneziaWG endpoints
      // are UDP and reject/ignore the TCP probe; only a timeout (no osError
      // before the deadline) means the host is actually unreachable.
      if (error.osError != null &&
          stopwatch.elapsed < const Duration(seconds: 4)) {
        return stopwatch.elapsedMilliseconds;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  // Parses "Endpoint = host:port" from an AmneziaWG/WireGuard config payload.
  (String, int)? _awgEndpoint(String payload) {
    final match =
        RegExp(r'^\s*Endpoint\s*=\s*(.+):(\d+)\s*$', multiLine: true)
            .firstMatch(payload);
    if (match == null) {
      return null;
    }
    final host = match.group(1)!.trim();
    final port = int.tryParse(match.group(2)!);
    if (host.isEmpty || port == null) {
      return null;
    }
    return (host, port);
  }

  /// Cumulative (received, sent) bytes of the active tunnel adapter on Windows,
  /// or null if no tunnel adapter is up. Both AmneziaWG and the VLESS sing-box
  /// TUN run over Wintun, so we match the active Wintun/WireGuard adapter.
  Future<(int, int)?> tunnelAdapterBytes() async {
    if (!Platform.isWindows) {
      return null;
    }
    const script = r'''
$a = Get-NetAdapter | Where-Object {
  $_.Status -eq 'Up' -and (
    $_.Name -like '*netineta*' -or
    $_.Name -like '*ironvpn*' -or
    $_.InterfaceDescription -like '*Wintun*' -or
    $_.InterfaceDescription -like '*WireGuard*' -or
    $_.InterfaceDescription -like '*sing-box*'
  )
} | Select-Object -First 1
if ($null -eq $a) { Write-Output 'none'; exit 0 }
$s = Get-NetAdapterStatistics -Name $a.Name
Write-Output ("{0} {1}" -f $s.ReceivedBytes, $s.SentBytes)
''';
    try {
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      );
      final out = (result.stdout as String).trim();
      if (out.isEmpty || out == 'none') {
        return null;
      }
      final parts = out.split(RegExp(r'\s+'));
      if (parts.length < 2) {
        return null;
      }
      final rx = int.tryParse(parts[0]);
      final tx = int.tryParse(parts[1]);
      if (rx == null || tx == null) {
        return null;
      }
      return (rx, tx);
    } catch (_) {
      return null;
    }
  }

  /// Accurate per-direction (received, sent) bytes for the active tunnel.
  /// VLESS reads the sing-box Clash API (the sing-tun NDIS counters are
  /// symmetric and can't tell up from down); AmneziaWG uses adapter counters.
  Future<(int, int)?> tunnelBytes(VpnProduct? product) async {
    if (product == VpnProduct.vless) {
      final clash = await _clashConnectionsBytes();
      if (clash != null) {
        return clash;
      }
    }
    return tunnelAdapterBytes();
  }

  Future<(int, int)?> _clashConnectionsBytes() async {
    try {
      final resp = await http.get(
        Uri.parse('http://127.0.0.1:$_clashPort/connections'),
        headers: {'Authorization': 'Bearer $_clashSecret'},
      ).timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) {
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final down = (data['downloadTotal'] as num?)?.toInt();
      final up = (data['uploadTotal'] as num?)?.toInt();
      if (down == null || up == null) {
        return null;
      }
      return (down, up);
    } catch (_) {
      return null;
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
    bool killSwitch = false,
  }) async {
    if (profile.product == VpnProduct.amneziaWg) {
      return _startWindowsAwg(profile, killSwitch: killSwitch);
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
    await _uninstallAwgService();

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

  // Starts the AmneziaWG tunnel on Windows using the *official* engine and
  // service model. The bundled awgtunnel.exe is built from amneziawg-windows
  // v0.1.9 + amneziawg-go v0.2.18 (exactly what the official
  // amneziawg-windows-client ships) and exposes the same verbs its UI drives:
  // "/installtunnelservice <conf>" creates and starts the per-tunnel Windows
  // service, whose "/tunnelservice" mode runs the unmodified tunnel.Run().
  // netineta.exe is elevated, so the child inherits the rights to manage
  // services.
  Future<VpnState> _startWindowsAwg(
    StoredVpnProfile profile, {
    bool killSwitch = false,
  }) async {
    await _stopWindows();

    try {
      final workDir = _windowsWorkDir();
      await workDir.create(recursive: true);
      final confFile = File(_join(workDir.path, 'netineta-awg.conf'));
      final logFile = File(_join(workDir.path, 'netineta-awg.log'));
      await confFile.writeAsString(
        _prepareWindowsAwgConfig(profile.payload, killSwitch: killSwitch),
      );

      final result = await Process.run(
        _awgExePath(),
        ['/installtunnelservice', confFile.path],
      );
      _appendWindowsLog(
        logFile,
        '\ninstalltunnelservice exit=${result.exitCode}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}\n',
      );
      if (result.exitCode != 0) {
        return VpnState.error;
      }
      _windowsAwgActive = true;

      for (var attempt = 0; attempt < 40; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (await _isWindowsAwgServiceRunning()) {
          await _configureWindowsAwgAdapter(logFile);
          return VpnState.connected;
        }
      }
      return await _isWindowsAwgServiceRunning()
          ? VpnState.connected
          : VpnState.error;
    } catch (_) {
      await _uninstallAwgService();
      return VpnState.error;
    }
  }

  String _prepareWindowsAwgConfig(String config, {bool killSwitch = false}) {
    // WireGuard/AmneziaWG on Windows enables a strict firewall kill-switch when
    // the peer has a literal 0.0.0.0/0 route: traffic is blocked unless it goes
    // through the tunnel, so nothing leaks if the tunnel drops (but the LAN is
    // blocked too). When the kill-switch is OFF we split 0.0.0.0/0 into two /1
    // routes — same full-tunnel routing, but without the strict firewall, so the
    // LAN / router UI stay reachable.
    if (killSwitch) {
      return config.trimRight();
    }
    return config.replaceAllMapped(
      RegExp(r'^AllowedIPs\s*=\s*(.+)$', multiLine: true),
      (match) {
        final values = match
            .group(1)!
            .split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList();
        final normalized = <String>[];
        for (final value in values) {
          if (value == '0.0.0.0/0') {
            normalized.addAll(['0.0.0.0/1', '128.0.0.0/1']);
          } else if (value == '::/0') {
            normalized.addAll(['::/1', '8000::/1']);
          } else {
            normalized.add(value);
          }
        }
        return 'AllowedIPs = ${normalized.toSet().join(', ')}';
      },
    ).trimRight();
  }

  Future<void> _configureWindowsAwgAdapter(File logFile) async {
    const script = r'''
$adapter = Get-NetAdapter |
  Where-Object { $_.Name -eq 'netineta' -or $_.InterfaceDescription -like '*WireGuard*' } |
  Select-Object -First 1
if ($null -eq $adapter) {
  Write-Output 'adapter=missing'
  exit 0
}
Write-Output ('adapter=' + $adapter.Name + '; ifIndex=' + $adapter.ifIndex)
try {
  Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @('1.1.1.1','8.8.8.8') -ErrorAction Stop
  Write-Output 'dns=ok'
} catch {
  Write-Output ('dns=failed ' + $_.Exception.Message)
}
try {
  Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -InterfaceMetric 1 -ErrorAction Stop
  Write-Output 'metric=ok'
} catch {
  Write-Output ('metric=failed ' + $_.Exception.Message)
}
''';

    try {
      for (var attempt = 0; attempt < 20; attempt++) {
        final result = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            script,
          ],
        );
        final output = '${result.stdout}\n${result.stderr}'.trim();
        _appendWindowsLog(
          logFile,
          '\nadapter-config attempt=$attempt exit=${result.exitCode}\n$output\n',
        );
        if (output.contains('dns=ok')) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } catch (error) {
      _appendWindowsLog(logFile, '\nadapter-config exception=$error\n');
    }
  }

  Future<bool> _isWindowsAwgServiceRunning() async {
    try {
      final result = await Process.run('sc', ['query', _awgServiceName]);
      return (result.stdout as String).contains('RUNNING');
    } catch (_) {
      return false;
    }
  }

  Future<void> _uninstallAwgService() async {
    _windowsAwgActive = false;
    try {
      await Process.run(
        _awgExePath(),
        ['/uninstalltunnelservice', _awgTunnelName],
      );
    } catch (_) {}
  }

  // Absolute path to the bundled awgtunnel.exe, which sits next to netineta.exe.
  String _awgExePath() =>
      _join(File(Platform.resolvedExecutable).parent.path, 'awgtunnel.exe');

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

  // Clash API exposed by the desktop sing-box so the app can read accurate
  // per-direction traffic (the sing-tun adapter's NDIS counters are symmetric).
  static const _clashPort = 19191;
  static const _clashSecret = 'netineta-stats';

  // The bundled desktop sing-box (>= 1.13) removed several legacy fields the
  // shared mobile config still emits. Rewrite just those for the desktop run so
  // the shared generator keeps working with the older libbox on mobile.
  Map<String, dynamic> _migrateConfigForDesktop(Map<String, dynamic> config) {
    final result = Map<String, dynamic>.from(config);

    // Desktop-only: enable the Clash API for accurate up/down stats.
    final experimental = Map<String, dynamic>.from(
        (result['experimental'] as Map?) ?? const {});
    experimental['clash_api'] = {
      'external_controller': '127.0.0.1:$_clashPort',
      'secret': _clashSecret,
    };
    result['experimental'] = experimental;

    // Inbounds: drop the legacy `sniff` flag (sniffing is a route action now).
    result['inbounds'] = (result['inbounds'] as List)
        .map(
            (entry) => Map<String, dynamic>.from(entry as Map)..remove('sniff'))
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
