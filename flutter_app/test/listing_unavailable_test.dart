// A listing a buyer marked unavailable (2026-11-12, backend
// listings/sold_out.py): it was out of every list, the seller's own
// dashboard included, and the push about it opened nothing - a seller whose
// item was still for sale could not find it to say so. The push now opens
// the dashboard, and the dashboard lists it with "Still available".
//
// Also here: the seller's number as the listing screen shows it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/seller_dashboard/presentation/reported_unavailable_panel.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:broka/utils/phone_format.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _reported(String id, {String name = 'Oraimo Spacebuds', int reports = 1}) => {
      'id': id,
      'name': name,
      'category': 'Electronics',
      'price': 1500,
      'listing_type': 'direct',
      'status': 'active',
      'seller_id': 'seller-1',
      'views': 3,
      'sold_out': true,
      'reported_sold_out': true,
      'reported_at': DateTime.now().toUtc().subtract(const Duration(hours: 2))
          .toIso8601String().replaceAll('Z', ''),
      'open_reports': reports,
    };

void main() {
  setUpAll(installFakeApi);

  setUp(() async {
    clearFakeRequests();
    SharedPreferences.setMockInitialValues({'auth_token': 'tok', 'user_id': 'seller-1', 'user_name': 'Xavier'});
    await ApiService.loadSavedSession();
  });

  tearDown(() => setFakeRoute(null));

  group('the push about it', () {
    Future<List<String>> tapPush(WidgetTester tester, Map<String, dynamic> data) async {
      final key = GlobalKey<NavigatorState>();
      NotificationService.instance.navigatorKey = key;
      final opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        home: const SizedBox(),
        onGenerateRoute: (s) {
          opened.add(s.name ?? '');
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
      ));
      await NotificationService.instance.navigateFromPayload(data);
      await tester.pump();
      return opened;
    }

    testWidgets('opens the seller dashboard, where the listing is', (tester) async {
      // What listings/sold_out.py sends the seller.
      final opened = await tapPush(tester, {
        'type': 'listing_sold_out_reported',
        'listing_id': 'listing-9',
        'listing_name': 'Oraimo Spacebuds',
      });
      expect(opened, ['/seller-dashboard']);
    });

    testWidgets('a signed-out phone signs in first', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await ApiService.loadSavedSession();
      final opened = await tapPush(tester, {'type': 'listing_sold_out_reported', 'listing_id': 'listing-9'});
      expect(opened, ['/auth']);
    });
  });

  group("the dashboard's list of them", () {
    Future<void> show(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: ReportedUnavailablePanel())),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('lists each one, and Still available puts it back on sale', (tester) async {
      var reported = [_reported('listing-9'), _reported('listing-10', name: 'JBL Flip 5', reports: 2)];
      setFakeRoute((uri) {
        if (uri.path == '/listings/reported-unavailable') return reported;
        if (uri.path == '/listings/listing-9/sold-out') {
          reported = [reported.last];
          return {'listing_id': 'listing-9', 'reported_sold_out': false, 'reported_at': null};
        }
        return null;
      });
      await show(tester);
      expect(find.byKey(const Key('reported-unavailable-panel')), findsOneWidget);
      expect(find.text('Buyers marked 2 listings unavailable'), findsOneWidget);
      expect(find.text('Oraimo Spacebuds'), findsOneWidget);
      expect(find.textContaining('Hidden since 2h ago'), findsWidgets);
      expect(find.textContaining('2 buyers'), findsOneWidget);

      await tester.tap(find.byKey(const Key('reported-still-available-listing-9')));
      await tester.pumpAndSettle();
      final sent = fakeRequests.where((r) => r.method == 'DELETE').toList();
      expect(sent.map((r) => r.uri.path), ['/listings/listing-9/sold-out']);
      expect(find.text('Oraimo Spacebuds'), findsNothing);
      expect(find.text('JBL Flip 5'), findsOneWidget);
      expect(find.textContaining('back on sale'), findsOneWidget);
    });

    testWidgets("It's sold asks first, then removes it", (tester) async {
      setFakeRoute((uri) {
        if (uri.path == '/listings/reported-unavailable') return [_reported('listing-9')];
        if (uri.path == '/listings/listing-9') return {'deleted': true, 'listing_id': 'listing-9'};
        return null;
      });
      await show(tester);
      await tester.tap(find.byKey(const Key('reported-sold-listing-9')));
      await tester.pumpAndSettle();
      expect(fakeRequests.where((r) => r.method == 'DELETE'), isEmpty, reason: 'nothing before the answer');
      await tester.tap(find.byKey(const Key('confirm-remove-reported')));
      await tester.pumpAndSettle();
      expect(fakeRequests.where((r) => r.method == 'DELETE').map((r) => r.uri.path), ['/listings/listing-9']);
      expect(find.byKey(const Key('reported-unavailable-panel')), findsNothing);
    });

    testWidgets('draws nothing when none are reported - or for rows that are not reports',
        (tester) async {
      // The fake answers every /listings path with ordinary listings: none
      // of those carries reported_at, so none is shown as a report.
      await show(tester);
      expect(find.byKey(const Key('reported-unavailable-panel')), findsNothing);
    });
  });

  group("the seller's number", () {
    test('reads as a Kenyan number however it was stored', () {
      for (final raw in ['0712345678', '254712345678', '+254712345678', '+254 712 345 678', '712345678']) {
        expect(formatPhone(raw), '+254 712 345 678', reason: raw);
        expect(dialablePhone(raw), '+254712345678', reason: raw);
      }
      expect(formatPhone('0110123456'), '+254 110 123 456');
      // Not Kenyan: as it came.
      expect(formatPhone('+44 20 7946 0958'), '+44 20 7946 0958');
      expect(dialablePhone('+44 20 7946 0958'), '+442079460958');
    });
  });
}
