import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironvpn_mobile/models/vpn_product.dart';
import 'package:ironvpn_mobile/ui/globe_background.dart';

/// Renders the network-globe backdrop to build/globe_preview.png so the
/// visual can be inspected without launching the app.
void main() {
  testWidgets('render globe preview png', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: key,
          child: Container(
            color: const Color(0xFF070B0D),
            child: const GlobeBackground(product: VpnProduct.vless),
          ),
        ),
      ),
    );
    // Let real time pass so rotation/packets reach a representative state.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1800)),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('build/globe_preview.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    expect(File('build/globe_preview.png').existsSync(), isTrue);
  });
}
