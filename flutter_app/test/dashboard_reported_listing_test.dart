// A listing a buyer marked unavailable, on its seller's dashboard (reported
// 2026-11-13): the seller got the text saying they could revoke it there,
// opened the dashboard, and the listing was gone - the catalogue was read
// from the same list buyers browse. The server now keeps it in the owner's
// catalogue, flagged, and its card says so and offers "Still available".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/seller_dashboard_screen.dart';
import 'package:broka/services/api_service.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'seller-1';
    clearFakeRequests();
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/auth/user/seller-1') {
        return {'id': 'seller-1', 'name': 'Grace Akinyi', 'rating': 4.7, 'completed_deals': 3};
      }
      if (p == '/listings/' && uri.queryParameters['seller_id'] == 'seller-1') {
        return [
          {
            ...fakeListingJson(1),
            'name': 'Airtel Smart Connect',
            'seller_id': 'seller-1',
            'status': 'active',
            'sold_out': true,
            'reported_sold_out': true,
            'reported_at': '2026-11-13T15:00:00',
          },
          {...fakeListingJson(2), 'seller_id': 'seller-1', 'status': 'active'},
        ];
      }
      if (p == '/listings/reported-unavailable') return [];
      if (p == '/listings/listing-1/sold-out') {
        return {'listing_id': 'listing-1', 'reported_sold_out': false, 'reported_at': null};
      }
      if (p.endsWith('/revenue')) return {'total': 0, 'deals': 0, 'series': []};
      if (p.endsWith('/metrics')) return {'history': [], 'advice': []};
      return null;
    });
  });

  testWidgets('the reported listing is in the catalogue, and Still available revokes it',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SellerDashboardScreen(animateBackground: false)));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('dashboard-tab-1')));
    await _settle(tester);

    expect(find.text('Airtel Smart Connect'), findsOneWidget);
    expect(find.byKey(const Key('catalogue-reported-listing-1')), findsOneWidget);
    expect(find.byKey(const Key('catalogue-reported-listing-2')), findsNothing,
        reason: 'only the reported one says so');

    await tester.ensureVisible(find.byKey(const Key('catalogue-still-available-listing-1')));
    await tester.tap(find.byKey(const Key('catalogue-still-available-listing-1')));
    await _settle(tester);

    expect(
      fakeRequests.where((r) => r.method == 'DELETE' && r.uri.path == '/listings/listing-1/sold-out'),
      hasLength(1),
    );
    expect(find.textContaining('is back on sale'), findsOneWidget);
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
