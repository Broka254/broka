// BROKA — line chart with axes
//
// One series over time, drawn the way a chart is read: a y-axis with its
// values marked, an x-axis with its dates marked, and both axes titled.
//
// The dashboard's graphs used to be bare traces. A line with no scale says
// "up" or "down" and nothing else - a seller could not tell whether a
// rating moved from 6.1 to 6.3 or from 2 to 9, nor which day a change
// happened - so every graph on it now goes through this painter.
//
// Points are placed by their DATE, not their index: snapshots can skip days
// (no snapshot is taken for a day the worker did not run), and spacing them
// evenly would draw a week's gap as if it were one day.
//
// Optional bands (good / acceptable / poor) are shaded behind the line for
// metrics with a known healthy range - see FactorTrendChart.
//
// THE LOOK (2026-10-09). The traces were a flat 2px line on a grey grid,
// which read as a spreadsheet rather than the rest of the app. Now: the
// line glows (a blurred copy under it) and runs a gradient from the
// series colour into a lighter tint of it, the area under it fades in
// three steps, the grid is a faint dashed one that stays behind the data,
// each measurement is a hollow neon dot, and the latest one carries a halo,
// a guide down to the date axis and, where asked, its value. Nothing
// about WHAT is drawn changed: same scale, same dates, same straight
// segments.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;

/// The good / poor thresholds of a metric, and which way is better.
class ChartBands {
  final double good;
  final double poor;

  /// False when a SMALLER number is better (response time, rank).
  final bool higherIsBetter;
  const ChartBands({required this.good, required this.poor, this.higherIsBetter = true});
}

/// A labelled mark along the x-axis, at [position] (0 = left, 1 = right).
class AxisTick {
  final double position;
  final String label;
  const AxisTick(this.position, this.label);
}

const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "3 Oct" - short enough that five fit under a phone-width chart.
String shortDate(DateTime d) => '${d.day} ${_monthNames[d.month - 1]}';

/// Where each date sits along the x-axis, from the first to the last.
List<double> datePositions(List<DateTime> dates) {
  if (dates.length < 2) return [for (final _ in dates) 0.5];
  final first = dates.first.millisecondsSinceEpoch.toDouble();
  final span = dates.last.millisecondsSinceEpoch - first;
  if (span <= 0) return [for (var i = 0; i < dates.length; i++) dates.length == 1 ? 0.5 : i / (dates.length - 1)];
  return [for (final d in dates) (d.millisecondsSinceEpoch - first) / span];
}

/// Up to [count] evenly spread date labels between the first and last date.
List<AxisTick> dateTicks(List<DateTime> dates, {int count = 4}) {
  if (dates.isEmpty) return const [];
  if (dates.length == 1) return [AxisTick(0.5, shortDate(dates.first))];
  final first = dates.first, last = dates.last;
  final days = last.difference(first).inDays;
  // Never more labels than days, or two would read the same date.
  final n = math.max(2, math.min(count, days + 1));
  return [
    for (var i = 0; i < n; i++)
      AxisTick(i / (n - 1),
          shortDate(first.add(Duration(milliseconds: (last.difference(first).inMilliseconds * i / (n - 1)).round())))),
  ];
}

/// Round tick values covering [lo]..[hi]: 0, 5, 10, 15 rather than 0, 4.3, 8.6.
/// [minStep] stops counts from getting fractional ticks (0, 0.5, 1).
List<double> niceTicks(double lo, double hi, {int target = 4, double minStep = 0}) {
  if ((hi - lo).abs() < 1e-9) hi = lo + math.max(1.0, minStep);
  // Slightly under the even split, so 3..47 gets 0, 10 .. 50 rather than
  // 0, 20 .. 60 with a third of the chart empty.
  final raw = (hi - lo) / target * 0.8;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  var step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * mag;
  if (step < minStep) step = minStep;
  final start = (lo / step).floor() * step;
  final end = (hi / step).ceil() * step;
  return [for (var v = start; v <= end + step * 1e-6; v += step) double.parse(v.toStringAsFixed(6))];
}

