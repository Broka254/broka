// The user profile (2026-09-30): on Home's visual system, showing only
// figures the API returns, and reviews that load - with "Write a review"
// offered only to a buyer whose deal with the seller completed.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/main.dart' show BrokaColors, ZoneGlowText;
import 'package:broka/screens/user_profile_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/constellation_background.dart';

import 'support/fake_api.dart';

/// A seller's profile as GET /auth/user/{id} returns it to someone else.
Map<String, dynamic> _seller({Map<String, dynamic> extra = const {}}) => {
      'id': 'seller-1',
      'name': 'Grace Akinyi',
      'nickname': null,
      'account_type': 'buyer_seller',
      'business_location': 'Westlands, Nairobi',
      'rating': 5.0,
      'completed_deals': 14,
      'is_verified': true,
      'profile_photo': null,
      'last_seen': '2026-09-30T13:05:00',
      'is_online': false,
      'last_seen_label': 'Active 12m ago',
      'created_at': '2026-03-02T09:00:00',
      'distance_km': 3.4,
      'escrow_success_rate_pct': 92.9,
      'dispute_rate_pct': 7.1,
      'avg_deal_time_minutes': 2880.0,
      'timed_deals': 3,
      'seller_standing': {
        'overall_rating': 8.5,
        'dcr': 92.3,
        'dcr_provisional': false,
        'median_response_minutes': 25.0,
        'completed_deals': 14,
        'as_of': '2026-09-29',
      },
      ...extra,
    };

const _summary = {
  'avg': 4.5,
  'count': 2,
  'distribution': {'1': 0, '2': 0, '3': 0, '4': 1, '5': 1},
};

const _reviews = [
  {'id': 'r1', 'rating': 5, 'comment': 'Phone exactly as described.',
   'reviewer_name': 'Amina W.', 'created_at': '2026-09-20T10:00:00'},
  {'id': 'r2', 'rating': 4, 'comment': '', 'reviewer_name': 'Brian O.',
   'created_at': '2026-09-10T10:00:00'},
];

Map<String, dynamic> _deal({bool reviewed = false}) => {
      'deal_id': 'deal-9', 'seller_id': 'seller-1', 'seller_name': 'Grace Akinyi',
      'listing_name': 'Samsung A54', 'agreed_price': 32000, 'created_at': '2026-09-01T10:00:00',
      'completed_at': '2026-09-03T10:00:00', 'already_reviewed': reviewed,
    };

