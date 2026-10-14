// Pictures of the AI cover looks, for choosing one.
//
// A seller picks the look of their cover by seeing it, not by reading a
// colour name: each look is painted as a small scene - its backdrop,
// surface and light, with a stand-in product - so "Warm Wood" shows a
// wooden table in window light and "Neon Tech" a glowing grid. They are
// drawn rather than bundled images: six photos would add a few hundred KB
// to every install for one screen, and a drawing can move (light sways,
// bokeh drifts, sparkles twinkle) off a single animation value, [t] in
// 0..1, looping.
import 'dart:math';

import 'package:flutter/material.dart';

/// The painter for the look with id [themeId] (ShowcaseGenerator.themes).
CustomPainter coverThemePainter(String themeId, double t) {
  switch (themeId) {
    case 'luxury':
      return _LuxuryScene(t);
    case 'wood':
      return _WoodScene(t);
    case 'nature':
      return _NatureScene(t);
    case 'neon':
      return _NeonScene(t);
    case 'pastel':
      return _PastelScene(t);
  }
  return _StudioScene(t);
}

abstract class _Scene extends CustomPainter {
  _Scene(this.t);
  final double t;

  double get wave => sin(t * 2 * pi);

  /// A stand-in product: a bottle with a small box beside it, standing on
  /// the floor at [floorY] (a fraction of the height), shaded as a cylinder.
  void product(Canvas canvas, Size size, {
    required Color body,
    required Color accent,
    double floorY = 0.8,
    Color shadow = const Color(0x55000000),
    bool reflection = false,
  }) {
    final w = size.width, h = size.height;
    final floor = h * floorY;
    final cx = w * 0.46;
    final bw = w * 0.22, bh = h * 0.40;

    // Contact shadow.
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx + w * 0.06, floor), width: w * 0.62, height: h * 0.05),
      Paint()
        ..color = shadow
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    void draw(Canvas c) {
      final bodyRect = Rect.fromLTWH(cx - bw / 2, floor - bh, bw, bh);
      final rr = RRect.fromRectAndRadius(bodyRect, Radius.circular(bw * 0.28));
      c.drawRRect(rr, Paint()
        ..shader = LinearGradient(colors: [
          Color.lerp(body, Colors.white, 0.35)!, body, Color.lerp(body, Colors.black, 0.35)!,
        ], stops: const [0, 0.45, 1]).createShader(bodyRect));
      // Label band.
      c.drawRect(
        Rect.fromLTWH(bodyRect.left, bodyRect.top + bh * 0.42, bw, bh * 0.2),
        Paint()..color = accent.withOpacity(0.85),
      );
      // Neck and cap.
      final neck = Rect.fromLTWH(cx - bw * 0.2, bodyRect.top - bh * 0.1, bw * 0.4, bh * 0.12);
      c.drawRect(neck, Paint()..color = Color.lerp(body, Colors.black, 0.15)!);
      c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(cx - bw * 0.25, neck.top - bh * 0.09, bw * 0.5, bh * 0.1),
            const Radius.circular(3)),
        Paint()..color = accent,
      );
      // Specular highlight.
      c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(bodyRect.left + bw * 0.16, bodyRect.top + bh * 0.08, bw * 0.08, bh * 0.8),
            const Radius.circular(4)),
        Paint()..color = Colors.white.withOpacity(0.35),
      );
      // The box beside it.
      final bs = w * 0.17;
      final box = Rect.fromLTWH(cx + bw * 0.62, floor - bs, bs, bs);
      c.drawRect(box, Paint()
        ..shader = LinearGradient(colors: [accent, Color.lerp(accent, Colors.black, 0.3)!])
            .createShader(box));
      final top = Path()
        ..moveTo(box.left, box.top)
        ..lineTo(box.left + bs * 0.25, box.top - bs * 0.2)
        ..lineTo(box.right + bs * 0.25, box.top - bs * 0.2)
        ..lineTo(box.right, box.top)
        ..close();
      c.drawPath(top, Paint()..color = Color.lerp(accent, Colors.white, 0.35)!);
      final side = Path()
        ..moveTo(box.right, box.top)
        ..lineTo(box.right + bs * 0.25, box.top - bs * 0.2)
        ..lineTo(box.right + bs * 0.25, box.bottom - bs * 0.2)
        ..lineTo(box.right, box.bottom)
        ..close();
      c.drawPath(side, Paint()..color = Color.lerp(accent, Colors.black, 0.45)!);
    }

    if (reflection) {
      canvas.save();
      canvas.translate(0, floor * 2);
      canvas.scale(1, -1);
      canvas.saveLayer(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white.withOpacity(0.22));
      draw(canvas);
      canvas.restore();
      canvas.restore();
    }
    draw(canvas);
  }

  @override
  bool shouldRepaint(covariant _Scene oldDelegate) => oldDelegate.t != t;
}

