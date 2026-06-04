import 'package:flutter/material.dart';

import 'ui/app_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IronVpnApp());
}

class IronVpnApp extends StatelessWidget {
  const IronVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IronVPN',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF078566),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const AppShell(),
    );
  }
}
