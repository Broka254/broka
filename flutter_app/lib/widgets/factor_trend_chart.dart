// BROKA — factor trend chart
//
// The banded line graph from the sketch: one metric over time, with two
// threshold lines cutting the plot into three regions so a seller can see
// at a glance whether they are in good, acceptable or poor territory
// without having to know what a "good" DCR is.
//
// THE BANDS ARE THE POINT
// A bare line answers "am I going up or down". The bands answer "is this
// number OK", which is the question a seller actually has and the one a
// raw figure cannot answer on its own — 82% means nothing until you know
// the platform expects 90.
//
// DIRECTION IS PER-METRIC, NOT GLOBAL
// For DCR and rating, higher is better and the green band is on top. For
// response time and rank position, LOWER is better and green is at the
// bottom. Getting this backwards would tell a seller their worsening reply
// time is an improvement, so it is an explicit flag on every chart rather
// than something inferred from the data.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;
import '../theme/motion.dart';

class TrendPoint {
  final DateTime date;
  final double? value;   // null = no snapshot that day
  const TrendPoint(this.date, this.value);
}

class FactorTrendChart extends StatelessWidget {
  final String label;
  final List<TrendPoint> points;

  /// Value above which the metric is healthy, and below which it is poor.
  /// Expressed in the metric's own units.
  final double goodThreshold;
  final double poorThreshold;

  /// False for metrics where a SMALLER number is better — response time,
  /// rank position. Flips which band is drawn on top.
  final bool higherIsBetter;

  /// Formats a value for the axis and the current-value chip.
  final String Function(double) format;

  final Color lineColor;

  /// Today's value, used when there is no history yet. See build().
  final double? currentValue;

  const FactorTrendChart({
    super.key,
    required this.label,
    required this.points,
    required this.goodThreshold,
    required this.poorThreshold,
    required this.format,
    this.higherIsBetter = true,
    this.lineColor = BrokaColors.neonBlue,
    this.currentValue,
  });

  @override
  Widget build(BuildContext context) {
    final real = points.where((p) => p.value != null).toList();

    if (real.length < 2) {
      // Not enough for a line, but not nothing either.
      //
      // Six cards reading "No history yet" taught a new seller nothing,
      // yet the numbers exist from day one - DCR starts at its prior, the
      // rating is computed the moment there is an account - and the BANDS
      // are useful immediately regardless of history.
      //
      // So: plot today's value against the bands. No trace is drawn; a
      // horizontal line would read as "stable", which is a claim one day
      // cannot support. But "am I in good territory" gets answered on the
      // first day, which is the more valuable half of this chart anyway.
      final today = currentValue ?? (real.isNotEmpty ? real.last.value : null);
      if (today == null) {
        return _ChartFrame(
          label: label,
          child: const Center(
            child: Text('Not measured yet',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 11)),
          ),
        );
      }
      return _ChartFrame(
        label: label,
        trailing: Text(format(today),
            style: TextStyle(color: lineColor, fontSize: 13,
                fontWeight: FontWeight.w800)),
        child: Stack(children: [
          Positioned.fill(child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: BrokaMotion.reduced(context)
                ? Duration.zero : const Duration(milliseconds: 700),
            curve: BrokaMotion.enter,
            builder: (_, t, __) => CustomPaint(
              painter: _TrendPainter(
                points: [TrendPoint(DateTime.now(), today)],
                goodThreshold: goodThreshold,
                poorThreshold: poorThreshold,
                higherIsBetter: higherIsBetter,
                lineColor: lineColor,
                progress: t,
              ),
              child: const SizedBox.expand(),
            ),
          )),
          const Positioned(
            left: 0, right: 0, bottom: 0,
            child: Text('Tracking starts today',
                textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textMid, fontSize: 9.5)),
          ),
        ]),
      );
    }

    final latest = real.last.value!;
    final first = real.first.value!;
    final delta = latest - first;
    final improving = higherIsBetter ? delta > 0 : delta < 0;
    final flat = delta.abs() < 1e-9;

    return _ChartFrame(
      label: label,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!flat)
          Icon(
            improving ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 12,
            color: improving ? BrokaColors.neonGreen : BrokaColors.danger,
          ),
        const SizedBox(width: 3),
        Text(format(latest),
            style: TextStyle(
                color: flat
                    ? BrokaColors.textMid
                    : (improving ? BrokaColors.neonGreen : BrokaColors.danger),
                fontSize: 13,
                fontWeight: FontWeight.w800)),
      ]),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: BrokaMotion.reduced(context)
            ? Duration.zero : const Duration(milliseconds: 700),
        curve: BrokaMotion.enter,
        builder: (_, t, __) => CustomPaint(
          painter: _TrendPainter(
            points: real,
            goodThreshold: goodThreshold,
            poorThreshold: poorThreshold,
            higherIsBetter: higherIsBetter,
            lineColor: lineColor,
            progress: t,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _ChartFrame extends StatelessWidget {
  final String label;
  final Widget child;
  final Widget? trailing;
  const _ChartFrame({required this.label, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) => Container(
        height: 168,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(label.toUpperCase(),
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 10,
                    letterSpacing: 1.2, fontWeight: FontWeight.w700)),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 10),
          Expanded(child: child),
        ]),
      );
}