class _StudioScene extends _Scene {
  _StudioScene(super.t);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0xFFFFFFFF), Color(0xFFEFF1F6), Color(0xFFDDE1EA)],
        stops: [0, 0.72, 1],
      ).createShader(r));
    // Softbox glow, breathing.
    canvas.drawCircle(
      Offset(size.width * 0.5, -size.height * 0.05),
      size.width * (0.55 + 0.04 * wave),
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white, Colors.white.withOpacity(0),
        ]).createShader(Rect.fromCircle(
            center: Offset(size.width * 0.5, -size.height * 0.05), radius: size.width * 0.6)),
    );
    product(canvas, size, body: const Color(0xFF2B2F3A), accent: const Color(0xFF8B5CF6),
        shadow: const Color(0x40000000));
  }
}

class _LuxuryScene extends _Scene {
  _LuxuryScene(super.t);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()
      ..shader = const RadialGradient(
        center: Alignment(0, -0.2), radius: 0.9,
        colors: [Color(0xFF2E2416), Color(0xFF0A0806), Color(0xFF000000)],
        stops: [0, 0.6, 1],
      ).createShader(r));
    // Glossy floor.
    final floorRect = Rect.fromLTWH(0, size.height * 0.8, size.width, size.height * 0.2);
    canvas.drawRect(floorRect, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0xFF15110B), Color(0xFF000000)],
      ).createShader(floorRect));
    product(canvas, size, body: const Color(0xFF1C1C1E), accent: const Color(0xFFD4A94F),
        reflection: true, shadow: const Color(0x99000000));
    // Rim light.
    final rim = Rect.fromLTWH(size.width * 0.35, size.height * 0.36, size.width * 0.22, size.height * 0.44);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rim, Radius.circular(size.width * 0.06)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFD27A).withOpacity(0.55 + 0.25 * wave)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    // Gold sparkles.
    final rnd = Random(7);
    for (var i = 0; i < 9; i++) {
      final p = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height * 0.7);
      final a = (sin(t * 2 * pi + i * 1.3) + 1) / 2;
      _sparkle(canvas, p, 2.5 + 2.5 * a, const Color(0xFFFFE3A3).withOpacity(0.2 + 0.7 * a));
    }
  }

  void _sparkle(Canvas c, Offset p, double r, Color color) {
    final path = Path()
      ..moveTo(p.dx, p.dy - r)
      ..quadraticBezierTo(p.dx, p.dy, p.dx + r, p.dy)
      ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy + r)
      ..quadraticBezierTo(p.dx, p.dy, p.dx - r, p.dy)
      ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy - r);
    c.drawPath(path, Paint()..color = color);
  }
}

class _WoodScene extends _Scene {
  _WoodScene(super.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [Color(0xFFF6E7D2), Color(0xFFDDBF97)],
      ).createShader(r));
    // Window light, swaying.
    for (var i = 0; i < 3; i++) {
      final x = w * (0.05 + 0.18 * i) + w * 0.03 * wave;
      final ray = Path()
        ..moveTo(x, 0)
        ..lineTo(x + w * 0.1, 0)
        ..lineTo(x + w * 0.45, h * 0.72)
        ..lineTo(x + w * 0.3, h * 0.72)
        ..close();
      canvas.drawPath(ray, Paint()..color = Colors.white.withOpacity(0.18));
    }
    // A plant, out of focus.
    final leaf = Paint()
      ..color = const Color(0xFF4E7D3A).withOpacity(0.55)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    for (var i = 0; i < 5; i++) {
      canvas.save();
      canvas.translate(w * 0.14, h * 0.5);
      canvas.rotate(-0.9 + i * 0.4 + 0.04 * wave);
      canvas.drawOval(Rect.fromCenter(center: Offset(0, -h * 0.12), width: w * 0.08, height: h * 0.2), leaf);
      canvas.restore();
    }
    // The table.
    final table = Rect.fromLTWH(0, h * 0.72, w, h * 0.28);
    canvas.drawRect(table, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0xFF9A6534), Color(0xFF5C3818)],
      ).createShader(table));
    final grain = Paint()
      ..color = const Color(0xFF4A2C12).withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 6; i++) {
      final y = h * 0.75 + i * h * 0.04;
      final path = Path()..moveTo(0, y);
      for (var x = 0.0; x <= w; x += w / 12) {
        path.lineTo(x, y + sin(x / w * 6 + i) * 2);
      }
      canvas.drawPath(path, grain);
    }
    product(canvas, size, body: const Color(0xFFF3F1EA), accent: const Color(0xFFC4843E),
        floorY: 0.8, shadow: const Color(0x66301A08));
  }
}

