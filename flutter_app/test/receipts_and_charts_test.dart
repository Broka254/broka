// The Seller Dashboard's graphs and its Payment Receipts screen.
//
// What must hold:
//   * every graph is a line over time with both axes marked and titled:
//     values up the side, dates along the bottom;
//   * the y-axis is marked in round numbers that cover the data and the
//     bands, and counts are never marked in halves;
//   * the receipts screen lists listing fees and premium plans, with their
//     M-Pesa receipts, apart from the sales released to the seller.
import 'package:broka/screens/receipt_history_screen.dart';
import 'package:broka/widgets/axis_line_chart.dart';
import 'package:broka/widgets/factor_trend_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Frames enough for loads and short transitions. Not pumpAndSettle: the
/// receipts screen's ambient background never stops moving.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(WidgetTester tester, Widget child, {bool settle = true}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: child,
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _settle(tester);
  }
}

void main() {
  group('Axes', () {
    test('round ticks covering the data', () {
      expect(niceTicks(0, 9.3), [0, 2, 4, 6, 8, 10]);
      expect(niceTicks(3, 47), [0, 10, 20, 30, 40, 50]);
      expect(niceTicks(0, 2, minStep: 1), [0, 1, 2], reason: 'no half deals');
      expect(niceTicks(0, 0, minStep: 1), [0, 1], reason: 'a flat zero still has a scale');
    });

    test('dates sit where they fall, not one per slot', () {
      final d = DateTime(2026, 9, 1);
      final positions = datePositions([d, d.add(const Duration(days: 1)), d.add(const Duration(days: 10))]);
      expect(positions, [0, 0.1, 1]);
    });

    test('date labels run from the first day to the last', () {
      final ticks = dateTicks([DateTime(2026, 9, 1), DateTime(2026, 9, 30)]);
      expect(ticks.first.label, '1 Sep');
      expect(ticks.last.label, '30 Sep');
      expect(ticks.length, 4);
      expect(dateTicks([DateTime(2026, 9, 1), DateTime(2026, 9, 2)]).map((t) => t.label), ['1 Sep', '2 Sep'],
          reason: 'never two labels for the same day');
    });

    testWidgets('a trend graph titles both axes and plots its history', (tester) async {
      final start = DateTime(2026, 9, 1);
      await _open(tester, Scaffold(body: Padding(
        padding: const EdgeInsets.all(16),
        child: FactorTrendChart(
          label: 'Overall rating',
          points: [for (var i = 0; i < 10; i++) TrendPoint(start.add(Duration(days: i)), 5.0 + i * 0.2)],
          goodThreshold: 7, poorThreshold: 4,
          format: (v) => v.toStringAsFixed(1),
          yTitle: 'Rating out of 10',
        ),
      )));
      expect(find.byKey(const Key('chart-y-title')), findsOneWidget);
      expect(find.text('Rating out of 10'), findsOneWidget);
      expect(find.text('Date'), findsOneWidget);
      final painter = tester.widget<CustomPaint>(find.descendant(
              of: find.byType(AxisLineChart), matching: find.byType(CustomPaint)).first)
          .painter as AxisLineChartPainter;
      expect(painter.values.length, 10);
      expect(painter.xTicks.first.label, '1 Sep');
      expect(painter.xTicks.last.label, '10 Sep');
    });
  });

  group('Payment receipts', () {
    Map<String, dynamic> data() => {
          'receipts': [
            {'id': 's1', 'listing': 'Phone', 'buyer': 'Amina', 'amount': 20000, 'provider': 'M-Pesa',
              'reference': 'SALE1', 'paid_at': '2026-09-30T10:00:00'},
          ],
          'total': 20000,
          'count': 1,
          'charges': [
            {'id': 'c1', 'kind': 'premium', 'title': 'Premium plan', 'subject': 'BROKA Pro', 'detail': '1 month',
              'amount': 599, 'provider': 'M-Pesa', 'reference': 'PLAN456', 'paid_at': '2026-10-02T10:00:00'},
            {'id': 'c2', 'kind': 'listing_fee', 'title': 'Listing fee', 'subject': 'Calculator',
              'detail': '3 months + featured (KES 99)', 'amount': 950, 'provider': 'M-Pesa',
              'reference': 'FEE123', 'paid_at': '2026-10-01T10:00:00'},
          ],
          'charges_total': 1549,
        };

    testWidgets('listing fees and plans are on their own tab, with their receipts', (tester) async {
      await _open(tester, ReceiptHistoryScreen(loader: () async => data()), settle: false);
      expect(find.text('KES 20,000'), findsWidgets, reason: 'sales first, as before');
      expect(find.text('BROKA Pro'), findsNothing);

      await tester.tap(find.byKey(const Key('receipts-tab-1')));
      await _settle(tester);
      expect(find.byKey(const Key('charges-summary')), findsOneWidget);
      expect(find.text('KES 1,549'), findsOneWidget);
      expect(find.text('BROKA Pro'), findsOneWidget);
      expect(find.text('PLAN456'), findsOneWidget);
      expect(find.text('Calculator'), findsOneWidget);
      expect(find.text('3 months + featured (KES 99)'), findsOneWidget);
      expect(find.text('FEE123'), findsOneWidget);
      expect(find.text('Phone'), findsNothing, reason: 'a sale is not a fee');
    });

    testWidgets('an older server without charges shows none rather than failing', (tester) async {
      await _open(tester, ReceiptHistoryScreen(loader: () async => {'receipts': const [], 'total': 0}), settle: false);
      await tester.tap(find.byKey(const Key('receipts-tab-1')));
      await _settle(tester);
      expect(find.text('No listing fees or plans paid yet'), findsOneWidget);
    });
  });
}
