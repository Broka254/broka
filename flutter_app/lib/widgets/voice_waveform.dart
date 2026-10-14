// lib/widgets/voice_waveform.dart
//
// The small bar waveform in the Zeno voice card's top row.
//
// Driven by real microphone loudness, not by a permanent animation: brief §17
// is explicit that this must not be a fake aggressive loop. When nobody is
// speaking the bars sit low and barely move; when someone speaks they track
// what the microphone is actually picking up. The only time it animates on its
// own is while processing or while Zeno is speaking, where there is no input
// level to show but something is genuinely happening.
//
// Isolated behind a RepaintBoundary and painted by a CustomPainter, so a frame
// of waveform repaints ~120x28 logical pixels rather than the conversation and
// the constellation field behind it.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../main.dart';

enum WaveformMode {
  /// Connected, nothing being said. Low, near-still.
  idle,

  /// Tracks [VoiceWaveform.level].
  speaking,

  /// A slow travelling wave: no input level to show, but work is happening.
  processing,
}

class VoiceWaveform extends StatefulWidget {
  const VoiceWaveform({
    super.key,
    required this.mode,
    this.level = 0,
    this.color,
    this.barCount = 13,
    this.height = 26,
  });

  final WaveformMode mode;

  /// 0..1 microphone loudness. Ignored unless [mode] is speaking.
  final double level;

  final Color? color;
  final int barCount;
  final double height;

  @override
  State<VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<VoiceWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  /// Smoothed bar heights. The raw level jumps per audio chunk; easing toward
  /// it is what makes this read as a level meter rather than a strobe.
  late final List<double> _bars = List<double>.filled(widget.barCount, 0.12);

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? BrokaColors.neonBlue;
    return RepaintBoundary(
      child: SizedBox(
        width: widget.barCount * 5.0,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _t,
          builder: (context, _) {
            _advance();
            return CustomPaint(
              painter: _WaveformPainter(List<double>.from(_bars), color),
            );
          },
        ),
      ),
    );
  }

  void _advance() {
    final phase = _t.value * 2 * math.pi;
    for (var i = 0; i < _bars.length; i++) {
      final double target;
      switch (widget.mode) {
        case WaveformMode.speaking:
          // A gentle bell across the bar row so the middle is tallest, scaled
          // by the real level, with a small per-bar wobble so it looks alive
          // rather than like a single scaled shape.
          final centre = 1 - (2 * (i / (_bars.length - 1)) - 1).abs();
          final wobble = 0.85 + 0.15 * math.sin(phase * 3 + i * 0.9);
          target = (0.12 + widget.level * 0.88 * (0.45 + 0.55 * centre)) * wobble;
        case WaveformMode.processing:
          target = 0.18 + 0.30 * (0.5 + 0.5 * math.sin(phase * 2 - i * 0.55));
        case WaveformMode.idle:
          target = 0.10 + 0.04 * (0.5 + 0.5 * math.sin(phase + i * 0.7));
      }
      // Rise quickly, fall slowly - how a level meter behaves, and it keeps a
      // consonant from vanishing before it is drawn.
      final current = _bars[i];
      _bars[i] = target > current
          ? current + (target - current) * 0.55
          : current + (target - current) * 0.18;
    }
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.bars, this.color);

  final List<double> bars;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final slot = size.width / bars.length;
    final barWidth = math.max(1.6, slot * 0.52);
    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < bars.length; i++) {
      final h = (bars[i].clamp(0.0, 1.0)) * size.height;
      final x = i * slot + (slot - barWidth) / 2;
      final y = (size.height - h) / 2;
      // Louder bars are brighter as well as taller, which reads better than
      // height alone at this size.
      paint.color = color.withOpacity(0.35 + 0.55 * bars[i].clamp(0.0, 1.0));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, math.max(2, h)),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.color != color || !_sameBars(old.bars, bars);

  static bool _sameBars(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 0.004) return false;
    }
    return true;
  }
}
