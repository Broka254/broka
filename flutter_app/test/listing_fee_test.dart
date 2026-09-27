// The listing fee in the app (PRICING.md): the quote as the server sends it,
// the Listing fee screen, and Go live handing an unpaid listing to it.
//
// What must hold:
//   * the seller sees the list price crossed out, their price and why, and
//     the recommended months already chosen;
//   * Pay asks the server for exactly the months and extras chosen, under
//     one key per attempt, and waits for M-Pesa rather than assuming;
//   * a failed prompt says so and lets the seller try again;
//   * featured placement is offered only when the server offers it;
//   * a listing Go live creates unpaid goes straight to the fee screen, and
//     only a paid one gets the celebration.
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/listing_fee/data/listing_fee_repository.dart';
import 'package:broka/features/listing_fee/domain/listing_fee.dart';
import 'package:broka/features/listing_fee/presentation/listing_fee_screen.dart';
import 'package:broka/screens/sell_zeno_alert_screen.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/services/listing_publisher.dart';
import 'package:broka/services/photo_upload_tracker.dart';
import 'package:broka/services/sell_wizard_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// GET /pricing/listing-fee/listings/{id}/quote, as the backend builds it.
Map<String, dynamic> _quote({
  bool featured = true,
  String strength = 'strong',
  int recommended = 5,
  int completed = 0,
  double ownShare = 0,
  int launch = 0,
  int monthsAvailable = 6,
  bool feesEnabled = true,
}) {
  const totals = [1210, 2150, 3010, 3830, 4600, 5350];
  return {
    'category': 'Land',
    'unit_price': 1500000,
    'quantity': 1,
    'currency': 'KES',
    'list_price': 1230,
    'category_max_fee': 1500,
    'monthly_fee': 1210,
    'discount_percent': 2,
    'discounts': {'record_percent': 2, 'launch_percent': launch},
    'risk': {
      'coefficient': 0.982, 'completion_rate': completed > 0 ? 0.9 : 0.35,
      'category_completion_rate': 0.35, 'own_record_share': ownShare,
      'completed_deals': completed, 'leaked_deals': 0,
    },
    'cost_to_serve': 9.5,
    'options': [
      for (var m = 1; m <= monthsAvailable; m++)
        {
          'months': m, 'total': totals[m - 1], 'per_month': totals[m - 1] / m,
          'saving_percent': m == 1 ? 0 : (100 * (1 - totals[m - 1] / (1210 * m))).round(),
          'recommended': m == recommended,
        },
    ],
    'recommendation': {'months': recommended, 'expected_days_to_sell': 120, 'strength': strength},
    'featured': featured
        ? {'available': true, 'reason': null, 'plans': [
            {'id': 'week', 'label': '1 Week Boost', 'days': 7, 'price': 99},
            {'id': 'month', 'label': '4 Week Boost', 'days': 28, 'price': 350},
          ]}
        : {'available': false, 'reason': 'Featured placement is for occasional sellers.', 'plans': []},
    'fees_enabled': feesEnabled,
    'months_available': monthsAvailable,
    'listing_id': 'l1',
    'listing_fee': {'status': 'unpaid', 'live': false, 'paid_until': '2026-09-27T10:00:00', 'needs_payment': true},
  };
}

/// A backend for the fee endpoints: records what was paid for, and answers
/// the status poll with [statuses] in turn.
class _FeeBackend {
  _FeeBackend({Map<String, dynamic>? quote, List<String>? statuses})
      : quote = quote ?? _quote(),
        statuses = statuses ?? ['pending', 'success'];

  final Map<String, dynamic> quote;
  final List<String> statuses;
  final pays = <Map<String, dynamic>>[];
  final keys = <String?>[];
  var polls = 0;

  ListingFeeRepository get repository => ListingFeeRepository(client: ApiClient(client: MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/quote')) return _json(quote);
        if (path == '/pricing/listing-fee/pay') {
          pays.add(jsonDecode(req.body) as Map<String, dynamic>);
          keys.add(req.headers['X-Idempotency-Key']);
          return _json({'payment_id': 'p1', 'status': 'pending', 'amount': 3109, 'months': 3});
        }
        if (path.startsWith('/pricing/listing-fee/payments/')) {
          final status = statuses[polls < statuses.length ? polls : statuses.length - 1];
          polls++;
          return _json({
            'payment_id': 'p1', 'status': status, 'amount': 3109, 'months': 3,
            'failure_reason': status == 'failed' ? 'Request cancelled by user' : null,
            'paid_until': status == 'success' ? '2026-12-26T10:00:00' : null,
            'listing_fee': {'status': status == 'success' ? 'live' : 'unpaid',
              'live': status == 'success', 'paid_until': null, 'needs_payment': status != 'success'},
          });
        }
        return _json({'detail': 'Not found'}, 404);
      })));
}

