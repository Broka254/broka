// The review-rating rules that span screens: one conversion from a store's
// 0-10 composite score to stars, no seller rating without reviews, and a
// store page that refreshes both the shop and its reviews after a review.
//
// The bugs these hold shut: a 6.5/10 shop score passed straight to a
// five-star row read as 5/5; a seller with no reviews showed the legacy 5.0
// account default as a perfect average; and Store details kept the counts
// it was opened with after a review was posted.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/account/domain/models/my_account.dart';
import 'package:broka/features/auth/domain/models/user.dart';
import 'package:broka/features/listings/domain/models/listing.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/domain/models/store_reviews.dart';
import 'package:broka/features/stores/presentation/widgets/store_details_view.dart';
import 'package:broka/features/traders/presentation/trader_list_screen.dart';
import 'package:broka/widgets/product_card.dart';
import 'package:broka/widgets/rating_stars.dart';

import 'support/fake_api.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _storeJson({
  double rating = 6.5,
  int reviewCount = 0,
  double? ownerRating = 5.0,
  int ownerReviewCount = 0,
}) => {
      'id': 's1',
      'name': 'Clanix Electronics',
      'slug': 'clanix',
      'url': 'https://broka.co.ke/store/clanix',
      'rating': rating,
      'review_count': reviewCount,
      'is_active': true,
      'listing_count': 1,
      'owner': {
        'name': 'Jane Wanjiru',
        'verified': true,
        'rating': ownerRating,
        'review_count': ownerReviewCount,
        'completed_deals': 0,
      },
    };

/// [reviewsJson] as GET /stores/s1/reviews answers. The viewer's [deals] are
/// what makes the button appear; the second response after a post reports
/// the deal reviewed.
Map<String, dynamic> _reviewsJson({
  double avg = 4.5,
  int count = 1,
  bool alreadyReviewed = false,
}) => {
      'summary': {
        'avg': avg,
        'count': count,
        'distribution': {'5': count, '4': 0, '3': 0, '2': 0, '1': 0},
      },
      'reviews': [
        for (var i = 0; i < count; i++)
          {
            'id': 'r$i',
            'rating': 5,
            'comment': 'Fast and genuine.',
            'created_at': '2026-10-01T09:00:00',
            'reviewer_name': 'Amina W.',
          },
      ],
      'seller_standing': null,
      'viewer': {
        'can_review': !alreadyReviewed,
        'already_reviewed': alreadyReviewed,
        'reviewable_deals': [
          {
            'deal_id': 'd1',
            'seller_id': 'u1',
            'seller_name': 'Jane Wanjiru',
            'listing_name': 'Samsung A15',
            'status': 'released',
            'already_reviewed': alreadyReviewed,
          },
        ],
      },
    };

double _fill(WidgetTester tester, Key key) {
  final align = tester.widget<Align>(
      find.descendant(of: find.byKey(key), matching: find.byType(Align)));
  return align.widthFactor!;
}

/// Pops with `true`, the way ReviewScreen pops after a posted review.
class _WroteReview extends StatefulWidget {
  const _WroteReview();
  @override
  State<_WroteReview> createState() => _WroteReviewState();
}

class _WroteReviewState extends State<_WroteReview> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => Navigator.of(context).pop(true));
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('review form'));
}

