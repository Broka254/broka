// The listing fee in the app (PRICING.md): the quote as the server sends it,
// the Listing fee screen, and Go live handing an unpaid listing to it.
//
// What must hold:
//   * the seller sees the list price crossed out, their price and why, and
//     the recommended months already chosen;
//   * paying starts at the payment methods; picking M-Pesa opens a screen
//     with the number to pay from at the top, editable;
//   * Pay asks the server for exactly the months chosen, under
//     one key per attempt, and waits for M-Pesa rather than assuming;
//   * a failed prompt says so and lets the seller try again;
//   * featured placement is never offered: the fee is the only charge;
//   * a listing Go live creates unpaid goes straight to the fee screen, and
//     only a paid one gets the celebration.
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/listing_fee/data/listing_fee_repository.dart';
import 'package:broka/features/listing_fee/domain/listing_fee.dart';
import 'package:broka/features/listing_fee/presentation/awaiting_payment_panel.dart';
import 'package:broka/features/listing_fee/presentation/listing_fee_screen.dart';
import 'package:broka/features/listings/data/repositories/listings_repository.dart';
import 'package:broka/features/payments/domain/checkout.dart';
import 'package:broka/features/payments/presentation/mpesa_checkout_screen.dart';
import 'package:broka/features/payments/presentation/payment_method_screen.dart';
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

/// The quote of the current server: two months a period, 2, 4 or 6 at a
/// time - the KES 1.5M listing of the screenshot that started 2026-11-20.
Map<String, dynamic> _twoMonthQuote({String category = 'Land'}) => {
      ..._quote(recommended: 4),
      'category': category,
      'list_price': 980,
      'monthly_fee': 980,
      'period_fee': 980,
      'period_months': 2,
      'discount_percent': 0,
      'priced_on': 1500000,
      'multi_unit_percent': 0,
      'discounts': {'apply': false, 'record_percent': 0, 'launch_percent': 0},
      'options': [
        {'months': 2, 'total': 980, 'per_month': 490, 'saving_percent': 0, 'recommended': false},
        {'months': 4, 'total': 1740, 'per_month': 435, 'saving_percent': 11, 'recommended': true},
        {'months': 6, 'total': 2440, 'per_month': 406.67, 'saving_percent': 17, 'recommended': false},
      ],
      'recommendation': {'months': 4, 'expected_days_to_sell': 51, 'strength': 'strong'},
    };

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