class AxisLineChartPainter extends CustomPainter {
  final List<double> values;

  /// Each value's place along the x-axis, 0..1. Same length as [values].
  final List<double> positions;
  final List<AxisTick> xTicks;
  final String Function(double) yFormat;
  final Color lineColor;
  final ChartBands? bands;

  /// Always include this value on the y-axis - 0 for money and counts, so
  /// a quiet week is drawn at the bottom rather than stretched to fill.
  final double? yFloor;
  final double minStep;

  /// 0..1: how much of the line is drawn, so it traces in from the left.
  final double progress;

  /// Label the latest point with its value, in a small bubble above it.
  final bool showLastValue;

  AxisLineChartPainter({
    required this.values,
    required this.positions,
    required this.xTicks,
    required this.yFormat,
    required this.lineColor,
    this.bands,
    this.yFloor,
    this.minStep = 0,
    this.progress = 1,
    this.showLastValue = false,
  }) : assert(values.length == positions.length);

  static const _label = TextStyle(color: BrokaColors.textMid, fontSize: 9);

  TextPainter _text(String s) =>
      TextPainter(text: TextSpan(text: s, style: _label), textDirection: TextDirection.ltr)..layout();

  @override
  void paint(Canvas canvas, Size size) {
    // ── Scale ────────────────────────────────────────────────────────────
    var lo = values.isEmpty ? 0.0 : values.reduce(math.min);
    var hi = values.isEmpty ? 1.0 : values.reduce(math.max);
    if (bands != null) {
      // The band lines must be ON the chart even when every value sits on
      // one side of them, or a seller below the poor line loses the only
      // context the chart offers.
      lo = math.min(lo, math.min(bands!.good, bands!.poor));
      hi = math.max(hi, math.max(bands!.good, bands!.poor));
    }
    if (yFloor != null) {
      lo = math.min(lo, yFloor!);
      hi = math.max(hi, yFloor!);
    }
    final ticks = niceTicks(lo, hi, minStep: minStep);
    lo = ticks.first;
    hi = ticks.last;

    // ── Plot area: room on the left for the values, below for the dates ──
    final yLabels = [for (final t in ticks) _text(yFormat(t))];
    final left = yLabels.map((l) => l.width).reduce(math.max) + 8;
    const bottomGap = 16.0, top = 6.0, right = 8.0;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottomGap);
    double y(double v) => plot.bottom - plot.height * (v - lo) / (hi - lo);
    double x(double p) => plot.left + plot.width * p;

    // ── Bands ────────────────────────────────────────────────────────────
    if (bands != null) {
      final goodY = y(bands!.good).clamp(plot.top, plot.bottom);
      final poorY = y(bands!.poor).clamp(plot.top, plot.bottom);
      final upper = math.min(goodY, poorY), lower = math.max(goodY, poorY);
      // Each band fades toward the middle of the chart rather than sitting
      // as a flat block of colour - present, but behind the line.
      Paint band(Color c, Rect r, {required bool fromTop}) => Paint()
        ..shader = LinearGradient(
          begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
          end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [c.withOpacity(0.13), c.withOpacity(0.03)],
        ).createShader(r);
      final topRect = Rect.fromLTRB(plot.left, plot.top, plot.right, upper);
      final bottomRect = Rect.fromLTRB(plot.left, lower, plot.right, plot.bottom);
      final topColor = bands!.higherIsBetter ? BrokaColors.neonGreen : BrokaColors.danger;
      final bottomColor = bands!.higherIsBetter ? BrokaColors.danger : BrokaColors.neonGreen;
      if (topRect.height > 0) canvas.drawRect(topRect, band(topColor, topRect, fromTop: true));
      canvas.drawRect(Rect.fromLTRB(plot.left, upper, plot.right, lower),
          Paint()..color = BrokaColors.gold.withOpacity(0.035));
      if (bottomRect.height > 0) {
        canvas.drawRect(bottomRect, band(bottomColor, bottomRect, fromTop: false));
      }
      _dashed(canvas, plot, goodY, BrokaColors.neonGreen);
      _dashed(canvas, plot, poorY, BrokaColors.danger);
    }