void main() {
  setUpAll(() async {
    installFakeApi();
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts';
    if (Directory(fonts).existsSync()) {
      final roboto = FontLoader('Roboto');
      for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
        roboto.addFont(Future.value(ByteData.view(File('$fonts/$f').readAsBytesSync().buffer)));
      }
      await roboto.load();
    }
  });

  Future<void> signIn(String userId) async {
    SharedPreferences.setMockInitialValues({'auth_token': 'tok', 'user_id': userId, 'user_name': 'Me'});
    await ApiService.loadSavedSession();
  }

  /// The backend as a buyer [myDeals] from this seller sees it.
  void backend({
    Map<String, dynamic>? profile,
    Object? summary = _summary,
    Object? reviews = _reviews,
    List<Map<String, dynamic>> myDeals = const [],
    List<Map<String, dynamic>> listings = const [],
  }) {
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/auth/user/seller-1') return profile ?? _seller();
      if (p == '/reviews/summary/seller-1') return summary;
      if (p == '/reviews/seller/seller-1') return reviews;
      if (p == '/reviews/my-deals') return {'deals': myDeals};
      if (p == '/listings/') return listings;
      return null;
    });
  }

  setUp(() async {
    await signIn('buyer-1');
    clearFakeRequests();
    backend();
  });

  tearDown(() => setFakeRoute(null));

  /// The profile as the app opens it: a named route with the user's id.
  Future<List<RouteSettings>> open(WidgetTester tester, {String userId = 'seller-1'}) async {
    final opened = <RouteSettings>[];
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (s) {
        if (s.name == '/') {
          return MaterialPageRoute(
            settings: RouteSettings(name: '/user-profile', arguments: userId),
            builder: (_) => const UserProfileScreen(animateBackground: false),
          );
        }
        opened.add(s);
        return MaterialPageRoute(builder: (_) => Scaffold(body: Text('route ${s.name}')));
      },
    ));
    await tester.pumpAndSettle();
    return opened;
  }

  String textIn(WidgetTester tester, Key key) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(key), matching: find.byType(Text)))
      .map((t) => t.data ?? t.textSpan!.toPlainText())
      .join(' | ');

  testWidgets("on Home's visual system", (tester) async {
    await open(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(find.byType(SliverAppBar), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(find.widgetWithText(ZoneGlowText, 'PROFILE'), findsOneWidget);
  });

  group('only figures the API returns', () {
    testWidgets("the seller's standing, as their listings show it", (tester) async {
      await open(tester);
      expect(textIn(tester, const Key('standing-rating')), contains('8.5/10'));
      expect(textIn(tester, const Key('standing-dcr')), contains('92%'));
      expect(textIn(tester, const Key('standing-response')), contains('25m'));
      expect(textIn(tester, const Key('standing-deal-time')),
          allOf(contains('2.0d'), contains('3 deals')));
      expect(textIn(tester, const Key('fact-deals')), contains('14'));
      expect(textIn(tester, const Key('fact-escrow')), contains('93%'));
      expect(textIn(tester, const Key('fact-disputes')), contains('7%'));
    });

    testWidgets('none of the invented ones', (tester) async {
      // A new seller: no snapshot, no deals, a rating still at its 5.0 start.
      backend(profile: {
        'id': 'seller-1', 'name': 'New Seller', 'account_type': 'buyer_seller',
        'rating': 5.0, 'completed_deals': 0, 'last_seen': '2026-09-30T13:05:00',
        'created_at': '2026-09-01T09:00:00',
      }, summary: {'avg': null, 'count': 0, 'distribution': {}}, reviews: <Object?>[]);
      await open(tester);
      expect(tester.takeException(), isNull);
      // The 5.0 starting rating, doubled, was "10.0/10" for someone nobody rated.
      expect(find.textContaining('10.0/10'), findsNothing);
      for (final gone in ['Reliability', 'Trust Score', 'Response Rate', 'Pending Deals',
                          'TRADER PROFILE RADAR', '85', 'Kenya', 'N/A']) {
        expect(find.textContaining(gone), findsNothing, reason: gone);
      }
      expect(textIn(tester, const Key('standing-rating')), contains('Not rated yet'));
      expect(textIn(tester, const Key('standing-deal-time')), contains('No completed deals'));
      expect(textIn(tester, const Key('fact-escrow')), contains('—'));
      expect(find.byKey(const Key('reviews-empty')), findsOneWidget);
    });

    testWidgets("last seen is the server's reading, not a UTC-shifted guess", (tester) async {
      // last_seen is naive UTC. Read as local time in Kenya it was always at
      // least "3h ago" - the figure reported.
      await open(tester);
      expect(textIn(tester, const Key('profile-presence')), 'Active 12m ago');
      expect(find.textContaining('3h ago'), findsNothing);

      backend(profile: _seller(extra: {'is_online': true, 'last_seen_label': 'Active now'}));
      // A fresh screen, so the profile is fetched again.
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      expect(textIn(tester, const Key('profile-presence')), 'Online now');
    });

    testWidgets('a place only when the user shares one', (tester) async {
      await open(tester);
      expect(find.text('Westlands, Nairobi'), findsOneWidget);
      expect(textIn(tester, const Key('profile-distance')), '~3.4 km away');
    });
  });

  group('your own profile', () {
    testWidgets('opens the dashboard, and has no distance from yourself', (tester) async {
      await signIn('seller-1');
      final opened = await open(tester);
      expect(find.widgetWithText(ZoneGlowText, 'PROFILE'), findsOneWidget);
      expect(find.text('YOUR STANDING, AS BUYERS SEE IT'), findsOneWidget);
      expect(find.byKey(const Key('profile-distance')), findsNothing);
      expect(find.byKey(const Key('write-review')), findsNothing);
      expect(find.byKey(const Key('review-eligibility')), findsNothing);
      // You are not asked whether you can review yourself.
      expect(fakeRequests.where((r) => r.uri.path == '/reviews/my-deals'), isEmpty);

      await tester.tap(find.byKey(const Key('profile-dashboard')));
      await tester.pumpAndSettle();
      expect(opened.map((s) => s.name), ['/seller-dashboard']);
    });
  });

  group('reviews', () {
    testWidgets('load, with who wrote them', (tester) async {
      await open(tester);
      await tester.scrollUntilVisible(find.text('Phone exactly as described.'), 200);
      expect(textIn(tester, const Key('reviews-summary')),
          allOf(contains('4.5'), contains('2 reviews')));
      expect(find.text('Amina W.'), findsOneWidget);
      expect(find.text('Brian O.'), findsOneWidget);
      // The distribution's keys come as strings ("4"), and were read as ints.
      final bars = tester.widgetList<LinearProgressIndicator>(find.descendant(
          of: find.byKey(const Key('reviews-summary')),
          matching: find.byType(LinearProgressIndicator))).map((b) => b.value).toList();
      expect(bars, [0.5, 0.5, 0, 0, 0]);
    });

    testWidgets('someone who never bought from the seller is told why they cannot review',
        (tester) async {
      await open(tester);
      expect(find.byKey(const Key('write-review')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const Key('review-eligibility')), 200);
      expect(textIn(tester, const Key('review-eligibility')),
          'Only buyers who completed a deal with Grace Akinyi can review them.');
      // Asked about this seller's deals only.
      final ask = fakeRequests.singleWhere((r) => r.uri.path == '/reviews/my-deals');
      expect(ask.uri.queryParameters['seller_id'], 'seller-1');
    });

    testWidgets('a buyer who has reviewed every deal is not offered another', (tester) async {
      backend(myDeals: [_deal(reviewed: true)]);
      await open(tester);
      expect(find.byKey(const Key('write-review')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const Key('review-eligibility')), 200);
      expect(textIn(tester, const Key('review-eligibility')),
          "You've reviewed your deals with Grace Akinyi.");
    });

    testWidgets('a buyer with a completed deal goes straight to reviewing it', (tester) async {
      backend(myDeals: [_deal()]);
      final opened = await open(tester);
      expect(find.byKey(const Key('review-eligibility')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const Key('write-review')), 200);
      await tester.tap(find.byKey(const Key('write-review')));
      await tester.pumpAndSettle();
      expect(opened.single.name, '/review');
      expect(opened.single.arguments, {
        'seller_id': 'seller-1', 'seller_name': 'Grace Akinyi',
        'deal_id': 'deal-9', 'listing_name': 'Samsung A54',
      });
    });
  });

  group("the seller's listings", () {
    Map<String, dynamic> listing(String id, String name) => {
          'id': id, 'name': name, 'category': 'Electronics', 'price': 32000,
          'listing_type': 'direct', 'status': 'active', 'seller_id': 'seller-1',
        };

    // It was "Start Negotiation", on whichever listing loaded first.
    testWidgets('one listing: the button opens it', (tester) async {
      backend(listings: [listing('l1', 'Samsung A54')]);
      final opened = await open(tester);
      expect(find.text('Start Negotiation'), findsNothing);
      await tester.tap(find.byKey(const Key('profile-listings-button')));
      await tester.pumpAndSettle();
      expect(opened.single.name, '/product');
      expect((opened.single.arguments as dynamic).id, 'l1');
    });

    testWidgets('several: the button takes the buyer to them', (tester) async {
      backend(listings: [listing('l1', 'Samsung A54'), listing('l2', 'JBL Flip 6')]);
      final opened = await open(tester);
      expect(textIn(tester, const Key('profile-listings-button')), 'See 2 listings');
      await tester.tap(find.byKey(const Key('profile-listings-button')));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(find.text('JBL Flip 6'), findsOneWidget);
    });
  });

  testWidgets("a profile that doesn't exist says so", (tester) async {
    setFakeRoute((uri) => uri.path == '/auth/user/seller-1'
        ? const FakeResponse({'detail': 'User not found'}, statusCode: 404)
        : null);
    await open(tester);
    expect(find.text("This profile isn't available."), findsOneWidget);
    expect(find.text('BROKA user'), findsNothing);
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    backend(myDeals: [_deal()]);

    await open(tester);
    expect(tester.takeException(), isNull);
    // Two days: the dashboard's green band.
    final value = tester.widget<Text>(find.descendant(
        of: find.byKey(const Key('standing-deal-time')), matching: find.byType(Text)).at(1));
    expect((value.textSpan! as TextSpan).children!.first.style!.color, BrokaColors.neonGreen);
    // Scroll through every section so each one is laid out.
    for (var i = 0; i < 8; i++) {
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'after scroll $i');
    }
  });
}
