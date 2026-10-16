// Store billing in the app (PRICING.md §5; backend stores/billing.py): the
// plan a store's own stock prices at, paying it through the shared checkout,
// the plan card on My Store, the store directory's category cards and its
// BROKA-mark fallback, and where a fresh store goes after "Open my store"
// while billing is on.
//
// What must hold:
//   * the app shows no billing surface at all while the payload carries no
//     `billing` - the feature's switch is the server's;
//   * every amount on the screen is the server's quote, and the plan's size
//     follows the store's live listings, never a number the owner picks;
//   * the opening fee is waived from six months (the quote says so) and the
//     checkout charges exactly what was on screen;
//   * an unpaid store is hidden from buyers - both cards say so - and paying
//     pops back with `true` so the caller can celebrate or refresh;
//   * a store with no picture shows BROKA's mark, not its category emoji;
//   * a freshly launched store with billing unpaid opens the plan first,
//     and leaving it lands on My Store, never the celebration screen.
import 'dart:async';
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/categories/domain/category_visual.dart';
import 'package:broka/features/listings/data/repositories/listings_repository.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/domain/models/store_billing.dart';
import 'package:broka/features/stores/presentation/my_store_screen.dart';
import 'package:broka/features/stores/presentation/setup/store_setup_controller.dart';
import 'package:broka/features/stores/presentation/setup/store_setup_screen.dart';
import 'package:broka/features/stores/presentation/store_category_screen.dart';
import 'package:broka/features/stores/presentation/store_billing_screen.dart';
import 'package:broka/features/stores/presentation/store_launched_screen.dart';
import 'package:broka/features/stores/presentation/store_list_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/sell_photo_store.dart';
import 'package:broka/widgets/broka_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

// ── The server's shapes (stores/billing.py, pricing/plans.py) ───────────────

/// The goods card: 599 a month for 30 listings, 16 a listing to 100.
Map<String, dynamic> _rateCard() => {
      'id': 'goods',
      'name': 'Goods store',
      'included_listings': 30,
      'base_price': 599,
      'per_listing_bands': [
        {'up_to': 100, 'price': 16},
        {'up_to': 250, 'price': 14},
        {'up_to': 1000, 'price': 12},
      ],
      'min_listings': 1,
      'max_listings': 1000,
      'categories': ['Electronics'],
    };

/// period_prices() totals for 599, as plans.py rounds them.
const _totals = {1: 599, 3: 1649, 6: 3049, 12: 5749};

int _amount(int months, {bool setupPaid = false}) =>
    _totals[months]! + (setupPaid || months >= 6 ? 0 : 299);

List<Map<String, dynamic>> _periods({bool setupPaid = false}) => [
      for (final e in _totals.entries)
        {
          'months': e.key,
          'total': e.value,
          'per_month': e.value / e.key,
          'saving_percent': (100 * (1 - e.value / (_totals[1]! * e.key))).round(),
          'setup_fee': setupPaid || e.key >= 6 ? 0 : 299,
          'amount': _amount(e.key, setupPaid: setupPaid),
        },
    ];

Map<String, dynamic> _plan() => {
      'id': 'goods-30',
      'name': 'Goods store, 30 listings',
      'monthly_price': 599,
      'listings': 30,
      'periods': _periods(),
    };

Map<String, dynamic> _quote({int? listings, Map<String, dynamic>? current}) => {
      'rate_card': _rateCard(),
      'setup_fee': 299,
      'setup_fee_waived_from_months': 6,
      'min_listings': 1,
      'live_listings': 2,
      'current': current ?? _billingUnpaid(),
      'months_options': [1, 3, 6, 12],
      if (listings != null) 'plan': _plan(),
    };

Map<String, dynamic> _billingUnpaid() => {
      'active': false, 'plan_id': null, 'listings': null, 'monthly_price': null,
      'paid_until': null, 'setup_fee_paid': false,
    };

Map<String, dynamic> _billingActive() => {
      'active': true, 'plan_id': 'goods-30', 'listings': 30, 'monthly_price': 599,
      // Naive UTC, as the backend sends it.
      'paid_until': '2026-12-16T10:00:00', 'setup_fee_paid': true,
    };

