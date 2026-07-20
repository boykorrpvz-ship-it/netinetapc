import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/vpn_product.dart';
import 'theme.dart';

/// Faithful port of the netineta.com network globe (globe.js / initGlobe):
/// a fibonacci sphere of 1600 dots, 42 bright node markers, curved routes
/// between each node's 3 nearest neighbours, and 16 glowing "packets" that
/// travel node-to-node along those routes. Slow Y rotation, fixed X tilt,
/// perspective camera at z=15 (fov 45°) — same constants as the site.
///
/// The animation lives in a single global [_GlobeSim] driven by one [Ticker],
/// so every screen paints the SAME frame: switching to Settings and back is
/// seamless — the sphere never restarts.
class GlobeBackground extends StatelessWidget {
  const GlobeBackground({required this.product, this.anchorX = 0.5, super.key});

  final VpnProduct product;

  /// Horizontal centre of the sphere as a fraction of the canvas width.
  /// The desktop layout passes the power-button median so both line up.
  final double anchorX;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _GlobePainter(
            sim: _GlobeSim.instance,
            accent: AppColors.accentFor(product),
            dark: AppColors.isDark,
            anchorX: anchorX,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Single always-running simulation shared by every [GlobeBackground].
/// Advances packets exactly once per frame regardless of how many painters
/// are mounted, and notifies them to repaint.
class _GlobeSim extends ChangeNotifier {
  _GlobeSim._();

  static final _GlobeSim instance = _GlobeSim._();

  final List<_Packet> packets =
      List.generate(_Geo.packetCount, (i) => _Packet.seeded(i));

  double elapsed = 0; // seconds since start

  /// Advance the shared simulation by [dt] seconds and repaint every painter.
  /// Driven by the single [GlobeAnimator]; painters never advance it, so N
  /// mounted globes still run at one speed.
  void advance(double dt) {
    if (dt <= 0 || dt > 0.25) {
      dt = 1 / 60;
    }
    elapsed += dt;
    for (final p in packets) {
      p.advance(dt);
    }
    notifyListeners();
  }
}

/// Invisible widget that ticks the shared globe simulation. Mount exactly one,
/// high enough in the tree that it stays alive while Settings is pushed on top
/// — that keeps the sphere's animation continuous across screen changes.
class GlobeAnimator extends StatefulWidget {
  const GlobeAnimator({super.key});

  @override
  State<GlobeAnimator> createState() => _GlobeAnimatorState();
}

class _GlobeAnimatorState extends State<GlobeAnimator>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration now) {
    final dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    _GlobeSim.instance.advance(dt);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Static geometry shared by all instances — mirrors globe.js exactly.
class _Geo {
  static const int dotCount = 1600; // N
  static const int nodeCount = 42; // NN
  static const int neighbours = 3; // K
  static const int packetCount = 16;
  static const double radius = 5.0; // R
  static const double camZ = 15.0;
  static const double tiltX = -0.15;
  static const double rotSpeed = 0.0016 * 60; // per second
  static const double packetSpeed = 0.0075 * 60; // t units per second

  static final List<_V3> dots = _fib(dotCount);
  static final List<_V3> nodes = _fib(nodeCount);
  static final List<_Edge> edges = _buildEdges();
  static final List<List<int>> adj = _buildAdj();

  static List<_V3> _fib(int n) {
    final golden = math.pi * (3 - math.sqrt(5));
    final out = <_V3>[];
    for (var i = 0; i < n; i++) {
      final y = 1 - (i / (n - 1)) * 2;
      final rad = math.sqrt(1 - y * y);
      final th = golden * i;
      out.add(
        _V3(math.cos(th) * rad * radius, y * radius, math.sin(th) * rad * radius),
      );
    }
    return out;
  }

  static List<_Edge> _buildEdges() {
    final edges = <_Edge>[];
    final seen = <String>{};
    for (var i = 0; i < nodeCount; i++) {
      final order = List.generate(nodeCount, (j) => j)
        ..remove(i)
        ..sort(
          (a, b) => nodes[i].dist(nodes[a]).compareTo(nodes[i].dist(nodes[b])),
        );
      for (var k = 0; k < neighbours; k++) {
        final j = order[k];
        final key = i < j ? '$i-$j' : '$j-$i';
        if (!seen.add(key)) {
          continue;
        }
        final p1 = nodes[i];
        final p2 = nodes[j];
        final mid = _V3(
          (p1.x + p2.x) / 2,
          (p1.y + p2.y) / 2,
          (p1.z + p2.z) / 2,
        );
        final lift = 1 + p1.dist(p2) / (radius * 2) * 1.15;
        final ctrl = mid.normalized().scale(radius * lift);
        edges.add(_Edge(i, j, ctrl));
      }
    }
    return edges;
  }

  static List<List<int>> _buildAdj() {
    final adj = List.generate(nodeCount, (_) => <int>[]);
    for (var e = 0; e < edges.length; e++) {
      adj[edges[e].a].add(e);
      adj[edges[e].b].add(e);
    }
    return adj;
  }
}

class _V3 {
  const _V3(this.x, this.y, this.z);
  final double x, y, z;

