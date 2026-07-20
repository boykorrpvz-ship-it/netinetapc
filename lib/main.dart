import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'config/app_config.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // The updater compares this against the latest GitHub release tag. Read it
  // from the built binary so it can never drift from pubspec.yaml again.
  try {
    AppConfig.appVersion = (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    // keep the fallback baked into AppConfig
  }
  // Set by the Windows logon autostart entry so we can come up minimized.
  final launchedAtStartup = args.contains('--autostart');

  // Desktop (Windows): keep running in the system tray when the window's close
  // button is pressed, instead of quitting the app/tunnel.
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }

  runApp(IronVpnApp(launchedAtStartup: launchedAtStartup));
}

class IronVpnApp extends StatefulWidget {
  const IronVpnApp({
    this.launchedAtStartup = false,
    super.key,
  });

  final bool launchedAtStartup;

  @override
  State<IronVpnApp> createState() => _IronVpnAppState();
}

class _IronVpnAppState extends State<IronVpnApp>
    with WindowListener, TrayListener {
  // Only hide-to-tray once the tray icon is actually up, so a tray failure can
  // never leave the window hidden with no way to bring it back.
  bool _trayReady = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray().then((_) {
        // Started by Windows logon → come up hidden in the tray.
        if (widget.launchedAtStartup && _trayReady) {
          windowManager.hide();
        }
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('netineta');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Открыть netineta'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: 'Выход'),
          ],
        ),
      );
      _trayReady = true;
    } catch (_) {
      _trayReady = false;
    }
  }

  Future<void> _restoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // Hide to tray instead of quitting when the close button is pressed — but
  // only if the tray icon is up; otherwise really close so we never strand a
  // hidden, unrecoverable window.
  @override
  void onWindowClose() async {
    if (_trayReady && await windowManager.isPreventClose()) {
      await windowManager.hide();
    } else {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  @override
  void onTrayIconMouseDown() => _restoreWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await _restoreWindow();
      case 'exit':
        await trayManager.destroy();
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
    }
  }

  // The app is dark-only (the light theme + toggle were removed).
  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: dark ? const Color(0xFF19C08A) : const Color(0xFF07835C),
      brightness: brightness,
    ).copyWith(
      primary: dark ? const Color(0xFF19C08A) : const Color(0xFF07835C),
      secondary: dark ? const Color(0xFFF7860B) : const Color(0xFFC2620A),
      surface: dark ? const Color(0xFF0B1216) : Colors.white,
      onSurface: dark ? const Color(0xFFF2F7F6) : const Color(0xFF0A1C20),
    );

    final base = ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,
      fontFamily: 'Manrope',
      scaffoldBackgroundColor:
          dark ? const Color(0xFF070B0D) : const Color(0xFFEEF3F6),
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: dark ? const Color(0xFF04130D) : Colors.white,
          minimumSize: const Size.fromHeight(54),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.tile),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: dark ? const Color(0xFF7FF0C6) : scheme.primary,
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(
            color: dark ? const Color(0x2EFFFFFF) : const Color(0x33067A5B),
            width: 1.4,
          ),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.tile),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurface,
          backgroundColor:
              dark ? const Color(0x17FFFFFF) : const Color(0xFFFFFFFF),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? (dark ? const Color(0xFF04130D) : Colors.white)
              : const Color(0xFFF2F7F6),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : (dark ? const Color(0x2EFFFFFF) : const Color(0x260B2A33)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0x40000000) : const Color(0xFFFFFFFF),
        labelStyle: TextStyle(
          color: dark ? const Color(0xFFAEBCC0) : const Color(0xFF45585E),
        ),
        hintStyle: TextStyle(
          color: dark ? const Color(0xFF7C8A8F) : const Color(0xFF6C7E84),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadii.tile,
          borderSide: BorderSide(
            color: dark ? const Color(0x1AFFFFFF) : const Color(0x1F0B2A33),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadii.tile,
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: AppRadii.tile,
          borderSide: BorderSide(
            color: dark ? const Color(0x12FFFFFF) : const Color(0x140B2A33),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final darkTheme = _theme(Brightness.dark);
    AppColors.useDarkTheme(true);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'netineta',
      theme: darkTheme,
      themeMode: ThemeMode.dark,
      home: const AppShell(),
    );
  }
}