Map<String, dynamic> _storeJson({Map<String, dynamic>? billing}) => {
      'id': 's1',
      'name': 'Clanix Electronics',
      'slug': 'clanix',
      'url': 'https://broka.co.ke/store/clanix',
      'category': 'Electronics',
      'description': 'Phones',
      'county': 'Nairobi',
      'subcounty': 'Starehe',
      'location_description': 'Moi Avenue',
      'business_email': null,
      'business_email_verified': false,
      'logo': null,
      'cover': null,
      'photo_images': [],
      'logo_url': null,
      'photos': [],
      'owner': {'verified': true, 'rating': 4.8, 'completed_deals': 12,
          'member_since': '2025-01-10T00:00:00'},
      'is_active': true,
      'listing_count': 3,
      if (billing != null) 'billing': billing,
    };

Map<String, dynamic> _owner() => {
      'id': 'u1', 'name': 'Jane Wanjiru', 'account_type': 'buyer_seller',
      'seller_tier': 'long_term', 'business_name': 'Clanix Electronics',
      'business_category': 'Phones & Accessories',
      'business_location': 'Moi Avenue, Nairobi',
      'business_description': 'Phones and accessories, genuine only.',
      'email': null, 'email_verified': false,
    };

Map<String, dynamic> _stats() => {
      'days': 7,
      'visits': {
        'total': 9,
        'by_day': [
          for (var i = 0; i < 7; i++)
            {'date': '2026-09-1$i', 'count': 0},
        ],
        'by_source': <String, int>{},
        'by_surface': {'app': 0, 'web': 0},
      },
      'shares': {'total': 0, 'by_channel': <String, int>{}},
    };

/// A backend behind an injected ApiClient, routing on "METHOD /path".
class _Backend {
  _Backend(this.routes);
  final Map<String, FutureOr<http.Response> Function(http.Request)> routes;
  final List<http.Request> requests = [];

  late final client = ApiClient(client: MockClient((req) async {
    requests.add(req);
    final handler = routes['${req.method} ${req.url.path}'];
    if (handler == null) return _json({'detail': 'no route ${req.method} ${req.url.path}'}, 404);
    return handler(req);
  }));

  late final repo = StoresRepository(client: client);

  Iterable<Map<String, dynamic>> bodiesFor(String method, String path) => requests
      .where((r) => r.method == method && r.url.path == path)
      .map((r) => jsonDecode(r.body) as Map<String, dynamic>);
}

/// The billing endpoints, with the payment recorded and the status poll
/// answered from [statuses] in turn.
class _BillingBackend extends _Backend {
  _BillingBackend({List<String>? statuses})
      : statuses = statuses ?? ['pending', 'success'],
        super({});

  final List<String> statuses;
  final listingsAsked = <int?>[];
  final pays = <Map<String, dynamic>>[];
  final keys = <String?>[];
  var polls = 0;
  bool failQuote = false;

  void wire() {
    routes.addAll({
      'GET /stores/s1/billing': (r) {
        if (failQuote) return _json({'detail': 'Server busy'}, 503);
        final raw = r.url.queryParameters['listings'];
        listingsAsked.add(raw == null ? null : int.parse(raw));
        return _json(_quote(listings: raw == null ? null : int.parse(raw)));
      },
      'POST /stores/s1/billing/pay': (r) {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        pays.add(body);
        keys.add(r.headers['X-Idempotency-Key']);
        final months = body['months'] as int;
        return _json({
          'payment_id': 'bp1', 'status': 'pending', 'plan_id': 'goods-30',
          'listings': 30, 'months': months, 'amount': _amount(months),
          'setup_fee': months >= 6 ? 0 : 299,
          'message': 'Check your phone and enter your M-Pesa PIN.',
        });
      },
      'GET /stores/s1/billing/payments/bp1': (r) {
        final status = statuses[polls < statuses.length ? polls : statuses.length - 1];
        polls++;
        return _json({
          'payment_id': 'bp1', 'status': status, 'plan_id': 'goods-30', 'listings': 30,
          'months': 1, 'amount': 898,
          'failure_reason': status == 'failed' ? 'Request cancelled by user' : null,
          'paid_until': status == 'success' ? '2026-12-16T10:00:00' : null,
        });
      },
    });
  }
}