  double dist(_V3 o) {
    final dx = x - o.x, dy = y - o.y, dz = z - o.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  double get length => math.sqrt(x * x + y * y + z * z);
  _V3 normalized() {
    final l = length;
    return _V3(x / l, y / l, z / l);
  }

  _V3 scale(double s) => _V3(x * s, y * s, z * s);
}

class _Edge {
  const _Edge(this.a, this.b, this.ctrl);
  final int a;
  final int b;
  final _V3 ctrl;
}

class _Packet {
  _Packet.seeded(int i) : _rnd = math.Random(1000 + i) {
    edge = _rnd.nextInt(_Geo.edges.length);
    dir = _rnd.nextBool() ? 1 : -1;
    t = _rnd.nextDouble();
  }

  final math.Random _rnd;
  late int edge;
  late int dir;
  late double t;

  void advance(double dt) {
    t += _Geo.packetSpeed * dt;
    if (t >= 1) {
      t -= 1;
      final e = _Geo.edges[edge];
      final arrival = dir == 1 ? e.b : e.a;
      final options =
          _Geo.adj[arrival].where((ei) => ei != edge).toList(growable: false);
      final pool = options.isNotEmpty ? options : _Geo.adj[arrival];
      edge = pool[_rnd.nextInt(pool.length)];
      dir = _Geo.edges[edge].a == arrival ? 1 : -1;
    }
  }
}

class _GlobePainter extends CustomPainter {
  _GlobePainter({
    required this.sim,
    required this.accent,
    required this.dark,
    required this.anchorX,
  }) : super(repaint: sim);

  final _GlobeSim sim;
  final Color accent;
  final bool dark;
  final double anchorX;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final rotY = _Geo.rotSpeed * sim.elapsed;
    final cosY = math.cos(rotY), sinY = math.sin(rotY);
    const tilt = _Geo.tiltX;
    final cosX = math.cos(tilt), sinX = math.sin(tilt);

    final focal = size.height * 1.2071;
    final center = Offset(size.width * anchorX, size.height * 0.5);
    final dim = dark ? 1.0 : 0.5;

    Offset project(_V3 p, List<double> zOut) {
      final x1 = p.x * cosY + p.z * sinY;
      final z1 = -p.x * sinY + p.z * cosY;
      final y2 = p.y * cosX - z1 * sinX;
      final z2 = p.y * sinX + z1 * cosX;
      final f = focal / (_Geo.camZ - z2);
      zOut[0] = z2;
      zOut[1] = f;
      return Offset(center.dx + x1 * f, center.dy - y2 * f);
    }

    final z = List.filled(2, 0.0);

    // routes
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = accent.withValues(alpha: 0.16 * dim);
    final nodeScreens = List<Offset>.filled(_Geo.nodeCount, Offset.zero);
    final nodeF = List<double>.filled(_Geo.nodeCount, 1);
    for (var i = 0; i < _Geo.nodeCount; i++) {
      nodeScreens[i] = project(_Geo.nodes[i], z);
      nodeF[i] = z[1];
    }
    final edgeScreens = <int, List<Offset>>{};
    for (var e = 0; e < _Geo.edges.length; e++) {
      final edge = _Geo.edges[e];
      final a = nodeScreens[edge.a];
      final b = nodeScreens[edge.b];
      final c = project(edge.ctrl, z);
      edgeScreens[e] = [a, c, b];
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(c.dx, c.dy, b.dx, b.dy);
      canvas.drawPath(path, arcPaint);
    }

    // dotted sphere
    final dotPaint = Paint()..color = accent.withValues(alpha: 0.55 * dim);
    for (final p in _Geo.dots) {
      final o = project(p, z);
      final r = 0.025 * z[1];
      canvas.drawCircle(o, r.clamp(0.5, 3.0), dotPaint);
    }

    // bright node markers
    final nodePaint = Paint()..color = accent.withValues(alpha: 1.0 * dim);
    for (var i = 0; i < _Geo.nodeCount; i++) {
      canvas.drawCircle(nodeScreens[i], 0.055 * nodeF[i], nodePaint);
    }

    // travelling glow packets
    for (final p in sim.packets) {
      final pts = edgeScreens[p.edge]!;
      final tt = p.dir == 1 ? p.t : 1 - p.t;
      final omt = 1 - tt;
      final pos = Offset(
        omt * omt * pts[0].dx + 2 * omt * tt * pts[1].dx + tt * tt * pts[2].dx,
        omt * omt * pts[0].dy + 2 * omt * tt * pts[1].dy + tt * tt * pts[2].dy,
      );
      final fadeIn = math.min(1.0, p.t / 0.12);
      final fadeOut = math.min(1.0, (1 - p.t) / 0.4);
      final op = math.min(fadeIn, fadeOut).clamp(0.0, 1.0);
      if (op <= 0.01) {
        continue;
      }
      final worldScale = 0.14 + op * 0.16;
      final r = worldScale * focal / _Geo.camZ;
      final glow = Paint()
        ..blendMode = ui.BlendMode.plus
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.6)
        ..color = accent.withValues(alpha: 0.75 * op * dim);
      canvas.drawCircle(pos, r * 0.7, glow);
      final core = Paint()
        ..blendMode = ui.BlendMode.plus
        ..color = Color.lerp(accent, Colors.white, 0.55)!
            .withValues(alpha: 0.9 * op * dim);
      canvas.drawCircle(pos, r * 0.22, core);
    }
  }

  @override
  bool shouldRepaint(_GlobePainter oldDelegate) =>
      oldDelegate.accent != accent ||
      oldDelegate.dark != dark ||
      oldDelegate.anchorX != anchorX;
}
