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
//
// AXES
// Drawn through AxisLineChart: the y-axis is marked in the metric's own
// units and the x-axis in dates, so a seller reads WHEN a change happened
// and by how much, not just that the line went up.

import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;
import '../theme/motion.dart';
import 'axis_line_chart.dart';

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

  /// What the y-axis measures ("Rating out of 10", "Minutes").
  final String yTitle;

  /// True for whole-number metrics (deal counts, rank), so the y-axis is
  /// never marked 0.5 deals.
  final bool wholeNumbers;

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
    required this.yTitle,
    this.wholeNumbers = false,
    this.higherIsBetter = true,
    this.lineColor = BrokaColors.neonBlue,
    this.currentValue,
  });

  ChartBands get _bands =>
      ChartBands(good: goodThreshold, poor: poorThreshold, higherIsBetter: higherIsBetter);

  Widget _chart(BuildContext context, List<TrendPoint> real) {
    final dates = [for (final p in real) p.date];
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: BrokaMotion.reduced(context) ? Duration.zero : const Duration(milliseconds: 700),
      curve: BrokaMotion.enter,
      // Drawn to `t` so it traces in from the left: the motion carries the
      // direction of time, which is what the chart is about.
      builder: (_, t, __) => AxisLineChart(
        values: [for (final p in real) p.value!],
        positions: datePositions(dates),
        xTicks: dateTicks(dates),
        yFormat: format,
        xTitle: 'Date',
        yTitle: yTitle,
        lineColor: lineColor,
        bands: _bands,
        minStep: wholeNumbers ? 1 : 0,
        progress: t,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final real = points.where((p) => p.value != null).toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    if (real.length < 2) {
      // Not enough for a line, but not nothing either.
      //
      // Six cards reading "No history yet" taught a new seller nothing,
      // yet the numbers exist from day one - DCR starts at its prior, the
      // rating is computed the moment there is an account - and the BANDS
      // are useful immediately regardless of history.
      //
      // So: plot today's value against the bands, on today's date. No
      // trace is drawn; a horizontal line would read as "stable", which is
      // a claim one day cannot support.
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
            style: TextStyle(color: lineColor, fontSize: 13, fontWeight: FontWeight.w800)),
        footer: 'Tracking starts today - the line grows a point a day',
        child: _chart(context, [TrendPoint(DateTime.now(), today)]),
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
      child: _chart(context, real),
    );
  }
}

class _ChartFrame extends StatelessWidget {
  final String label;
  final Widget child;
  final Widget? trailing;
  final String? footer;
  const _ChartFrame({required this.label, required this.child, this.trailing, this.footer});

  @override
  Widget build(BuildContext context) => Container(
        height: footer == null ? 220 : 236,
        padding: const EdgeInsets.fromLTRB(10, 12, 14, 10),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Flexible(
                child: Text(label.toUpperCase(),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 10,
                        letterSpacing: 1.2, fontWeight: FontWeight.w700)),
              ),
              if (trailing != null) trailing!,
            ]),
          ),
          const SizedBox(height: 10),
          Expanded(child: child),
          if (footer != null) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(footer!,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 9.5)),
            ),
          ],
        ]),
      );
}