// Store details is a tall column: on the page itself it rides a ListView.
Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('the one star conversion', () {
    test('6.5 out of 10 is 3.25 out of 5, never five stars', () {
      expect(starsFromStoreScore(6.5), 3.25);
      expect(starsFromStoreScore(7.2), closeTo(3.6, 1e-9));
      expect(starsFromStoreScore(10), 5);
      expect(starsFromStoreScore(0), 0);
      // A bad payload cannot draw more than five stars or fewer than none.
      expect(starsFromStoreScore(42), 5);
      expect(starsFromStoreScore(-1), 0);
      expect(starsFromStoreScore(double.nan), 0);
    });

    testWidgets('a fractional average fills the fraction of a star', (tester) async {
      await tester.pumpWidget(_host(const RatingStars(
        key: Key('stars'),
        value: 3.25,
        semanticLabel: '3.25 out of 5 stars',
      )));
      expect(_fill(tester, const Key('stars')), closeTo(0.65, 1e-9));
      // Flutter's Icon wraps each star in its own (label-less) Semantics, so
      // the row's labelled node is the one with a label - ours.
      final semantics = tester.widget<Semantics>(find.descendant(
        of: find.byKey(const Key('stars')),
        matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label != null),
      ));
      expect(semantics.properties.label, '3.25 out of 5 stars');
    });
  });

  group('Store details', () {
    testWidgets('keeps the 0-10 shop score apart from the 1-5 buyer reviews',
        (tester) async {
      await tester.pumpWidget(_host(StoreDetailsView(
        store: Store.fromJson(_storeJson(rating: 6.5, reviewCount: 0)),
        reviews: StoreReviews.fromJson(_reviewsJson(avg: 4.5, count: 2)),
      )));

      // The shop score is labelled and drawn on its own scale.
      final score = find.byKey(const Key('store-rating'));
      expect(find.descendant(of: score, matching: find.text('6.5')), findsOneWidget);
      expect(find.descendant(of: score, matching: find.text('out of 10')), findsOneWidget);
      expect(_fill(tester, const Key('store-score-stars')), closeTo(0.65, 1e-9));

      // The shop card's count comes from the reviews response, which is
      // authoritative - the store payload disagrees here (0), and the old
      // card printed "No reviews yet" beside two listed reviews.
      final shop = find.byKey(const Key('store-rating'));
      expect(find.descendant(of: shop, matching: find.text('2 reviews')), findsOneWidget);
      expect(find.descendant(of: shop, matching: find.text('No reviews yet')), findsNothing);

      // The buyer reviews are a different figure with a different scale.
      final reviews = find.byKey(const Key('store-reviews-summary'));
      expect(find.descendant(of: reviews, matching: find.text('4.5')), findsOneWidget);
      expect(find.descendant(of: reviews, matching: find.text('/ 5')), findsOneWidget);
      expect(find.descendant(of: reviews, matching: find.text('2 reviews')), findsOneWidget);
      expect(_fill(tester, const Key('store-reviews-stars')), closeTo(0.9, 1e-9));
      // Nothing calls the shop score a five-star rating.
      expect(find.text('6.5/5'), findsNothing);
      expect(find.textContaining('6.5 out of 5'), findsNothing);

      // The owner has deals but no reviews: no average is invented for them.
      final owner = find.byKey(const Key('owner-rating'));
      expect(find.descendant(of: owner, matching: find.text('New')), findsOneWidget);
      expect(find.descendant(of: owner, matching: find.text('No reviews yet')), findsOneWidget);
      expect(find.text('5.0/5'), findsNothing);
    });

    testWidgets('after a review, both the shop and its reviews refresh once',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);

      var storeCalls = 0;
      var reviewCalls = 0;
      final client = ApiClient(client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/stores/s1') {
          storeCalls++;
          return _json(_storeJson(rating: 6.8, reviewCount: 2));
        }
        if (path == '/stores/s1/reviews') {
          reviewCalls++;
          return _json(reviewCalls == 1
              ? _reviewsJson()
              : _reviewsJson(avg: 4.8, count: 2, alreadyReviewed: true));
        }
        return _json({'detail': 'no route'}, 404);
      }));

      await tester.pumpWidget(MaterialApp(
        home: StoreDetailsScreen(
          store: Store.fromJson(_storeJson(rating: 6.5, reviewCount: 1)),
          repository: StoresRepository(client: client),
          animateBackground: false,
        ),
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => const _WroteReview()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('1 review'), findsWidgets);
      expect(find.byKey(const Key('store-rate')), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-rate')));
      await tester.pumpAndSettle();


      // The new review moved the shop's score and both counts, in place.
      expect(storeCalls, 1);
      expect(reviewCalls, 2);
      expect(find.text('6.8'), findsOneWidget);
      expect(_fill(tester, const Key('store-score-stars')), closeTo(0.68, 1e-9));
      expect(find.text('2 reviews'), findsWidgets);
      expect(find.text('4.8'), findsOneWidget);
      // The same deal cannot be reviewed twice, and the screen says so.
      expect(find.byKey(const Key('store-rate')), findsNothing);
      expect(find.byKey(const Key('store-reviews-already-reviewed')), findsOneWidget);
    });

    testWidgets('a failed store refresh after posting is visible and retryable',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);

      var reviewCalls = 0;
      var storeFails = true;
      final client = ApiClient(client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/stores/s1') {
          return storeFails
              ? _json({'detail': 'temporarily unavailable'}, 503)
              : _json(_storeJson(rating: 6.9, reviewCount: 2));
        }
        if (path == '/stores/s1/reviews') {
          reviewCalls++;
          return _json(reviewCalls == 1
              ? _reviewsJson()
              : _reviewsJson(avg: 4.8, count: 2, alreadyReviewed: true));
        }
        return _json({'detail': 'no route'}, 404);
      }));

      await tester.pumpWidget(MaterialApp(
        home: StoreDetailsScreen(
          store: Store.fromJson(_storeJson(rating: 6.5, reviewCount: 1)),
          repository: StoresRepository(client: client),
          animateBackground: false,
        ),
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => const _WroteReview()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('store-rate')));
      await tester.pumpAndSettle();

      // The reviews did refresh, but the composite score did not. The buyer
      // is told which part is stale instead of being shown an unexplained
      // mix of old and new figures.
      expect(find.byKey(const Key('store-reviews-refresh-error')), findsOneWidget);
      expect(find.textContaining('store score could not be refreshed'), findsOneWidget);
      expect(find.text('2 reviews'), findsWidgets);

      storeFails = false;
      await tester.ensureVisible(
          find.byKey(const Key('store-reviews-refresh-retry')));
      await tester.tap(find.byKey(const Key('store-reviews-refresh-retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('store-reviews-refresh-error')), findsNothing);
      expect(find.text('6.9'), findsOneWidget);
    });

    testWidgets('a failed reviews refresh after posting hides the stale rate button',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);

      var reviewCalls = 0;
      final client = ApiClient(client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/stores/s1') {
          return _json(_storeJson(rating: 6.9, reviewCount: 2));
        }
        if (path == '/stores/s1/reviews') {
          reviewCalls++;
          return reviewCalls == 1
              ? _json(_reviewsJson())
              : _json({'detail': 'temporarily unavailable'}, 503);
        }
        return _json({'detail': 'no route'}, 404);
      }));

      await tester.pumpWidget(MaterialApp(
        home: StoreDetailsScreen(
          store: Store.fromJson(_storeJson(rating: 6.5, reviewCount: 1)),
          repository: StoresRepository(client: client),
          animateBackground: false,
        ),
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => const _WroteReview()),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('store-rate')), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-rate')));
      await tester.pumpAndSettle();

      // The review was posted, but the eligibility payload is still the one
      // from before it. Offering Rate again would invite a duplicate that the
      // backend can only refuse.
      expect(find.byKey(const Key('store-reviews-refresh-error')), findsOneWidget);
      expect(find.textContaining('latest reviews could not be loaded'), findsOneWidget);
      expect(find.byKey(const Key('store-rate')), findsNothing);
    });
  });

  group('a seller rating needs reviews', () {
    testWidgets('a listing never shows the legacy 5.0 without a review', (tester) async {
      final listing = BrokaListing.fromJson({
        ...fakeListingJson(1),
        'seller_rating': 5.0,
        'seller_review_count': 0,
      });
      await tester.pumpWidget(_host(SizedBox(
        width: 180,
        height: 320,
        child: ProductCard(item: listing),
      )));
      expect(find.text('5.0 (0)'), findsNothing);
      expect(find.text('5.0'), findsNothing);
    });

    testWidgets('with reviews, the card carries the /10 score and its count',
        (tester) async {
      final listing = BrokaListing.fromJson({
        ...fakeListingJson(1),
        'seller_rating': 4.8,
        'seller_review_count': 3,
        // What listings/service.py sends beside the raw 1-5 average: the
        // composite in which reviews are one term.
        'seller_overall_rating': 6.9,
      });
      await tester.pumpWidget(_host(SizedBox(
        width: 180,
        height: 320,
        child: ProductCard(item: listing),
      )));
      expect(find.text('6.9/10 (3)'), findsOneWidget);
      // The raw review average stays available as `seller_rating` but is
      // never the headline, and never printed as a five-star score.
      expect(find.text('4.8 (3)'), findsNothing);
    });

    test('the account figures use reviews, not deals', () {
      const noReviews = MyAccount(id: 'u1', name: 'Jane', rating: 5,
          reviewCount: 0, completedDeals: 20);
      expect(noReviews.ratingLabel, 'New');
      const reviewed = MyAccount(id: 'u1', name: 'Jane', rating: 4.6,
          reviewCount: 4, completedDeals: 20);
      expect(reviewed.ratingLabel, '4.6');
    });

    test('the auth DTO cannot turn a missing review into 5.0', () {
      final unreviewed = BrokaUser.fromJson({
        'id': 'u1', 'name': 'Jane', 'email': 'jane@example.com',
        'rating': null, 'review_count': 0,
      });
      expect(unreviewed.rating, isNull);
      expect(unreviewed.reviewCount, 0);
    });
  });

  group('trader cards', () {
    testWidgets('say "No reviews yet" rather than the 5.0 default',
        (tester) async {
      installFakeApi();
      setFakeRoute((uri) {
        if (uri.path.startsWith('/traders')) {
          return [
            {...fakeTraderJson(0), 'rating': null, 'review_count': 0},
            {...fakeTraderJson(1), 'rating': 4.5, 'review_count': 6},
          ];
        }
        return null;
      });
      addTearDown(() => setFakeRoute(null));

      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: TraderListScreen(embedded: true))));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }

      expect(find.text('No reviews yet'), findsOneWidget);
      expect(find.text('4.5 (6)'), findsOneWidget);
      expect(find.text('5.0'), findsNothing);
    });
  });
}