    // ── Grid and y-axis values ───────────────────────────────────────────
    for (var i = 0; i < ticks.length; i++) {
      final ty = y(ticks[i]);
      if (i > 0) _dotted(canvas, plot.left, plot.right, ty, BrokaColors.textMid.withOpacity(0.16));
      final l = yLabels[i];
      l.paint(canvas, Offset(left - 6 - l.width, ty - l.height / 2));
    }

    // ── Axes ─────────────────────────────────────────────────────────────
    // A faint y-axis, and a baseline that glows faintly in the series colour.
    final axis = Paint()..color = BrokaColors.textMid.withOpacity(0.35)..strokeWidth = 1;
    canvas.drawLine(plot.topLeft, plot.bottomLeft, axis);
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, Paint()
      ..strokeWidth = 1
      ..shader = LinearGradient(colors: [
        BrokaColors.textMid.withOpacity(0.45),
        lineColor.withOpacity(0.55),
        BrokaColors.textMid.withOpacity(0.25),
      ]).createShader(Rect.fromLTRB(plot.left, plot.bottom - 1, plot.right, plot.bottom + 1)));

    // ── x-axis dates ─────────────────────────────────────────────────────
    for (final t in xTicks) {
      final tx = x(t.position);
      canvas.drawLine(Offset(tx, plot.bottom), Offset(tx, plot.bottom + 3), axis);
      final l = _text(t.label);
      // Kept inside the chart: the first and last label would otherwise
      // hang half off its edges.
      final lx = (tx - l.width / 2).clamp(0.0, size.width - l.width);
      l.paint(canvas, Offset(lx, plot.bottom + 4));
    }

    if (values.isEmpty) return;

    // ── The line ─────────────────────────────────────────────────────────
    final visible = (values.length * progress).ceil().clamp(1, values.length);
    final pts = [for (var i = 0; i < visible; i++) Offset(x(positions[i]), y(values[i]))];
    final light = Color.lerp(lineColor, Colors.white, 0.45)!;
    if (pts.length > 1) {
      // Straight segments, not a spline: a curve invents values between
      // measurements that were never taken.
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      final fill = Path.from(path)
        ..lineTo(pts.last.dx, plot.bottom)
        ..lineTo(pts.first.dx, plot.bottom)
        ..close();
      canvas.drawPath(fill, Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [lineColor.withOpacity(0.34), lineColor.withOpacity(0.10), lineColor.withOpacity(0.0)],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(plot));
      // The glow: a wide, blurred copy of the line beneath it.
      canvas.drawPath(path, Paint()
        ..color = lineColor.withOpacity(0.55)
        ..strokeWidth = 6
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawPath(path, Paint()
        ..shader = LinearGradient(colors: [lineColor, light]).createShader(plot)
        ..strokeWidth = 2.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round);
    }
    // A dot on every measurement when there are few enough to tell apart,
    // so a reader can see where the values are, not just the line between.
    // Hollow, with the card's colour inside, so the line reads through it.
    final dots = pts.length <= 31;
    for (var i = 0; i < pts.length - 1; i++) {
      if (!dots) break;
      canvas.drawCircle(pts[i], 3.0, Paint()..color = lineColor);
      canvas.drawCircle(pts[i], 1.6, Paint()..color = BrokaColors.bgCard);
    }

    // The latest measurement: a guide down to its date, a halo, and a
    // bright core.
    final lastPt = pts.last;
    _dotted(canvas, lastPt.dy, plot.bottom, lastPt.dx, lineColor.withOpacity(0.45), vertical: true);
    canvas.drawCircle(lastPt, 11, Paint()
      ..color = lineColor.withOpacity(0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(lastPt, 6.5, Paint()..color = lineColor.withOpacity(0.28));
    canvas.drawCircle(lastPt, 4, Paint()..color = lineColor);
    canvas.drawCircle(lastPt, 1.8, Paint()..color = Colors.white);

    if (showLastValue && visible == values.length) {
      final tp = TextPainter(
        text: TextSpan(text: yFormat(values[visible - 1]), style: const TextStyle(
            color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800)),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = tp.width + 12, h = tp.height + 6;
      final bx = (lastPt.dx - w / 2).clamp(plot.left, size.width - w);
      // Above the point, or below it when it is at the top of the chart.
      final by = lastPt.dy - h - 10 < 0 ? lastPt.dy + 10 : lastPt.dy - h - 10;
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, w, h), const Radius.circular(7));
      canvas.drawRRect(r, Paint()..shader = LinearGradient(colors: [
        lineColor.withOpacity(0.9), Color.lerp(lineColor, BrokaColors.neonPurple, 0.5)!.withOpacity(0.9),
      ]).createShader(r.outerRect));
      tp.paint(canvas, Offset(bx + 6, by + 3));
    }
  }

  /// A faint dotted rule, horizontal at [at] from [from] to [to], or
  /// vertical when [vertical].
  void _dotted(Canvas canvas, double from, double to, double at, Color c, {bool vertical = false}) {
    final p = Paint()..color = c..strokeWidth = 1..strokeCap = StrokeCap.round;
    const dash = 2.0, gap = 4.0;
    for (double d = from; d < to; d += dash + gap) {
      final e = math.min(d + dash, to);
      canvas.drawLine(vertical ? Offset(at, d) : Offset(d, at), vertical ? Offset(at, e) : Offset(e, at), p);
    }
  }

  void _dashed(Canvas canvas, Rect plot, double yy, Color c) {
    final p = Paint()..color = c.withOpacity(0.55)..strokeWidth = 1;
    const dash = 5.0, gap = 4.0;
    for (double dx = plot.left; dx < plot.right; dx += dash + gap) {
      canvas.drawLine(Offset(dx, yy), Offset(math.min(dx + dash, plot.right), yy), p);
    }
  }

  @override
  bool shouldRepaint(AxisLineChartPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.values != values ||
      oldDelegate.positions != positions || oldDelegate.lineColor != lineColor;
}

/// The painter with its axis titles: [yTitle] up the left side, [xTitle]
/// under the dates.
class AxisLineChart extends StatelessWidget {
  final List<double> values;
  final List<double> positions;
  final List<AxisTick> xTicks;
  final String Function(double) yFormat;
  final String xTitle;
  final String yTitle;
  final Color lineColor;
  final ChartBands? bands;
  final double? yFloor;
  final double minStep;
  final double progress;
  final bool showLastValue;

  const AxisLineChart({
    super.key,
    required this.values,
    required this.positions,
    required this.xTicks,
    required this.yFormat,
    required this.xTitle,
    required this.yTitle,
    this.lineColor = BrokaColors.neonBlue,
    this.bands,
    this.yFloor,
    this.minStep = 0,
    this.progress = 1,
    this.showLastValue = false,
  });

  static const _title = TextStyle(color: BrokaColors.textMid, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.4);

  @override
  Widget build(BuildContext context) => Column(children: [
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            RotatedBox(
              quarterTurns: 3,
              child: Center(child: Text(yTitle, key: const Key('chart-y-title'), style: _title)),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: CustomPaint(
                painter: AxisLineChartPainter(
                  values: values,
                  positions: positions,
                  xTicks: xTicks,
                  yFormat: yFormat,
                  lineColor: lineColor,
                  bands: bands,
                  yFloor: yFloor,
                  minStep: minStep,
                  progress: progress,
                  showLastValue: showLastValue,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 2),
        Text(xTitle, key: const Key('chart-x-title'), style: _title),
      ]);
}
