import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/vpn_product.dart';
import 'theme.dart';

/// The site's signature "network globe" backdrop (netineta.com), rendered
/// natively: a fibonacci sphere of dots with a few connecting arcs and glow
/// nodes, slowly rotating. Sits behind the app content at low opacity and is
/// tinted with the active product's accent (green VLESS / orange AWG).
class GlobeBackground extends StatefulWidget {
  const GlobeBackground({required this.product, super.key});

  final VpnProduct product;

  @override
  State<GlobeBackground> createState() => _GlobeBackgroundState();
}

class _GlobeBackgroundState extends State<GlobeBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 90),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _GlobePainter(
            animation: _controller,
            accent: AppColors.accentFor(widget.product),
            dark: AppColors.isDark,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _GlobePainter extends CustomPainter {
  _GlobePainter({
    required this.animation,
    required this.accent,
    required this.dark,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color accent;
  final bool dark;

  // Precomputed unit fibonacci sphere + stable arc pairs (same for every
  // instance, so rebuilds don't reshuffle the picture).
  static const _count = 900;
  static final List<List<double>> _points = _buildPoints();
  static final List<List<int>> _arcs = _buildArcs();

  static List<List<double>> _buildPoints() {
    final pts = <List<double>>[];
    const golden = math.pi * (3 - 2.2360679); // pi*(3-sqrt(5))
    for (var i = 0; i < _count; i++) {
      final y = 1 - (i / (_count - 1)) * 2;
      final r = math.sqrt(1 - y * y);
      final theta = golden * i;
      pts.add([math.cos(theta) * r, y, math.sin(theta) * r]);
    }
    return pts;
  }

  static List<List<int>> _buildArcs() {
    final rnd = math.Random(7);
    final arcs = <List<int>>[];
    while (arcs.length < 34) {
      final a = rnd.nextInt(_count);
      final b = rnd.nextInt(_count);
      final pa = _points[a];
      final pb = _points[b];
      final dx = pa[0] - pb[0], dy = pa[1] - pb[1], dz = pa[2] - pb[2];
      final d = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (d > 0.25 && d < 0.85) {
        arcs.add([a, b]);
      }
    }
    return arcs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final angle = animation.value * 2 * math.pi;
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    // Right-of-center, like the site (its globe group is offset to the right).
    final center = Offset(size.width * 0.74, size.height * 0.52);
    final radius = size.shortestSide * 0.62;

    final projected = List<Offset?>.filled(_count, null);
    final depth = List<double>.filled(_count, 0);
    for (var i = 0; i < _count; i++) {
      final p = _points[i];
      final x = p[0] * cosA + p[2] * sinA;
      final z = -p[0] * sinA + p[2] * cosA;
      projected[i] = center + Offset(x * radius, p[1] * radius);
      depth[i] = z; // -1 (back) .. 1 (front)
    }

    final baseOpacity = dark ? 1.0 : 0.55;

    // arcs first (behind dots)
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    for (final arc in _arcs) {
      final a = projected[arc[0]]!;
      final b = projected[arc[1]]!;
      final vis = (depth[arc[0]] + depth[arc[1]]) / 2;
      if (vis < -0.15) {
        continue;
      }
      arcPaint.color =
          accent.withValues(alpha: (0.05 + vis * 0.08) * baseOpacity);
      final mid = Offset.lerp(a, b, 0.5)!;
      final away = (mid - center);
      final ctrl = mid + away * 0.18;
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
      canvas.drawPath(path, arcPaint);
    }

    // dots
    final dotPaint = Paint();
    for (var i = 0; i < _count; i++) {
      final z = depth[i];
      final alpha = (0.05 + (z + 1) * 0.16) * baseOpacity;
      dotPaint.color = accent.withValues(alpha: alpha.clamp(0.02, 0.38));
      canvas.drawCircle(projected[i]!, 0.9 + (z + 1) * 0.8, dotPaint);
    }

    // a few glowing nodes (site look)
    final glowPaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    for (var i = 0; i < _count; i += 90) {
      final z = depth[i];
      if (z < 0.1) {
        continue;
      }
      glowPaint.color = accent.withValues(alpha: 0.30 * baseOpacity);
      canvas.drawCircle(projected[i]!, 3.4, glowPaint);
    }
  }

  @override
  bool shouldRepaint(_GlobePainter oldDelegate) =>
      oldDelegate.accent != accent || oldDelegate.dark != dark;
}
