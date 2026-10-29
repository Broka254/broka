// Distinct store graphs (visits, product views, rating, reviews,
// response time — one graph each, like the seller dashboard) and the
// product card's composite /10 rating (reviews only contribute to it;
// a raw 5-star average is never the headline).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/listings/domain/models/listing.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/domain/models/store_insights.dart';
import 'package:broka/features/stores/presentation/widgets/store_performance.dart';
import 'package:broka/widgets/product_card.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _insightsJson() {
  final today = DateTime.now();
  String day(int back) =>
      today.subtract(Duration(days: back)).toIso8601String().substring(0, 10);
  Map<String, dynamic> kpi(int v) =>
      {'value': v, 'previous': 0, 'change_percent': null, 'exact': true};
  return {
    'store': {
      'id': 's1', 'name': 'Clanix', 'slug': 'clanix', 'is_active': true,
      'rating': 7.4,
      'rating_breakdown': {'review': 0.8, 'response': 0.7, 'tenure': 0.4},
      'rating_explanation': 'no reviews yet',
      'review_count': 3, 'response_minutes': 25.0,
      'rank': 1, 'stores_total': 4, 'products': 2, 'live_visitors': 0,
    },
    'period': {'days': 7, 'from': day(6), 'to': day(0)},
    'kpis': {
      'visits': kpi(5), 'product_views': kpi(9), 'saves': kpi(1),
      'likes': kpi(2), 'interested_buyers': kpi(1), 'chats': kpi(1),
      'messages': kpi(3), 'shares': kpi(0),
    },
    'series': {
      'visits': [for (var i = 6; i >= 0; i--) {'date': day(i), 'count': i}],
      'product_views': [for (var i = 6; i >= 0; i--) {'date': day(i), 'count': i * 2}],
      'chats': [for (var i = 6; i >= 0; i--) {'date': day(i), 'count': 0}],
      'rating': [for (var i = 6; i >= 0; i--) {'date': day(i), 'value': 6.5 + i * 0.1}],
      'reviews': [for (var i = 6; i >= 0; i--) {'date': day(i), 'count': i == 0 ? 1 : 0}],
      'response_minutes': [for (var i = 6; i >= 0; i--) {'date': day(i), 'value': 30.0 - i}],
    },
    'sources': {'visits_by_source': {}, 'visits_by_surface': {}, 'shares_by_channel': {}},
    'top_products': [],
    'advice': {'positives': [], 'negatives': []},
  };
}

void main() {
  test('insights parse the rating, reviews and response series', () {
    final data = StoreInsights.fromJson(_insightsJson());
    expect(data.ratingSeries, hasLength(7));
    expect(data.ratingSeries.first.value, closeTo(7.1, 0.001));
    expect(data.ratingSeries.last.value, closeTo(6.5, 0.001));
    expect(data.reviewSeries, hasLength(7));
    expect(data.reviewSeries.last.count, 1);
    expect(data.responseSeries, hasLength(7));
    expect(data.responseSeries.last.value, closeTo(30.0, 0.001));
  });

  testWidgets('the store dashboard draws five distinct graphs', (tester) async {
    final client = ApiClient(client: MockClient((req) async => http.Response(
        jsonEncode(_insightsJson()), 200,
        headers: {'content-type': 'application/json'})));
    final repo = StoresRepository(client: client);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StorePerformanceSection(
              storeId: 's1', repo: repo, animate: false),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    for (final key in const [
      'store-chart-visits', 'store-chart-views', 'store-chart-rating',
      'store-chart-reviews', 'store-chart-response',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    expect(find.text('STORE RATING'), findsOneWidget);
    expect(find.text('RESPONSE TIME'), findsOneWidget);
    // No old metric switcher behind which the other graphs hid.
    expect(find.byKey(const Key('metric-visits')), findsNothing);
  });

  testWidgets('a card shows the composite /10, never the raw 5-star average', (tester) async {
    final listing = BrokaListing.fromJson({
      ...fakeListingJson(1, sellerRating: 5.0, sellerReviewCount: 1),
      'seller_overall_rating': 6.8,
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(
        width: 180, height: 320,
        child: ProductCard(item: listing, onTap: () {}),
      ))),
    ));
    expect(find.byKey(const Key('product-card-rating')), findsOneWidget);
    expect(find.text('6.8/10 (1)'), findsOneWidget);
    expect(find.text('5.0 (1)'), findsNothing);
  });

  testWidgets("a store card shows the store's /10 ahead of the seller's", (tester) async {
    final listing = BrokaListing.fromJson({
      ...fakeListingJson(1, sellerRating: 5.0, sellerReviewCount: 1),
      'seller_overall_rating': 6.8,
      'store_id': 's1', 'store_name': 'Clanix Electronics', 'store_slug': 'clanix',
      'store_rating': 8.2, 'store_review_count': 4,
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(
        width: 180, height: 320,
        child: ProductCard(item: listing, onTap: () {}),
      ))),
    ));
    expect(find.text('8.2/10'), findsOneWidget);
  });
}