/// Continue -> pick M-Pesa -> the M-Pesa screen, with [phone] typed in.
Future<void> _toMpesa(WidgetTester tester, String phone) async {
  await _tap(tester, find.byKey(const Key('fee-continue')));
  await tester.pumpAndSettle();
  await _tap(tester, find.byKey(const Key('method-mpesa')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('mpesa-phone')), phone);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('The quote', () {
    test('reads what the server sends', () {
      final q = ListingFeeQuote.fromJson(_quote());
      expect(q.listPrice, 1230);
      expect(q.monthlyFee, 1210);
      expect(q.options.map((o) => o.months), [1, 2, 3, 4, 5, 6]);
      expect(q.defaultMonths, 5, reason: 'the recommended months are chosen to start with');
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

    test('with payments off the price is explained by one unit\'s price, not a record', () {
      final j = _quote()
        ..['priced_on'] = 1500000
        ..['multi_unit_percent'] = 0
        ..['listing_value'] = 1500000
        ..['discounts'] = {'apply': false, 'record_percent': 0, 'launch_percent': 0};
      final lines = feeReasons(ListingFeeQuote.fromJson(j));
      expect(lines.first, 'Priced on the item\'s price: KES 1,500,000.');
      expect(lines.join(), isNot(contains('complete through BROKA')));
      expect(lines.join(), isNot(contains('\u00d7 units')));
    });

    test('several units are priced on one, plus a fifth however many', () {
      // The founder's case: a KES 10,000 phone pays 150, two or ten of them 180.
      final j = _quote()
        ..['unit_price'] = 10000
        ..['quantity'] = 10
        ..['priced_on'] = 10000
        ..['multi_unit_percent'] = 20
        ..['listing_value'] = 100000
        ..['discounts'] = {'apply': false, 'record_percent': 0, 'launch_percent': 0};
      final q = ListingFeeQuote.fromJson(j);
      expect(q.quantity, 10);
      expect(feeReasons(q).first,
          'Priced on one unit: KES 10,000, plus 20% because you\'re listing 10 - '
          'the same however many you list.');
      expect(feeReasons(q).join(), isNot(contains('100,000')), reason: 'not price x units');
    });

    test('a founding seller is told their discount', () {
      final j = _quote()
        ..['discounts'] = {'apply': false, 'record_percent': 0, 'launch_percent': 80};
      expect(feeReasons(ListingFeeQuote.fromJson(j)).last, contains('Founding seller: 80% off'));
    });

    test('recommends months for land, says nothing when a month will do', () {
      final land = recommendationText(ListingFeeQuote.fromJson(_quote()));
      expect(land, startsWith('Land listings like this usually take about 4 months'));
      expect(land, contains('5 months keeps you in front of buyers'));
      expect(recommendationText(ListingFeeQuote.fromJson(_quote(strength: 'none', recommended: 1))), isNull);
    });

    test('the saving is against renewing the period, never a price a month', () {
      // KES 980 for 2 months "costs 11% less a month than renewing" read as
      // a monthly charge.
      final q = ListingFeeQuote.fromJson(_twoMonthQuote(category: 'Automobiles'));
      final text = recommendationText(q);
      expect(text, startsWith('Automobiles listings like this'));
      expect(text, endsWith('and costs 11% less than renewing every 2 months.'));
      expect(text, isNot(contains('a month')));
    });
  });

  group('Paying', () {
    test('sends the choice and one key per attempt', () async {
      final backend = _FeeBackend();
      final r = await backend.repository.pay(
          listingId: 'l1', months: 3, phone: '0712345678', idempotencyKey: 'k1');
      expect(r.isSuccess, isTrue);
      expect(backend.pays.single, {
        'listing_id': 'l1', 'months': 3, 'phone_number': '0712345678'});
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
      expect(find.text('Continue to payment · KES 4,600'), findsOneWidget);
    });

    testWidgets('the price is one payment for its months, never a price a month', (tester) async {
      // "KES 490 a month" under KES 980 read as a monthly bill.
      final backend = _FeeBackend(quote: _twoMonthQuote());
      await _open(tester, ListingFeeScreen(
          listingId: 'l1', listingName: 'Toyota Probox 2014', repository: backend.repository));
      expect(find.text('KES 980 for 2 months'), findsOneWidget);
      expect(find.text('One payment for the whole 2 months.'), findsOneWidget);
      expect(find.text('Paid once for 2 months'), findsOneWidget);
      expect(find.text('Paid once for 4 months · save 11%'), findsOneWidget);
      expect(find.text('Paid once for 6 months · save 17%'), findsOneWidget);
      expect(find.textContaining('a month'), findsNothing);
      expect(find.textContaining('490'), findsNothing);
      expect(find.text('Continue to payment · KES 1,740'), findsOneWidget);
    });

    testWidgets('paying starts at the payment methods, then the number to pay from, at the top',
        (tester) async {
      final backend = _FeeBackend();
      await _open(tester, ListingFeeScreen(
          listingId: 'l1', listingName: 'Plot in Kitengela', repository: backend.repository));
      expect(find.byKey(const Key('mpesa-phone')), findsNothing,
          reason: 'the number is asked for after the method is chosen, not under the months');
      await _tap(tester, find.byKey(const Key('fee-continue')));
      await tester.pumpAndSettle();
      expect(find.byType(PaymentMethodScreen), findsOneWidget);
      expect(find.text('Choose how to pay'.toUpperCase()), findsOneWidget);
      expect(find.byKey(const Key('mpesa-phone')), findsNothing);
      expect(backend.pays, isEmpty);

      await _tap(tester, find.byKey(const Key('method-mpesa')));
      await tester.pumpAndSettle();
      expect(find.byType(MpesaCheckoutScreen), findsOneWidget);
      final phoneTop = tester.getTopLeft(find.byKey(const Key('mpesa-phone'))).dy;
      final summaryTop = tester.getTopLeft(find.byKey(const Key('checkout-summary'))).dy;
      expect(phoneTop, lessThan(summaryTop), reason: 'the number comes first, above what is being paid for');
      expect(find.text('KES 4,600'), findsWidgets);
      expect(find.text('Pay KES 4,600'), findsOneWidget);

      // Back goes to the methods, not out of paying.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PaymentMethodScreen), findsOneWidget);
    });

    testWidgets('the number is the account\'s own to start with, and can be changed', (tester) async {
      final backend = _FeeBackend();
      await _open(tester, MpesaCheckoutScreen(
        order: const CheckoutOrder(title: 'Listing fee', total: 300),
        initialPhone: '0712345678',
        charge: MpesaCharge(
          start: (phone, key) async {
            backend.pays.add({'phone_number': phone});
            return const Success(ChargeStarted(paymentId: 'p1', amount: 300));
          },
          check: (_) async => const Success(ChargeProgress(succeeded: false, pending: true)),
        ),
        success: CheckoutSuccess(title: 'Paid', body: (_) => ''),
      ));
      expect(find.text('0712345678'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('mpesa-phone')), '0722 000 111');
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      await tester.pump();
      expect(backend.pays.single['phone_number'], '0722 000 111');
      expect(find.textContaining('prompt to 0722 000 111'), findsOneWidget);
    });

    testWidgets('pays for the months chosen, then waits for M-Pesa', (tester) async {
      final backend = _FeeBackend();
      await _open(tester, ListingFeeScreen(
          listingId: 'l1', listingName: 'Plot in Kitengela', repository: backend.repository,
          pollEvery: _poll));
      await _tap(tester, find.byKey(const Key('fee-months-3')));
      expect(find.text('Continue to payment · KES 3,010'), findsOneWidget);
      await _toMpesa(tester, '0712 345 678');
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      await tester.pump();
      expect(find.byKey(const Key('checkout-waiting')), findsOneWidget);
      expect(backend.pays.single['months'], 3);
      expect(backend.pays.single.containsKey('featured_plan'), isFalse);

      await tester.pump(_poll); // pending
      expect(find.byKey(const Key('checkout-waiting')), findsOneWidget);
      await tester.pump(_poll); // success
      await tester.pump();
      expect(find.byKey(const Key('checkout-paid')), findsOneWidget);
      expect(find.textContaining('is live until 26 Dec 2026'), findsOneWidget);
    });

    testWidgets('a cancelled prompt says so and the seller can try again', (tester) async {
      final backend = _FeeBackend(statuses: ['failed']);
      await _open(tester, ListingFeeScreen(
          listingId: 'l1', listingName: 'Plot', repository: backend.repository, pollEvery: _poll));
      await _toMpesa(tester, '0712345678');
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      await tester.pump();
      await tester.pump(_poll);
      await tester.pump();
      expect(find.byKey(const Key('checkout-error')), findsOneWidget);
      expect(find.textContaining("didn't complete the payment"), findsOneWidget);
      expect(find.byKey(const Key('mpesa-pay')), findsOneWidget);
    });

    testWidgets('no featured placement, even from a server that offers it', (tester) async {
      // An older server still offering it is ignored: the fee is the only charge.
      final backend = _FeeBackend(quote: _quote(featured: true));
      await _open(tester, ListingFeeScreen(listingId: 'l1', listingName: 'Plot', repository: backend.repository));
      expect(find.byKey(const Key('fee-featured-week')), findsNothing);
      expect(find.text('Feature it at the top of Home?'), findsNothing);
    });

    testWidgets('a number too short to be one is caught before any prompt', (tester) async {
      final backend = _FeeBackend();
      await _open(tester, ListingFeeScreen(listingId: 'l1', listingName: 'Plot', repository: backend.repository));
      await _toMpesa(tester, '0712');
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      expect(find.byKey(const Key('checkout-error')), findsOneWidget);
      expect(backend.pays, isEmpty);
    });

    testWidgets('paid six months ahead: nothing more to buy', (tester) async {
      final backend = _FeeBackend(quote: _quote(monthsAvailable: 0));
      await _open(tester, ListingFeeScreen(listingId: 'l1', listingName: 'Plot', repository: backend.repository));
      expect(find.text('Paid 6 months ahead'), findsOneWidget);
      expect(find.byKey(const Key('fee-continue')), findsNothing);
    });
  });

  group('Free renewal while fees are off', () {
    Map<String, dynamic> expiredQuote() {
      final q = _quote(feesEnabled: false);
      final past = DateTime.now().subtract(const Duration(days: 1)).toIso8601String();
      q['listing_fee'] = {
        'status': 'expired', 'live': false, 'paid_until': past, 'needs_payment': true};
      return q;
    }

    ListingFeeRepository renewBackend({bool fail = false}) =>
        ListingFeeRepository(client: ApiClient(client: MockClient((req) async {
          final path = req.url.path;
          if (path.endsWith('/quote')) return _json(expiredQuote());
          if (path == '/pricing/listing-fee/renew-free') {
            if (fail) return _json({'detail': 'Too early to renew'}, 409);
            final future = DateTime.now().add(const Duration(days: 60)).toIso8601String();
            return _json({
              'listing_id': 'l1',
              'paid_until': future,
              'listing_fee': {'status': 'live', 'live': true,
                'paid_until': future, 'needs_payment': false},
              'time_left': {'status': 'live', 'label': '60d 0h left',
                'seconds_left': 5184000, 'is_expiring_soon': false},
            });
          }
          return _json({'detail': 'Not found'}, 404);
        })));

    Future<void> openRenew(WidgetTester tester, ListingFeeRepository repository,
        {required void Function(bool? popped) onPop}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Builder(
            builder: (ctx) => ElevatedButton(
                  onPressed: () async => onPop(await Navigator.of(ctx).push<bool>(
                      MaterialPageRoute(
                          builder: (_) => ListingFeeScreen(
                              listingId: 'l1', listingName: 'Plot', repository: repository)))),
                  child: const Text('go'),
                )),
      ));
      await _tap(tester, find.text('go'));
      await tester.pumpAndSettle();
    }

    test('renew-free parses the extended window', () async {
      final r = await renewBackend().renewFree(listingId: 'l1');
      expect(r.isSuccess, isTrue);
      expect(r.data.paidUntil, isNotNull);
      expect(r.data.state?.status, 'live');
      expect(r.data.timeLeft?.label, '60d 0h left');
    });

    testWidgets('an expired window offers a free renewal that pops paid', (tester) async {
      bool? popped;
      await openRenew(tester, renewBackend(), onPop: (p) => popped = p);
      expect(find.text('Your listing is offline'), findsOneWidget);
      expect(find.byKey(const Key('fee-renew-free')), findsOneWidget);
      await _tap(tester, find.text('Renew free'));
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      expect(find.text('go'), findsOneWidget);
    });

    testWidgets('a refused renewal says so and stays', (tester) async {
      bool? popped;
      await openRenew(tester, renewBackend(fail: true), onPop: (p) => popped = p);
      await _tap(tester, find.text('Renew free'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(popped, isNull);
      expect(find.byKey(const Key('fee-renew-free')), findsOneWidget);
    });

    /// A shop whose plan pays for 20 listings: [covered] says whether this
    /// listing of the owner's own is already on one of its places.
    ListingFeeRepository planBackend({required bool covered, List<String>? calls}) =>
        ListingFeeRepository(client: ApiClient(client: MockClient((req) async {
          final path = req.url.path;
          calls?.add(path);
          if (path.endsWith('/quote')) {
            return _json({
              ..._twoMonthQuote(),
              'fees_enabled': false,
              'store_plan': {
                'store_id': 's1', 'store_name': 'Clanix', 'places': 20,
                'in_use': covered ? 7 : 6, 'free': covered ? 13 : 14,
                'until': '2027-01-20T10:00:00', 'covered': covered,
              },
            });
          }
          if (path == '/pricing/listing-fee/renew-free') {
            return _json({
              'listing_id': 'l1',
              'paid_until': '2027-01-20T10:00:00',
              'listing_fee': {'status': 'live', 'live': true,
                'paid_until': '2027-01-20T10:00:00', 'needs_payment': false},
              'time_left': {'status': 'live', 'label': '61d 0h left',
                'seconds_left': 5270400, 'is_expiring_soon': false},
            });
          }
          return _json({'detail': 'Not found'}, 404);
        })));

    testWidgets('a place free on the store plan puts the listing up with no fee', (tester) async {
      // A shop that paid for 20 listings was asked for a fee on its own
      // listing posted under "No Store".
      final calls = <String>[];
      bool? popped;
      await openRenew(tester, planBackend(covered: false, calls: calls), onPop: (p) => popped = p);
      expect(find.text('Your store plan covers this one'), findsOneWidget);
      expect(find.textContaining('20 listings and 14 places are free'), findsOneWidget);
      expect(find.byKey(const Key('fee-continue')), findsNothing,
          reason: 'never a fee the plan already covers');
      await _tap(tester, find.text('Put it up free'));
      await tester.pumpAndSettle();
      expect(calls, contains('/pricing/listing-fee/renew-free'));
      expect(popped, isTrue);
    });

    testWidgets('a listing already on the store plan has nothing to pay', (tester) async {
      await openRenew(tester, planBackend(covered: true), onPop: (_) {});
      expect(find.text('Covered by your store plan'), findsOneWidget);
      expect(find.textContaining('one of the 20 listings your Clanix plan pays for'), findsOneWidget);
      expect(find.byKey(const Key('fee-continue')), findsNothing);
      expect(find.text('Put it up free'), findsNothing);
    });
  });

  group('Waiting for payment', () {
    Map<String, dynamic> awaiting(String id, String status) => {
          'id': id, 'name': 'Calculator $id', 'price': 1500,
          'listing_fee': {'status': status, 'live': status == 'ending', 'paid_until': '2026-10-05T10:00:00',
            'needs_payment': true},
        };

    testWidgets('an unpaid listing can be removed, after asking', (tester) async {
      final deleted = <String>[];
      final fees = ListingFeeRepository(client: ApiClient(client: MockClient((req) async => _json({
            'listings': [awaiting('a', 'unpaid'), awaiting('b', 'expired'), awaiting('c', 'ending')],
          }))));
      final listings = ListingsRepository(client: ApiClient(client: MockClient((req) async {
        if (req.method == 'DELETE') deleted.add(req.url.path);
        return _json({'deleted': true});
      })));
      await _open(tester, Scaffold(body: SingleChildScrollView(
          child: AwaitingPaymentPanel(repository: fees, listings: listings))));
      expect(find.byKey(const Key('awaiting-remove-a')), findsOneWidget);
      expect(find.byKey(const Key('awaiting-remove-b')), findsOneWidget, reason: 'ended and hidden: removable too');
      expect(find.byKey(const Key('awaiting-remove-c')), findsNothing,
          reason: 'still live: deleted from the catalogue like any live listing');

      // Keep it: nothing is deleted.
      await _tap(tester, find.byKey(const Key('awaiting-remove-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);
      expect(find.text('Calculator a'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('awaiting-remove-a')));
      await tester.pumpAndSettle();
      expect(find.textContaining('nothing is charged'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-remove-unpaid')));
      await tester.pumpAndSettle();
      expect(deleted, ['/listings/a']);
      expect(find.text('Calculator a'), findsNothing);
      expect(find.text('Calculator b'), findsOneWidget);
    });

    testWidgets('a refusal is shown and the listing stays', (tester) async {
      final fees = ListingFeeRepository(client: ApiClient(client: MockClient((req) async => _json({
            'listings': [awaiting('a', 'unpaid')],
          }))));
      final listings = ListingsRepository(client: ApiClient(client: MockClient((req) async =>
          _json({'detail': 'A buyer has a deal on this listing.'}, 409))));
      await _open(tester, Scaffold(body: SingleChildScrollView(
          child: AwaitingPaymentPanel(repository: fees, listings: listings))));
      await _tap(tester, find.byKey(const Key('awaiting-remove-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-remove-unpaid')));
      await tester.pumpAndSettle();
      expect(find.text('A buyer has a deal on this listing.'), findsOneWidget);
      expect(find.text('Calculator a'), findsOneWidget);
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
      await _toMpesa(tester, '0712345678');
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      await tester.pumpAndSettle();
      expect(find.byType(ListingFeeScreen), findsNothing);
      expect(find.byType(PaymentMethodScreen), findsNothing);
      expect(find.byType(MpesaCheckoutScreen), findsNothing);
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