Future<void> _open(WidgetTester tester, Widget screen, {Map<String, WidgetBuilder>? routes}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    routes: routes ?? const {},
    home: screen,
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

const _poll = Duration(milliseconds: 100);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('The quote', () {
    test('reads what the server sends', () {
      final q = ListingFeeQuote.fromJson(_quote());
      expect(q.listPrice, 1230);
      expect(q.monthlyFee, 1210);
      expect(q.options.map((o) => o.months), [1, 2, 3, 4, 5, 6]);
      expect(q.defaultMonths, 5, reason: 'the recommended months are chosen to start with');
      expect(q.featuredPlans.map((p) => p.price), [99, 350]);
      expect(q.state?.unpaid, isTrue);
    });

    test('starts on the longest months left when the recommendation no longer fits', () {
      final q = ListingFeeQuote.fromJson(_quote(recommended: 5, monthsAvailable: 2));
      expect(q.defaultMonths, 2);
    });

    test('a new seller is told they start at their category, a proven one about their record', () {
      final fresh = feeReasons(ListingFeeQuote.fromJson(_quote()));
      expect(fresh.first, contains('New sellers start at the Land average: 35%'));
      final proven = feeReasons(ListingFeeQuote.fromJson(_quote(completed: 40, ownShare: 0.8)));
      expect(proven.first, startsWith('90% of your deals complete through BROKA'));
    });

    test('the launch offer is named only while there is one', () {
      expect(feeReasons(ListingFeeQuote.fromJson(_quote())).join(), isNot(contains('Launch offer')));
      expect(feeReasons(ListingFeeQuote.fromJson(_quote(launch: 30))).join(), contains('Launch offer: 30%'));
    });

    test('recommends months for land, says nothing when a month will do', () {
      final land = recommendationText(ListingFeeQuote.fromJson(_quote()));
      expect(land, contains('about 4 months'));
      expect(land, contains('5 months keeps you in front of buyers'));
      expect(recommendationText(ListingFeeQuote.fromJson(_quote(strength: 'none', recommended: 1))), isNull);
    });
  });

  group('Paying', () {
    test('sends the choice and one key per attempt', () async {
      final backend = _FeeBackend();
      final r = await backend.repository.pay(
          listingId: 'l1', months: 3, phone: '0712345678', featuredPlan: 'week', idempotencyKey: 'k1');
      expect(r.isSuccess, isTrue);
      expect(backend.pays.single, {
        'listing_id': 'l1', 'months': 3, 'phone_number': '0712345678', 'featured_plan': 'week'});
      expect(backend.keys.single, 'k1');
      expect(ListingFeeRepository.newAttemptKey(), isNot(ListingFeeRepository.newAttemptKey()));
    });

    testWidgets('shows the list price crossed out, the price, and the recommended months chosen', (tester) async {
      final backend = _FeeBackend();
      await _open(tester, ListingFeeScreen(
          listingId: 'l1', listingName: 'Plot in Kitengela', repository: backend.repository));
      expect(find.byKey(const Key('fee-list-price')), findsOneWidget);
      expect(find.text('KES 1,230'), findsOneWidget);
      expect(find.byKey(const Key('fee-discount')), findsOneWidget);
      expect(find.byKey(const Key('fee-recommendation')), findsOneWidget);
      final chosen = tester.widget<Semantics>(find.descendant(
          of: find.byKey(const Key('fee-months-5')), matching: find.byType(Semantics)).first);
      expect(chosen.properties.selected, isTrue);
      expect(find.text('Pay KES 4,600 with M-Pesa'), findsOneWidget);
    });

    testWidgets('pays for the months and extras chosen, then waits for M-Pesa', (tester) async {
      final backend = _FeeBackend();
      await _open(tester, ListingFeeScreen(
          listingId: 'l1', listingName: 'Plot in Kitengela', repository: backend.repository,
          pollEvery: _poll));
      await _tap(tester, find.byKey(const Key('fee-months-3')));
      await _tap(tester, find.byKey(const Key('fee-featured-week')));
      expect(find.text('Pay KES 3,109 with M-Pesa'), findsOneWidget, reason: '3,010 + 99');
      await tester.enterText(find.byKey(const Key('fee-phone')), '0712 345 678');
      await _tap(tester, find.byKey(const Key('fee-pay')));
      await tester.pump();
      expect(find.byKey(const Key('fee-waiting')), findsOneWidget);
      expect(backend.pays.single['months'], 3);
      expect(backend.pays.single['featured_plan'], 'week');

      await tester.pump(_poll); // pending
      expect(find.byKey(const Key('fee-waiting')), findsOneWidget);
      await tester.pump(_poll); // success
      await tester.pump();
      expect(find.byKey(const Key('fee-paid')), findsOneWidget);
      expect(find.textContaining('is live until 26 Dec 2026'), findsOneWidget);
    });

    testWidgets('a cancelled prompt says so and the seller can try again', (tester) async {
      final backend = _FeeBackend(statuses: ['failed']);
      await _open(tester, ListingFeeScreen(
          listingId: 'l1', listingName: 'Plot', repository: backend.repository, pollEvery: _poll));
      await tester.enterText(find.byKey(const Key('fee-phone')), '0712345678');
      await _tap(tester, find.byKey(const Key('fee-pay')));
      await tester.pump();
      await tester.pump(_poll);
      await tester.pump();
      expect(find.byKey(const Key('fee-error')), findsOneWidget);
      expect(find.textContaining("didn't complete the payment"), findsOneWidget);
      expect(find.byKey(const Key('fee-pay')), findsOneWidget);
    });

    testWidgets('no featured placement unless the server offers it', (tester) async {
      final backend = _FeeBackend(quote: _quote(featured: false));
      await _open(tester, ListingFeeScreen(listingId: 'l1', listingName: 'Plot', repository: backend.repository));
      expect(find.byKey(const Key('fee-featured-week')), findsNothing);
      expect(find.text('Feature it at the top of Home?'), findsNothing);
    });

    testWidgets('a number too short to be one is caught before any prompt', (tester) async {
      final backend = _FeeBackend();
      await _open(tester, ListingFeeScreen(listingId: 'l1', listingName: 'Plot', repository: backend.repository));
      await tester.enterText(find.byKey(const Key('fee-phone')), '0712');
      await _tap(tester, find.byKey(const Key('fee-pay')));
      expect(find.byKey(const Key('fee-error')), findsOneWidget);
      expect(backend.pays, isEmpty);
    });

    testWidgets('paid six months ahead: nothing more to buy', (tester) async {
      final backend = _FeeBackend(quote: _quote(monthsAvailable: 0));
      await _open(tester, ListingFeeScreen(listingId: 'l1', listingName: 'Plot', repository: backend.repository));
      expect(find.text('Paid 6 months ahead'), findsOneWidget);
      expect(find.byKey(const Key('fee-pay')), findsNothing);
    });
  });

  group('Go live', () {
    SellWizardData draft() {
      final data = SellWizardData(photoUploads: PhotoUploadTracker(service: _FakeUploader()))
        ..name = 'Plot in Kitengela'
        ..category = 'Land'
        ..categoryId = 'land'
        ..subcategoryId = 'plots'
        ..description = 'Quarter acre, ready title, 2 km from the tarmac.'
        ..price = '1500000'
        ..priceNegotiable = true
        ..quantity = '1'
        ..deliveryAvailable = false
        ..county = 'Kajiado'
        ..subcounty = 'Kitengela'
        ..smsAlerts = false;
      data.attributes['land_size'] = '0.25';
      data.attributes['land_size_unit'] = 'acres';
      data.verifiedPhotos.add(File('/photos/plot.jpg'));
      data.photoUploads.restore({'/photos/plot.jpg': 'photo-1'});
      return data;
    }

    ListingPublisher publisherReturning(Map<String, dynamic> listing) => ListingPublisher(
        client: ApiClient(client: MockClient((req) async => _json(listing, 201))),
        uploader: _FakeUploader());

    testWidgets('an unpaid listing goes to the fee screen, and is celebrated once paid', (tester) async {
      final backend = _FeeBackend();
      await _open(tester, SellZenoAlertScreen(
        data: draft(),
        question: 'Shall I text you?',
        publisher: publisherReturning({
          'id': 'l1', 'name': 'Plot in Kitengela',
          'listing_fee': {'status': 'unpaid', 'live': false, 'paid_until': '2026-09-27T10:00:00',
            'needs_payment': true},
        }),
        feeRepository: backend.repository,
      ));
      expect(find.byKey(const Key('sell-fee-teaser')), findsOneWidget,
          reason: 'the price is said before Go live, not sprung after');
      await _tap(tester, find.byKey(const Key('sell-go-live')));
      await tester.pumpAndSettle();
      expect(find.byType(ListingFeeScreen), findsOneWidget);
      expect(find.text('Your listing is live!'), findsNothing);

      // Leaving without paying: saved, and the button now pays.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sell-saved-unpaid')), findsOneWidget);
      expect(find.text('PAY TO GO LIVE'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('sell-go-live')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('fee-phone')), '0712345678');
      await _tap(tester, find.byKey(const Key('fee-pay')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      await tester.pumpAndSettle();
      expect(find.byType(ListingFeeScreen), findsNothing);
      expect(find.text('Your listing is live!'), findsOneWidget);
    });

    testWidgets('with fees off, nothing about fees and straight to live', (tester) async {
      final backend = _FeeBackend(quote: _quote(feesEnabled: false));
      await _open(tester, SellZenoAlertScreen(
        data: draft(),
        question: 'Shall I text you?',
        publisher: publisherReturning({
          'id': 'l1', 'name': 'Plot in Kitengela',
          'listing_fee': {'status': 'free', 'live': true, 'paid_until': null, 'needs_payment': false},
        }),
        feeRepository: backend.repository,
      ));
      expect(find.byKey(const Key('sell-fee-teaser')), findsNothing);
      await _tap(tester, find.byKey(const Key('sell-go-live')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Your listing is live!'), findsOneWidget);
      expect(find.byType(ListingFeeScreen), findsNothing);
      await tester.pumpAndSettle();
    });
  });
}

class _FakeUploader extends ImageUploadService {
  @override
  Future<UploadedImage> uploadFile(File file,
          {required String purpose, void Function(double fraction)? onProgress}) async =>
      const UploadedImage(id: 'photo-1', thumb: '/t', medium: '/m', large: '/l');
}