class _TrendPainter extends CustomPainter {
  final List<TrendPoint> points;
  final double goodThreshold;
  final double poorThreshold;
  final bool higherIsBetter;
  final Color lineColor;
  final double progress;

  _TrendPainter({
    required this.points,
    required this.goodThreshold,
    required this.poorThreshold,
    required this.higherIsBetter,
    required this.lineColor,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final values = points.map((p) => p.value!).toList();

    // The band lines must be ON the chart even when every value sits on one
    // side of them — otherwise a seller who is consistently below the poor
    // line sees no line at all and loses the only context the chart offers.
    var lo = math.min(values.reduce(math.min),
        math.min(goodThreshold, poorThreshold));
    var hi = math.max(values.reduce(math.max),
        math.max(goodThreshold, poorThreshold));
    if ((hi - lo).abs() < 1e-9) { hi = lo + 1; }
    final pad = (hi - lo) * 0.12;
    lo -= pad; hi += pad;

    double y(double v) => size.height * (1 - (v - lo) / (hi - lo));
    double x(int i) => points.length == 1
        ? 0 : size.width * i / (points.length - 1);

    final goodY = y(goodThreshold);
    final poorY = y(poorThreshold);

    // ── Three regions ────────────────────────────────────────────────────
    // Painted as translucent fills rather than just two lines: the sketch
    // shows regions, and a seller should be able to see which one they are
    // sitting in peripherally, without tracing the line to an axis.
    final topRect    = Rect.fromLTRB(0, 0, size.width, math.min(goodY, poorY));
    final midRect    = Rect.fromLTRB(0, math.min(goodY, poorY), size.width,
                                     math.max(goodY, poorY));
    final bottomRect = Rect.fromLTRB(0, math.max(goodY, poorY), size.width,
                                     size.height);

    final goodFill = Paint()..color = BrokaColors.neonGreen.withOpacity(0.07);
    final midFill  = Paint()..color = BrokaColors.gold.withOpacity(0.05);
    final poorFill = Paint()..color = BrokaColors.danger.withOpacity(0.07);

    canvas.drawRect(topRect,    higherIsBetter ? goodFill : poorFill);
    canvas.drawRect(midRect,    midFill);
    canvas.drawRect(bottomRect, higherIsBetter ? poorFill : goodFill);

    // ── Threshold lines ──────────────────────────────────────────────────
    void dashed(double yy, Color c) {
      final p = Paint()..color = c.withOpacity(0.55)..strokeWidth = 1;
      const dash = 5.0, gap = 4.0;
      for (double dx = 0; dx < size.width; dx += dash + gap) {
        canvas.drawLine(Offset(dx, yy),
            Offset(math.min(dx + dash, size.width), yy), p);
      }
    }
    dashed(goodY, BrokaColors.neonGreen);
    dashed(poorY, BrokaColors.danger);

    // ── The line itself ──────────────────────────────────────────────────
    // Drawn to `progress` so it traces in from the left rather than
    // appearing whole — the motion carries the direction of time, which is
    // what the chart is about.
    // Lower bound 1, not 2: a single-point chart (day one) is a real
    // state, and clamping to 2 would index past the end of the list.
    final visible = (points.length * progress).ceil().clamp(1, points.length);
    if (visible == 1) {
      // Marker only - no trace and no gradient fill, since both would imply
      // a history that does not exist.
      final px = size.width / 2, py = y(values[0]);
      canvas.drawCircle(Offset(px, py), 7,
          Paint()..color = lineColor.withOpacity(0.25));
      canvas.drawCircle(Offset(px, py), 3.2, Paint()..color = lineColor);
      return;
    }
    final path = Path()..moveTo(x(0), y(values[0]));
    for (var i = 1; i < visible; i++) {
      // Straight segments, not a spline. A curved interpolation invents
      // values between snapshots that were never measured, and on a chart
      // whose whole job is honesty about a trend that is the wrong trade.
      path.lineTo(x(i), y(values[i]));
    }

    final fill = Path.from(path)
      ..lineTo(x(visible - 1), size.height)
      ..lineTo(x(0), size.height)
      ..close();
    canvas.drawPath(fill, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [lineColor.withOpacity(0.22), lineColor.withOpacity(0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)));

    canvas.drawPath(path, Paint()
      ..color = lineColor
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // Head marker, so "where am I now" is findable without reading the axis.
    final hx = x(visible - 1), hy = y(values[visible - 1]);
    canvas.drawCircle(Offset(hx, hy), 5, Paint()..color = lineColor.withOpacity(0.25));
    canvas.drawCircle(Offset(hx, hy), 2.6, Paint()..color = lineColor);
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.progress != progress || old.points != points;
}