const _poll = Duration(milliseconds: 100);

/// Peeking at the store directory and the launch screen: their
/// ConstellationBackground never stops scheduling frames, so pumpAndSettle
/// would only ever time out (discovery_destinations_test.dart's _settle).
Future<void> _pumpFrames(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

/// Opens the billing screen through a navigator, so the test can see what it
/// pops when it is done.
Future<ValueNotifier<bool?>> _openBilling(WidgetTester tester, _BillingBackend backend) async {
  final popped = ValueNotifier<bool?>(null);
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              popped.value = await Navigator.of(context).push<bool>(MaterialPageRoute(
                builder: (_) => StoreBillingScreen(
                  storeId: 's1', storeName: 'Clanix Electronics',
                  repository: backend.repo, pollEvery: _poll,
                  giveUpAfter: const Duration(seconds: 3),
                ),
              ));
            },
            child: const Text('open billing'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open billing'));
  await tester.pumpAndSettle();
  return popped;
}

/// Continue -> pick M-Pesa -> the M-Pesa screen, with [phone] typed in.
Future<void> _toMpesa(WidgetTester tester, String phone) async {
  await _tap(tester, find.byKey(const Key('store-billing-continue')));
  await tester.pumpAndSettle();
  await _tap(tester, find.byKey(const Key('method-mpesa')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('mpesa-phone')), phone);
}

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    setFakeRoute(null);
    clearFakeRequests();
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'u1';
    // Launching clears the kept-photos folder; there is no storage plugin in
    // a widget test, so the real one would only stall the launch future
    // (sell_wizard_overhaul_test.dart does the same).
    KeptPhotos.baseDirectory = () async => throw UnsupportedError('no storage in tests');
  });

  group('What the server sends', () {
    test('the store payload carries the plan state - or nothing while billing is off', () {
      expect(Store.fromJson(_storeJson()).billing, isNull);

      final unpaid = Store.fromJson(_storeJson(billing: _billingUnpaid()));
      expect(unpaid.billing!.active, isFalse);
      expect(unpaid.billing!.setupFeePaid, isFalse);
      expect(unpaid.billing!.paidUntil, isNull);

      final active = Store.fromJson(_storeJson(billing: _billingActive()));
      expect(active.billing!.active, isTrue);
      expect(active.billing!.listings, 30);
      expect(active.billing!.paidUntil, DateTime.utc(2026, 12, 16, 10).toLocal());
    });

    test('a quote: the card, the priced size, and the periods with the opening fee', () {
      final q = StoreBillingQuote.fromJson(_quote(listings: 2));
      expect(q.liveListings, 2);
      expect(q.rateCard.name, 'Goods store');
      expect(q.rateCard.includedListings, 30);
      expect(q.rateCard.bandUpTo, 100);
      expect(q.setupFee, 299);
      expect(q.setupFeeWaivedFromMonths, 6);
      expect(q.plan!.listings, 30);
      expect(q.plan!.monthlyPrice, 599);
      expect(q.plan!.period(1)!.amount, 898, reason: '599 + the 299 opening fee');
      expect(q.plan!.period(6)!.amount, 3049, reason: 'six months waives the fee');
      expect(q.plan!.period(6)!.setupFee, 0);
      expect(q.plan!.period(12)!.savingPercent, 20);
    });
  });

  group('StoreBillingScreen', () {
    testWidgets("prices the plan for the store's own stock, opening fee waived from six months",
        (tester) async {
      final backend = _BillingBackend()..wire();
      await _openBilling(tester, backend);

      // The card first, then the size the live count picked: never a number
      // the owner has to know.
      expect(backend.listingsAsked, [null, 2]);
      expect(find.byKey(const Key('store-billing-status')), findsOneWidget);
      expect(find.text('Your store is offline'), findsOneWidget);
      expect(find.textContaining("Buyers can't see Clanix Electronics"), findsOneWidget);
      expect(find.byKey(const Key('store-billing-plan')), findsOneWidget);
      expect(find.text('Goods store · up to 30 listings'), findsOneWidget);
      expect(find.text('KES 599 a month · 2 live now'), findsOneWidget);
      expect(find.textContaining('Plus a one-off KES 299 opening fee'), findsOneWidget);
      // Every period is priced; six and twelve wear the waiver.
      expect(find.text('Opening fee waived'), findsNWidgets(2));
      expect(find.text('Continue to payment · KES 898'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('store-billing-months-6')));
      await tester.pumpAndSettle();
      expect(find.text('Continue to payment · KES 3,049'), findsOneWidget);
      expect(find.text('KES 3,049'), findsOneWidget);
    });

    testWidgets('pays through the shared checkout and pops true once M-Pesa confirms',
        (tester) async {
      final backend = _BillingBackend()..wire();
      final popped = await _openBilling(tester, backend);

      await _toMpesa(tester, '0712 345 678');
      expect(find.text('Pay KES 898'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      await tester.pump();
      expect(find.byKey(const Key('checkout-waiting')), findsOneWidget);

      // The charge is the size and months that were on screen, under one
      // idempotency key per attempt.
      expect(backend.pays.single,
          {'listings': 30, 'months': 1, 'phone_number': '0712 345 678'});
      expect(backend.keys.single, isNotNull);

      await tester.pump(_poll); // pending
      await tester.pump(_poll); // success
      await tester.pump();
      expect(find.byKey(const Key('checkout-paid')), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(popped.value, isTrue, reason: 'the caller has to know to refresh');
      expect(find.byType(StoreBillingScreen), findsNothing);
    });

    testWidgets('a cancelled prompt says so and Pay is there again', (tester) async {
      final backend = _BillingBackend(statuses: ['failed'])..wire();
      await _openBilling(tester, backend);
      await _toMpesa(tester, '0712345678');
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      await tester.pump();
      await tester.pump(_poll);
      await tester.pump();
      expect(find.byKey(const Key('checkout-error')), findsOneWidget);
      expect(find.byKey(const Key('mpesa-pay')), findsOneWidget);
    });

    testWidgets('grace time - live but no plan - says paid up, not for sale', (tester) async {
      final backend = _BillingBackend()..wire();
      backend.routes['GET /stores/s1/billing'] = (_) => _json(_quote(current: {
            'active': true, 'plan_id': null, 'listings': null, 'monthly_price': null,
            'paid_until': null, 'setup_fee_paid': false,
          }));
      final popped = await _openBilling(tester, backend);
      expect(find.text('Your plan is paid up'), findsOneWidget);
      expect(find.byKey(const Key('store-billing-continue')), findsNothing);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(popped.value, isFalse);
    });

    testWidgets('a quote that fails offers a retry that works', (tester) async {
      final backend = _BillingBackend()..wire();
      backend.failQuote = true;
      await _openBilling(tester, backend);
      expect(find.text("Couldn't load your plan"), findsOneWidget);
      expect(find.byKey(const Key('store-billing-continue')), findsNothing);

      backend.failQuote = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('store-billing-continue')), findsOneWidget);
    });
  });

  group('My Store plan card', () {
    Future<_Backend> openMyStore(WidgetTester tester,
        {Map<String, dynamic>? billing,
        Map<String, FutureOr<http.Response> Function(http.Request)> more = const {}}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final backend = _Backend({
        'GET /stores/mine': (_) => _json(_storeJson(billing: billing)),
        'GET /stores/s1/stats': (_) => _json(_stats()),
        'GET /stores/s1/manage/listings': (_) =>
            _json({'items': [], 'counts': {'all': 0, 'live': 0, 'hidden': 0, 'in_deal': 0, 'sold': 0}}),
        ...more,
      });
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: MyStoreScreen(key: UniqueKey(), repository: backend.repo,
              listings: ListingsRepository(client: backend.client),
              animateBackground: false)));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('unpaid: the card and the switch both say buyers cannot see it',
        (tester) async {
      await openMyStore(tester, billing: _billingUnpaid());
      final card = find.byKey(const Key('my-store-plan-card'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Plan unpaid')), findsOneWidget);
      expect(find.descendant(of: card,
          matching: find.text("Buyers can't see your store or its products yet")), findsOneWidget);
      expect(find.byKey(const Key('my-store-plan-action')), findsOneWidget);
      expect(find.text('Pay now'), findsOneWidget);
      // The open/paused card directly under it must not claim buyers can
      // browse: a paid plan is what gets the store seen (billing.py).
      expect(find.text('Hidden from buyers until your plan is paid'), findsOneWidget);
      expect(find.text('Buyers can browse it from your link'), findsNothing);
    });

    testWidgets('paid: says until when, and Manage opens the plan', (tester) async {
      await openMyStore(tester, billing: _billingActive());
      final card = find.byKey(const Key('my-store-plan-card'));
      expect(find.descendant(of: card, matching: find.text('Plan active')), findsOneWidget);
      expect(find.descendant(of: card,
          matching: find.text('Buyers can see your store until 16 Dec')), findsOneWidget);
      expect(find.text('Manage'), findsOneWidget);
      expect(find.text('Buyers can browse it from your link'), findsOneWidget);

      // The card sits at the very top; ensureVisible would tuck it under the
      // pinned bar, so tap where it rests.
      await tester.tap(find.byKey(const Key('my-store-plan-action')));
      await tester.pumpAndSettle();
      expect(find.byType(StoreBillingScreen), findsOneWidget);
    });

    testWidgets('billing off: no card, and the switch is as it always was', (tester) async {
      await openMyStore(tester);
      expect(find.byKey(const Key('my-store-plan-card')), findsNothing);
      expect(find.text('Buyers can browse it from your link'), findsOneWidget);
    });
  });

  group('Store directory', () {
    testWidgets('a category card opens a screen scoped to that category, off the wire',
        (tester) async {
      // Wide enough that the rail's early entries are all on screen.
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: StoreListScreen()));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('store-category-rail')), findsOneWidget);
      expect(find.byKey(const Key('store-category-Electronics')), findsOneWidget);

      clearFakeRequests();
      await tester.tap(find.byKey(const Key('store-category-Electronics')));
      // The category screen's constellation never stops; settle would only
      // ever time out.
      await _pumpFrames(tester, 12);

      expect(find.byType(StoreCategoryScreen), findsOneWidget);
      final asked = fakeRequests.where((r) => r.uri.path == '/stores').last;
      expect(asked.uri.queryParameters['category'], 'Electronics');
    });

    testWidgets("a shop with no picture wears BROKA's mark, not a category emoji",
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: StoreListScreen()));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('store-default-logo')), findsWidgets);
      // The directory rail legitimately wears category emoji now; the card
      // itself must not fall back to one.
      expect(
          find.descendant(
              of: find.byKey(const Key('store-card-store-0')),
              matching: find.text(CategoryVisuals.emojiFor('Electronics'))),
          findsNothing);
    });

    testWidgets("a cover photo and no uploaded logo still wears BROKA's sign",
        (tester) async {
      const cover = '/media/c1/medium.webp';
      setFakeRoute((uri) => uri.path.startsWith('/stores')
          ? [
              {
                ...fakeStoreJson(0),
                'cover': {'id': 'c1', 'thumb': cover, 'medium': cover, 'large': cover},
              },
            ]
          : null);
      await tester.pumpWidget(const MaterialApp(home: StoreListScreen()));
      await _pumpFrames(tester);
      final card = find.byKey(const Key('store-card-store-0'));
      expect(find.descendant(of: card, matching: find.byKey(const Key('store-default-logo'))),
          findsOneWidget);
    });

    testWidgets("an uploaded logo wears the shop's own, not BROKA's", (tester) async {
      const cover = '/media/c1/medium.webp';
      const logo = '/media/l1/thumb.webp';
      setFakeRoute((uri) => uri.path.startsWith('/stores')
          ? [
              {
                ...fakeStoreJson(0),
                'cover': {'id': 'c1', 'thumb': cover, 'medium': cover, 'large': cover},
                'logo': {'id': 'l1', 'thumb': logo, 'medium': logo, 'large': logo},
              },
            ]
          : null);
      await tester.pumpWidget(const MaterialApp(home: StoreListScreen()));
      await _pumpFrames(tester);
      final card = find.byKey(const Key('store-card-store-0'));
      expect(
          find.descendant(
              of: card,
              matching: find.byWidgetPredicate(
                  (w) => w is BrokaImage && w.source == logo)),
          findsOneWidget);
    });
  });

  group('Opening a store', () {
    Future<StoreSetupController> walkToReview(WidgetTester tester, _Backend backend) async {
      final c = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: StoreSetupScreen(controller: c, animateBackground: false),
        onGenerateRoute: (settings) => MaterialPageRoute(
            settings: settings, builder: (_) => Text('route ${settings.name}')),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue')); // name
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue')); // link
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue')); // category
      await tester.pumpAndSettle();
      // The location step needs an area; the signup details don't carry one.
      c.setSubcounty('Starehe');
      await tester.pump();
      await tester.tap(find.text('Continue')); // location
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip for now')); // logo
      await tester.pumpAndSettle();
      // Shop photos are compulsory: the button no longer offers a skip, so
      // stand in an already-uploaded one rather than walking the picker.
      c.photos = [const DraftImage(id: 'p1', url: 'https://broka.co.ke/media/p1.jpg')];
      await tester.pump();
      await tester.tap(find.text('Continue')); // photos
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip')); // email
      await tester.pumpAndSettle();
      expect(find.text('Open my store'), findsOneWidget);
      return c;
    }

    Map<String, FutureOr<http.Response> Function(http.Request)> wizardRoutes(
        Map<String, dynamic> launchedStore) =>
        {
          'GET /auth/me': (_) => _json(_owner()),
          'GET /stores/mine': (_) => _json(null),
          'GET /stores/name-available': (r) => _json({
                'name': r.url.queryParameters['name'],
                'available': true,
                'url': 'https://broka.co.ke/store/${r.url.queryParameters['name']}',
              }),
          'POST /stores': (_) => _json(launchedStore, 201),
          'GET /stores/s1/billing': (r) {
            final raw = r.url.queryParameters['listings'];
            return _json(_quote(listings: raw == null ? null : int.parse(raw)));
          },
        };

    testWidgets('an unpaid new store shows its plan first; leaving lands on My Store',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final backend = _Backend(
          wizardRoutes(_storeJson(billing: _billingUnpaid())));
      final c = await walkToReview(tester, backend);

      // The billing screen the wizard opens is built without a repository,
      // so its quote comes off the global client: fake the wire.
      setFakeRoute((uri) {
        if (uri.path == '/stores/s1/billing') {
          final raw = uri.queryParameters['listings'];
          return _quote(listings: raw == null ? null : int.parse(raw));
        }
        return null;
      });

      await tester.tap(find.text('Open my store'));
      await _pumpFrames(tester, 12);
      expect(find.byType(StoreLaunchedScreen), findsNothing);
      expect(find.byType(StoreBillingScreen), findsOneWidget);
      expect(find.byKey(const Key('store-billing-continue')), findsOneWidget);

      // Backing out is not paying: the store's dashboard is where the plan
      // card keeps saying what is owed.
      Navigator.of(tester.element(find.byType(StoreBillingScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(StoreBillingScreen), findsNothing);
      expect(find.text('route /store-manage'), findsOneWidget);
      c.dispose();
    });

    testWidgets('with billing off, launching is the celebration as before', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final backend = _Backend(wizardRoutes(_storeJson()));
      final c = await walkToReview(tester, backend);

      await tester.tap(find.text('Open my store'));
      // The launch screen's constellation never stops; settle would only
      // ever time out.
      await _pumpFrames(tester, 12);
      expect(find.byType(StoreLaunchedScreen), findsOneWidget);
      expect(find.byType(StoreBillingScreen), findsNothing);
      c.dispose();
    });
  });
}
