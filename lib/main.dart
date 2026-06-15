import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui/app_shell.dart';
import 'ui/theme.dart';

const _themePreferenceKey = 'ironvpn_dark_theme';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final darkTheme = preferences.getBool(_themePreferenceKey) ?? true;
  runApp(IronVpnApp(initialDarkTheme: darkTheme));
}

class IronVpnApp extends StatefulWidget {
  const IronVpnApp({
    required this.initialDarkTheme,
    super.key,
  });

  final bool initialDarkTheme;

  @override
  State<IronVpnApp> createState() => _IronVpnAppState();
}

class _IronVpnAppState extends State<IronVpnApp> {
  late bool _darkTheme = widget.initialDarkTheme;

  Future<void> _setDarkTheme(bool value) async {
    if (_darkTheme == value) {
      return;
    }
    setState(() => _darkTheme = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_themePreferenceKey, value);
  }

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
            fontWeight: FontWeight.w900,
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
            fontWeight: FontWeight.w900,
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
    final lightTheme = _theme(Brightness.light);
    final darkTheme = _theme(Brightness.dark);
    AppColors.useDarkTheme(_darkTheme);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'netineta',
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: _darkTheme ? ThemeMode.dark : ThemeMode.light,
      home: AppShell(
        darkTheme: _darkTheme,
        onDarkThemeChanged: _setDarkTheme,
      ),
    );
  }
}