class _NatureScene extends _Scene {
  _NatureScene(super.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0xFFBFE6FF), Color(0xFFE6F6DF), Color(0xFF9CCB7C)],
        stops: [0, 0.55, 1],
      ).createShader(r));
    // Sun flare.
    canvas.drawCircle(Offset(w * 0.85, h * 0.1), w * 0.35, Paint()
      ..shader = RadialGradient(colors: [
        const Color(0xFFFFF6C8).withOpacity(0.95), const Color(0xFFFFF6C8).withOpacity(0),
      ]).createShader(Rect.fromCircle(center: Offset(w * 0.85, h * 0.1), radius: w * 0.35)));
    // Bokeh, drifting.
    final rnd = Random(3);
    for (var i = 0; i < 12; i++) {
      final base = Offset(rnd.nextDouble() * w, rnd.nextDouble() * h * 0.7);
      final drift = Offset(sin(t * 2 * pi + i) * 6, cos(t * 2 * pi + i) * 3);
      canvas.drawCircle(base + drift, 4 + rnd.nextDouble() * 9, Paint()
        ..color = (i.isEven ? const Color(0xFF7BC96F) : const Color(0xFFE7F59E)).withOpacity(0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    }
    // Stone slab.
    final slab = RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.12, h * 0.78, w * 0.8, h * 0.08), const Radius.circular(6));
    canvas.drawRRect(slab, Paint()..color = const Color(0xFFBFC3B8));
    // Leaves in front.
    final leaf = Paint()..color = const Color(0xFF3F8F4A);
    for (var i = 0; i < 6; i++) {
      canvas.save();
      canvas.translate(w * (0.05 + i * 0.18), h);
      canvas.rotate(-0.5 + i * 0.2 + 0.05 * wave);
      canvas.drawOval(Rect.fromCenter(center: Offset(0, -h * 0.07), width: w * 0.1, height: h * 0.16), leaf);
      canvas.restore();
    }
    product(canvas, size, body: const Color(0xFFFAFAF7), accent: const Color(0xFF2E9E5B),
        floorY: 0.8, shadow: const Color(0x55284018));
  }
}

class _NeonScene extends _Scene {
  _NeonScene(super.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0xFF0B0620), Color(0xFF1B0B3D)],
      ).createShader(r));
    // Perspective grid on the floor.
    final horizon = h * 0.7;
    final grid = Paint()
      ..color = const Color(0xFFFF3FD8).withOpacity(0.35)
      ..strokeWidth = 1;
    for (var i = -6; i <= 6; i++) {
      canvas.drawLine(Offset(w / 2 + i * w * 0.04, horizon), Offset(w / 2 + i * w * 0.3, h), grid);
    }
    for (var i = 0; i < 5; i++) {
      final f = (i + t) / 5;
      final y = horizon + (h - horizon) * f * f;
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }
    // Neon ring behind the product, flickering slightly.
    final glow = sin(t * 2 * pi * 3) > 0.92 ? 0.8 : 1.0;
    canvas.drawCircle(Offset(w * 0.52, h * 0.5), w * 0.32, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = const Color(0xFF22D3EE).withOpacity(0.25 * glow)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(Offset(w * 0.52, h * 0.5), w * 0.32, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xFF7DF3FF).withOpacity(glow));
    // Magenta tube.
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.1, h * 0.12, 4, h * 0.5), const Radius.circular(2)),
      Paint()
        ..color = const Color(0xFFFF3FD8)
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4),
    );
    product(canvas, size, body: const Color(0xFF15151C), accent: const Color(0xFF22D3EE),
        floorY: 0.8, reflection: true, shadow: const Color(0x8822D3EE));
  }
}

class _PastelScene extends _Scene {
  _PastelScene(super.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [Color(0xFFFFD9CC), Color(0xFFE6D6FF)],
      ).createShader(r));
    // Arch and sun shapes behind.
    canvas.drawCircle(Offset(w * 0.72, h * 0.34), w * 0.28, Paint()..color = const Color(0xFFBFF0DC));
    final arch = Path()
      ..moveTo(w * 0.08, h * 0.72)
      ..lineTo(w * 0.08, h * 0.32)
      ..arcToPoint(Offset(w * 0.4, h * 0.32), radius: Radius.circular(w * 0.16))
      ..lineTo(w * 0.4, h * 0.72)
      ..close();
    canvas.drawPath(arch, Paint()..color = const Color(0xFFD9C2FF));
    // Floating spheres, bobbing.
    canvas.drawCircle(Offset(w * 0.86, h * 0.16 + 5 * wave), w * 0.05, Paint()..color = const Color(0xFFFF9EBB));
    canvas.drawCircle(Offset(w * 0.18, h * 0.16 - 4 * wave), w * 0.035, Paint()..color = const Color(0xFFFFE08A));
    // Podium.
    final top = Rect.fromCenter(center: Offset(w * 0.52, h * 0.8), width: w * 0.78, height: h * 0.08);
    final side = Rect.fromLTWH(top.left, top.center.dy, top.width, h * 0.1);
    final sidePaint = Paint()..color = const Color(0xFFA8E6CF);
    canvas.drawRect(side, sidePaint);
    canvas.drawOval(
        Rect.fromCenter(center: Offset(top.center.dx, side.bottom), width: top.width, height: top.height),
        sidePaint);
    canvas.drawOval(top, Paint()..color = const Color(0xFFCFF5E7));
    product(canvas, size, body: const Color(0xFFFFFFFF), accent: const Color(0xFFFF8FB1),
        floorY: 0.8, shadow: const Color(0x33A05080));
  }
}
