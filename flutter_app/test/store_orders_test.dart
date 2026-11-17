// Store orders in the app (backend api/domains/store_orders/): the models,
// the requests the seller tools send, My Store's Orders tab, the order
// screen's actions and payment record, the stock controls, the pause
// switch, and the push that opens an order.
//
// HTTP goes through a MockClient behind an injected ApiClient; nothing
// here reaches a network.
import 'dart:async';
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/listings/data/repositories/listings_repository.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/domain/models/store_campaign.dart';
import 'package:broka/features/stores/domain/models/store_insights.dart';
import 'package:broka/features/stores/domain/models/store_order.dart';
import 'package:broka/features/stores/domain/models/store_product.dart';
import 'package:broka/features/stores/presentation/my_store_screen.dart';
import 'package:broka/features/stores/presentation/store_order_screen.dart';
import 'package:broka/features/stores/presentation/widgets/store_stock_sheet.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// A backend: [routes] maps "METHOD /path" to a handler. Every request is
/// recorded; anything unrouted answers 404, as an unknown path would.
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

  List<Map<String, dynamic>> bodies(String method, String path) => [
        for (final r in requests)
          if (r.method == method && r.url.path == path) jsonDecode(r.body) as Map<String, dynamic>,
      ];

  List<http.Request> calls(String method, String path) =>
      [for (final r in requests) if (r.method == method && r.url.path == path) r];
}

const _notice = 'BROKA does not receive, hold, verify or release payments for store orders. '
    'These are reports made by the buyer or the store, not confirmations from BROKA or from '
    'any payment provider.';

Map<String, dynamic> _storeJson({bool ordersEnabled = true, bool accepting = true, String? pauseNote}) => {
      'id': 's1',
      'name': 'Clanix Electronics',
      'slug': 'clanix',
      'url': 'https://broka.co.ke/store/clanix',
      'category': 'Electronics',
      'categories': ['Electronics'],
      'description': 'Phones',
      'county': 'Nairobi',
      'subcounty': 'Starehe',
      'location_description': 'Moi Avenue',
      'logo': null,
      'cover': null,
      'photo_images': [],
      'logo_url': null,
      'photos': [],
      'owner': {'verified': true, 'rating': 4.8, 'completed_deals': 12, 'member_since': '2025-01-10T00:00:00'},
      'is_active': true,
      'listing_count': 1,
      'orders_enabled': ordersEnabled,
      'accepting_orders': accepting,
      'orders_pause_note': accepting ? null : pauseNote,
    };

Map<String, dynamic> _payment({
  List<Map<String, dynamic>> reports = const [],
  List<String> allowed = const [],
  String summary = 'No payment reported yet',
  String? arrangement,
}) =>
    {
      'arrangement': arrangement,
      'arrangement_label': arrangement == null ? null : 'Direct payment to the store',
      'provider': null,
      'reports': reports,
      'summary': {
        'label': summary,
        'awaiting_external_confirmation': summary == 'Awaiting external confirmation',
        'status_note': null,
        'verified': false,
      },
      'can_choose': false,
      'allowed_reports': allowed,
      'notice': _notice,
    };

/// One order as GET /orders/{id} returns it to the store.
Map<String, dynamic> _order({
  String status = 'submitted',
  String label = 'New order request',
  List<String> actions = const ['accept', 'propose', 'decline'],
  Map<String, dynamic>? payment,
  String? declineReason,
  String role = 'seller',
}) =>
    {
      'id': 'o1',
      'reference': 'BK-1001',
      'role': role,
      'status': status,
      'status_label': label,
      'open': !['declined', 'cancelled', 'expired', 'completed'].contains(status),
      'store': {'id': 's1', 'name': 'Clanix Electronics', 'slug': 'clanix',
          'url': 'https://broka.co.ke/store/clanix'},
      'currency': 'KES',
      'items': [
        {
          'id': 'i1',
          'listing_id': 'l1',
          'name': 'Samsung A15',
          'price_unit': null,
          'image': null,
          'requested_quantity': 2,
          'requested_unit_price_minor': 1500000,
          'requested_line_total_minor': 3000000,
          'proposed_quantity': null,
          'proposed_unit_price_minor': null,
          'final_quantity': null,
          'final_unit_price_minor': null,
          'quantity': 2,
          'unit_price_minor': 1500000,
          'line_total_minor': 3000000,
          'changed': false,
          'removed': false,
          'stock_tracked': true,
          'stock_on_hand': 5,
          'stock_available': 5,
          'reserved_quantity': 0,
          'stock_state': 'none',
        },
      ],
      'totals': {
        'requested_subtotal_minor': 3000000,
        'seller_subtotal_minor': null,
        'delivery_fee_minor': null,
        'total_minor': null,
        'display_total_minor': 3000000,
        'final': false,
      },
      'fulfilment': {
        'method': 'delivery',
        'requested_method': 'delivery',
        'address': 'Kilimani, opposite Yaya Centre',
        'contact_phone': '+254712345678',
        'note': null,
        'dispatch_note': null,
      },
      'buyer_note': 'Call when near',
      'seller_note': null,
      'decline_reason': declineReason,
      'cancel_reason': null,
      'cancelled_by': null,
      'problem': null,
      'revision': 0,
      'expires_at': status == 'submitted' ? '2026-11-18T08:00:00' : null,
      'expiry_stage': status == 'submitted' ? 'seller_response' : null,
      'allowed_actions': actions,
      'payment': payment ?? _payment(),
      'events': [
        {
          'id': 'e1',
          'kind': 'submitted',
          'label': 'Order request sent',
          'actor_role': 'buyer',
          'from_status': null,
          'to_status': 'submitted',
          'revision': 0,
          'detail': null,
          'created_at': '2026-11-17T08:00:00',
        },
      ],
      'created_at': '2026-11-17T08:00:00',
      'updated_at': '2026-11-17T08:00:00',
      'buyer': {'name': 'Amina Wanjiku', 'phone_verified': true},
      'attribution': {'surface': 'web', 'source': 'whatsapp', 'campaign': null},
    };

Map<String, dynamic> _summary() => {
      'id': 'o1',
      'reference': 'BK-1001',
      'status': 'submitted',
      'status_label': 'New order request',
      'open': true,
      'needs_action': true,
      'item_count': 2,
      'first_item': 'Samsung A15',
      'currency': 'KES',
      'total_minor': 3000000,
      'final': false,
      'fulfilment': 'delivery',
      'created_at': '2026-11-17T08:00:00',
      'updated_at': '2026-11-17T08:00:00',
      'expires_at': '2026-11-18T08:00:00',
      'store': {'id': 's1', 'name': 'Clanix Electronics', 'slug': 'clanix'},
      'buyer_name': 'Amina Wanjiku',
      'problem_reported': false,
    };

Map<String, dynamic> _ordersSummary({bool accepting = true}) => {
      'counts': {
        'needs_action': 1,
        'awaiting_buyer': 0,
        'ready_or_dispatched': 0,
        'completed': 0,
        'closed': 0,
        'by_status': {'submitted': 1},
      },
      'pipeline': {'awaiting_store': 1},
      'unread': 1,
      'accepting_orders': accepting,
    };

/// One product as GET /stores/{id}/manage/listings returns it.
Map<String, dynamic> _product({bool tracked = false, int? quantity, int reserved = 0, int? available}) => {
      'id': 'l1',
      'seller_id': 'u1',
      'name': 'Samsung A15',
      'category': 'Electronics',
      'price': 15000,
      'lat': -1.28,
      'lng': 36.8,
      'listing_type': 'direct',
      'status': 'active',
      'photos': [],
      'cover': null,
      'quantity': quantity,
      'store_id': 's1',
      'store_slug': 'clanix',
      'store_name': 'Clanix Electronics',
      'store_state': 'live',
      'listing_fee': {'status': 'free', 'live': true, 'paid_until': null, 'needs_payment': false},
      'stock_tracked': tracked,
      'stock_reserved': reserved,
      'available_quantity': available,
      'temporarily_unavailable': false,
    };

void _tallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
}

Future<_Backend> _openMyStore(
  WidgetTester tester, {
  Map<String, dynamic>? store,
  Map<String, FutureOr<http.Response> Function(http.Request)> more = const {},
}) async {
  _tallPhone(tester);
  final backend = _Backend({
    'GET /stores/mine': (_) => _json(store ?? _storeJson()),
    'GET /stores/s1/manage/listings': (_) => _json({
          'items': [_product()],
          'counts': {'all': 1, 'live': 1, 'hidden': 0, 'in_deal': 0, 'sold': 0},
        }),
    ...more,
  });
  await tester.pumpWidget(MaterialApp(
      home: MyStoreScreen(
          repository: backend.repo,
          listings: ListingsRepository(client: backend.client),
          animateBackground: false)));
  await tester.pumpAndSettle();
  return backend;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'u1';
  });

  group('Store order models', () {
    test('an order reads as the API sends it', () {
      final o = StoreOrder.fromJson(_order());
      expect(o.reference, 'BK-1001');
      expect(o.isSeller, isTrue);
      expect(o.status, StoreOrderStatus.submitted);
      expect(o.statusLabel, 'New order request');
      expect(o.items.single.quantity, 2);
      expect(o.items.single.stockTracked, isTrue);
      expect(o.displayTotalMinor, 3000000);
      expect(o.totalMinor, isNull);
      expect(o.isDelivery, isTrue);
      expect(o.expiryStage, 'seller_response');
      expect(o.buyerName, 'Amina Wanjiku');
      expect(o.source, 'whatsapp');
      expect(o.allowedActions,
          [StoreOrderAction.accept, StoreOrderAction.propose, StoreOrderAction.decline]);
      expect(o.payment.notice, _notice);
    });

    test('a status or an action this app does not know is never acted on', () {
      final o = StoreOrder.fromJson({..._order(), 'status': 'teleported', 'allowed_actions': ['accept', 'beam_up']});
      expect(o.status, StoreOrderStatus.unknown);
      expect(o.allowedActions, [StoreOrderAction.accept]);
    });

    test('amounts are cents from the API, shown as shillings', () {
      expect(formatMinorKes(1530000), 'KES 15,300');
      expect(formatMinorKes(150050), 'KES 1,500.50');
      expect(formatMinorKes(5), 'KES 0.05');
      expect(formatMinorKes(null), '');
    });

    test("insights' orders block keeps every rate's counts, and is absent from older APIs", () {
      final orders = StoreOrderInsights.fromJson({
        'enabled': true,
        'accepting': true,
        'kpis': {
          'requests': {'value': 8, 'previous': 4, 'change_percent': 100.0},
          'completed': {'value': 3, 'previous': 0, 'change_percent': null},
        },
        'completed_value_minor': 4500000,
        'rates': [
          {'key': 'request_to_acceptance', 'numerator': 3, 'denominator': 8, 'percent': 37.5,
              'definition': 'Of the order requests made in the period, the share the store answered.'},
        ],
        'pipeline': {'awaiting_store': 2, 'stale_requests': 1, 'to_fulfil': 1},
        'definitions': {'requests': 'Order requests buyers sent in the period. A request is not a sale.'},
      })!;
      expect(orders.requests.value, 8);
      expect(orders.completed.isNew, isTrue);
      expect(orders.rates.single.numerator, 3);
      expect(orders.rates.single.denominator, 8);
      expect(orders.rates.single.label, 'Requests the store answered');
      expect(orders.staleRequests, 1);
      expect(StoreOrderInsights.fromJson(null), isNull);
      final insights = StoreInsights.fromJson({'store': {'id': 's1', 'name': 'Clanix', 'slug': 'clanix'}});
      expect(insights.orders, isNull);
    });

    test('campaigns count orders from their links only when the API sends them', () {
      final withOrders = CampaignEvents.fromJson({
        'by_kind': {'visit': 4},
        'orders': {'order_requests': 3, 'confirmed_orders': 2, 'completed_orders': 1},
      });
      expect(withOrders.orders?.requests, 3);
      expect(withOrders.orders?.confirmed, 2);
      expect(withOrders.orders?.completed, 1);
      expect(CampaignEvents.fromJson({'by_kind': {'visit': 4}}).orders, isNull);
    });

    test("a product's stock: untracked is never out of stock", () {
      final untracked = StoreProduct.fromJson(_product(quantity: 3));
      expect(untracked.stockTracked, isFalse);
      expect(untracked.outOfStock, isFalse);
      expect(storeStockNote(untracked), isNull);

      final gone = StoreProduct.fromJson(_product(tracked: true, quantity: 2, reserved: 2, available: 0));
      expect(gone.outOfStock, isTrue);
      expect(storeStockNote(gone), 'Out of stock');

      final some = StoreProduct.fromJson(_product(tracked: true, quantity: 5, reserved: 2, available: 3));
      expect(storeStockNote(some), '3 in stock to order · 2 set aside');
    });

    test('a store without the orders switch shows no orders', () {
      final old = Store.fromJson(_storeJson()
        ..remove('orders_enabled')
        ..remove('accepting_orders')
        ..remove('orders_pause_note'));
      expect(old.ordersEnabled, isFalse);
      expect(old.acceptingOrders, isTrue);
      final paused = Store.fromJson(_storeJson(accepting: false, pauseNote: 'Back on Monday'));
      expect(paused.acceptingOrders, isFalse);
      expect(paused.ordersPauseNote, 'Back on Monday');
    });
  });

  group('What the seller tools send', () {
    late _Backend backend;
    setUp(() {
      backend = _Backend({
        for (final path in ['accept', 'propose', 'decline', 'cancel', 'preparing', 'dispatch', 'payment-reports'])
          'POST /orders/o1/$path': (_) => _json(_order(status: 'awaiting_buyer_confirmation')),
        'PATCH /stores/s1/manage/listings/l1/stock': (_) => _json({
              'listing_id': 'l1',
              'stock_tracked': true,
              'quantity': 5,
              'stock_reserved': 0,
              'available_quantity': 5,
              'temporarily_unavailable': false,
            }),
        'PATCH /stores/s1': (r) => _json({..._storeJson(), ...jsonDecode(r.body) as Map}),
        'GET /stores/s1/orders': (_) => _json({'items': [_summary()], 'total': 1}),
      });
    });

    test('accepting sends the delivery charge in cents and a trimmed note, nothing else', () async {
      final r = await backend.repo.acceptOrder('o1', deliveryFeeMinor: 30000, sellerNote: '  Ready by 5  ');
      expect(r, isA<Success<StoreOrder>>());
      expect(backend.bodies('POST', '/orders/o1/accept').single,
          {'delivery_fee_minor': 30000, 'seller_note': 'Ready by 5'});
    });

    test('a proposal names each line by item, with its quantity and price', () async {
      await backend.repo.proposeOrderChanges('o1',
          items: const [ProposedOrderItem(itemId: 'i1', quantity: 1, unitPriceMinor: 1400000)],
          fulfilment: 'collection',
          sellerNote: 'Only one left');
      expect(backend.bodies('POST', '/orders/o1/propose').single, {
        'items': [
          {'item_id': 'i1', 'quantity': 1, 'unit_price_minor': 1400000},
        ],
        'fulfilment': 'collection',
        'seller_note': 'Only one left',
      });
    });

    test('decline and cancel carry the reason; a blank reason is not sent', () async {
      await backend.repo.declineOrder('o1', ' Out of stock ');
      await backend.repo.cancelOrder('o1', reason: '   ');
      expect(backend.bodies('POST', '/orders/o1/decline').single, {'reason': 'Out of stock'});
      expect(backend.bodies('POST', '/orders/o1/cancel').single, isEmpty);
    });

    test('fulfilment steps post to their own paths', () async {
      await backend.repo.startPreparingOrder('o1');
      await backend.repo.dispatchOrder('o1', note: 'Rider Kevin');
      expect(backend.calls('POST', '/orders/o1/preparing'), hasLength(1));
      expect(backend.bodies('POST', '/orders/o1/dispatch').single, {'dispatch_note': 'Rider Kevin'});
    });

    test("a payment report is the seller's own, with an optional reference", () async {
      await backend.repo.reportOrderPayment('o1', kind: 'seller_confirmed_receipt', reference: ' QK12AB34 ');
      expect(backend.bodies('POST', '/orders/o1/payment-reports').single,
          {'kind': 'seller_confirmed_receipt', 'reference': 'QK12AB34'});
    });

    test('stock: the three switches go to the stock endpoint', () async {
      final r = await backend.repo.setListingStock('s1', 'l1',
          tracked: true, quantity: 5, temporarilyUnavailable: false);
      expect((r as Success<StoreListingStock>).data.availableQuantity, 5);
      expect(backend.bodies('PATCH', '/stores/s1/manage/listings/l1/stock').single,
          {'stock_tracked': true, 'quantity': 5, 'temporarily_unavailable': false});
    });

    test('pausing new orders carries the note for buyers; resuming sends none', () async {
      await backend.repo.setAcceptingOrders('s1', false, note: ' Back on Monday ');
      await backend.repo.setAcceptingOrders('s1', true);
      expect(backend.bodies('PATCH', '/stores/s1'), [
        {'accepting_orders': false, 'orders_pause_note': 'Back on Monday'},
        {'accepting_orders': true},
      ]);
    });

    test('the order list asks for one group', () async {
      final r = await backend.repo.getStoreOrders('s1', group: 'awaiting_buyer');
      expect((r as Success<StoreOrdersPage>).data.items.single.itemsLine, 'Samsung A15 and 1 more');
      expect(backend.calls('GET', '/stores/s1/orders').single.url.queryParameters['group'], 'awaiting_buyer');
    });

    test("a refusal comes back in the server's words", () async {
      final refusing = _Backend({
        'POST /orders/o1/accept': (_) => _json({
              'detail': {'code': 'ORDER_STOCK_SHORT', 'message': 'Only 1 of Samsung A15 is left.'},
            }, 409),
      });
      final r = await refusing.repo.acceptOrder('o1');
      expect(r, isA<Failure<StoreOrder>>());
      expect((r as Failure<StoreOrder>).message, 'Only 1 of Samsung A15 is left.');
    });
  });

  group('My Store: Orders', () {
    testWidgets('no Orders tab while store orders are off', (tester) async {
      await _openMyStore(tester, store: _storeJson(ordersEnabled: false));
      expect(find.text('Orders'), findsNothing);
      expect(find.byKey(const Key('my-store-tab-4')), findsNothing);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('the Orders tab lists what waits on the store; an order opens with its actions',
        (tester) async {
      final backend = await _openMyStore(tester, more: {
        'GET /stores/s1/orders': (_) => _json({'items': [_summary()], 'total': 1}),
        'GET /stores/s1/orders/summary': (_) => _json(_ordersSummary()),
        'GET /orders/o1': (_) => _json(_order()),
        'POST /orders/notifications/read': (_) => _json({'marked': 1, 'unread': 0}),
        'POST /orders/o1/accept': (_) => _json(_order(
              status: 'awaiting_buyer_confirmation',
              label: 'Waiting for the buyer to confirm',
              actions: ['propose', 'decline'],
            )),
      });
      // Orders sits before Settings: Products and Marketing keep their places.
      expect(find.byKey(const Key('my-store-tab-3')), findsOneWidget);
      await tester.tap(find.text('Orders'));
      await tester.pumpAndSettle();

      expect(backend.calls('GET', '/stores/s1/orders').single.url.queryParameters['group'], 'needs_action');
      expect(find.text('To do · 1'), findsOneWidget);
      expect(find.text('BK-1001 · Amina Wanjiku'), findsOneWidget);
      expect(find.text('Samsung A15 and 1 more'), findsOneWidget);
      expect(find.text('KES 30,000'), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-order-o1')));
      await tester.pumpAndSettle();
      expect(find.text('New order request'), findsOneWidget);
      expect(find.byKey(const Key('order-deadline')), findsOneWidget);
      // Opening the order reads its updates.
      expect(backend.bodies('POST', '/orders/notifications/read').single, {'order_id': 'o1'});
      // Only what the API allows now.
      expect(find.byKey(const Key('order-action-accept')), findsOneWidget);
      expect(find.byKey(const Key('order-action-propose')), findsOneWidget);
      expect(find.byKey(const Key('order-action-decline')), findsOneWidget);
      expect(find.byKey(const Key('order-action-dispatch')), findsNothing);

      // Accepting asks first, and nothing is sent until the seller says yes.
      await tester.tap(find.byKey(const Key('order-action-accept')));
      await tester.pumpAndSettle();
      expect(find.text('Accept this order?'), findsOneWidget);
      expect(backend.calls('POST', '/orders/o1/accept'), isEmpty);
      await tester.enterText(find.byKey(const Key('accept-delivery-fee')), '300');
      await tester.tap(find.byKey(const Key('accept-yes')));
      await tester.pumpAndSettle();
      expect(backend.bodies('POST', '/orders/o1/accept').single, {'delivery_fee_minor': 30000});
      expect(find.text('Waiting for the buyer to confirm'), findsOneWidget);
      expect(find.byKey(const Key('order-action-accept')), findsNothing);
    });

    testWidgets('a paused store says so on the tab, and can start again from there', (tester) async {
      var accepting = false;
      final backend = await _openMyStore(tester,
          store: _storeJson(accepting: false, pauseNote: 'Back on Monday'),
          more: {
            'GET /stores/s1/orders': (_) => _json({'items': [], 'total': 0}),
            'GET /stores/s1/orders/summary': (_) => _json(_ordersSummary(accepting: accepting)),
            'PATCH /stores/s1': (_) {
              accepting = true;
              return _json(_storeJson());
            },
          });
      await tester.tap(find.text('Orders'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('orders-paused')), findsOneWidget);
      expect(find.textContaining('Back on Monday'), findsOneWidget);
      await tester.tap(find.byKey(const Key('orders-resume')));
      await tester.pumpAndSettle();
      expect(backend.bodies('PATCH', '/stores/s1').single, {'accepting_orders': true});
      expect(find.byKey(const Key('orders-paused')), findsNothing);
    });

    testWidgets('Settings: pausing new orders asks what buyers should be told', (tester) async {
      final backend = await _openMyStore(tester, more: {
        'PATCH /stores/s1': (r) {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          return _json(_storeJson(
              accepting: body['accepting_orders'] as bool,
              pauseNote: body['orders_pause_note'] as String?));
        },
      });
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Taking new orders'), findsOneWidget);
      await tester.tap(find.byKey(const Key('accepting-orders-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Pause new orders?'), findsOneWidget);
      expect(backend.calls('PATCH', '/stores/s1'), isEmpty);
      await tester.enterText(find.byKey(const Key('pause-orders-note')), 'Back on Monday');
      await tester.tap(find.byKey(const Key('confirm-pause-orders')));
      await tester.pumpAndSettle();
      expect(backend.bodies('PATCH', '/stores/s1').single,
          {'accepting_orders': false, 'orders_pause_note': 'Back on Monday'});
      expect(find.text('Paused. Buyers see: "Back on Monday"'), findsOneWidget);
    });

    testWidgets("Products: counting a product's stock", (tester) async {
      final backend = await _openMyStore(tester, more: {
        'PATCH /stores/s1/manage/listings/l1/stock': (_) => _json({
              'listing_id': 'l1',
              'stock_tracked': true,
              'quantity': 5,
              'stock_reserved': 0,
              'available_quantity': 5,
              'temporarily_unavailable': false,
            }),
      });
      await tester.tap(find.text('Products'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('store-product-l1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-action-stock')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stock-tracked-switch')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('stock-quantity-field')), '5');
      await tester.tap(find.byKey(const Key('stock-save')));
      await tester.pumpAndSettle();
      expect(backend.bodies('PATCH', '/stores/s1/manage/listings/l1/stock').single,
          {'stock_tracked': true, 'quantity': 5, 'temporarily_unavailable': false});
    });

    testWidgets('no stock controls while store orders are off', (tester) async {
      await _openMyStore(tester, store: _storeJson(ordersEnabled: false));
      await tester.tap(find.text('Products'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('store-product-l1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('product-action-stock')), findsNothing);
      expect(find.byKey(const Key('product-action-price')), findsOneWidget);
    });
  });

  group('The order screen', () {
    Future<_Backend> openOrder(WidgetTester tester, Map<String, dynamic> order,
        {Map<String, FutureOr<http.Response> Function(http.Request)> more = const {}}) async {
      _tallPhone(tester);
      final backend = _Backend({
        'GET /orders/o1': (_) => _json(order),
        'POST /orders/notifications/read': (_) => _json({'marked': 0, 'unread': 0}),
        ...more,
      });
      await tester.pumpWidget(MaterialApp(home: StoreOrderScreen(orderId: 'o1', repo: backend.repo)));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('declining needs a reason the buyer will see', (tester) async {
      final backend = await openOrder(tester, _order(), more: {
        'POST /orders/o1/decline': (_) => _json(_order(
              status: 'declined', label: 'Declined', actions: [], declineReason: 'Out of stock')),
      });
      await tester.tap(find.byKey(const Key('order-action-decline')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('order-prompt-yes')));
      await tester.pumpAndSettle();
      expect(find.text('Say why, in a few words - the buyer will see it.'), findsOneWidget);
      expect(backend.calls('POST', '/orders/o1/decline'), isEmpty);

      await tester.enterText(find.byKey(const Key('order-prompt-field')), 'Out of stock');
      await tester.tap(find.byKey(const Key('order-prompt-yes')));
      await tester.pumpAndSettle();
      expect(backend.bodies('POST', '/orders/o1/decline').single, {'reason': 'Out of stock'});
      expect(find.text('Declined: Out of stock'), findsOneWidget);
      // An order that ended without a sale has nothing to pay and nothing to do.
      expect(find.text('Payment'), findsNothing);
      expect(find.byKey(const Key('order-action-decline')), findsNothing);
    });

    testWidgets('"Not now" sends nothing', (tester) async {
      final backend = await openOrder(tester,
          _order(status: 'confirmed', label: 'Confirmed - ready to prepare', actions: ['start_preparing', 'dispatch', 'cancel']));
      await tester.tap(find.byKey(const Key('order-action-start_preparing')));
      await tester.pumpAndSettle();
      expect(find.text('Start preparing?'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(backend.calls('POST', '/orders/o1/preparing'), isEmpty);
    });

    testWidgets('a refusal is shown in the server\'s words, and the order is read again', (tester) async {
      final backend = await openOrder(tester,
          _order(status: 'confirmed', label: 'Confirmed - ready to prepare', actions: ['start_preparing', 'dispatch', 'cancel']),
          more: {
            'POST /orders/o1/preparing': (_) => _json({
                  'detail': {'code': 'ORDER_STATE_CONFLICT', 'message': 'The buyer cancelled this order.'},
                }, 409),
          });
      await tester.tap(find.byKey(const Key('order-action-start_preparing')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('order-confirm-yes')));
      await tester.pumpAndSettle();
      expect(find.text('The buyer cancelled this order.'), findsOneWidget);
      expect(backend.calls('GET', '/orders/o1'), hasLength(2));
    });

    testWidgets('payment lines say who reported them, and that BROKA verified nothing', (tester) async {
      final backend = await openOrder(
        tester,
        _order(
          status: 'confirmed',
          label: 'Confirmed - ready to prepare',
          actions: ['start_preparing', 'dispatch', 'cancel'],
          payment: _payment(
            arrangement: 'direct_to_seller',
            summary: 'Awaiting external confirmation',
            allowed: ['seller_confirmed_receipt'],
            reports: [
              {
                'kind': 'buyer_reported_payment_sent',
                'label': 'Buyer reported payment sent',
                'actor_role': 'buyer',
                'reference': 'QK12AB34',
                'note': null,
                'created_at': '2026-11-17T09:00:00',
                'verified': false,
              },
            ],
          ),
        ),
        more: {
          'POST /orders/o1/payment-reports': (_) => _json(_order(status: 'confirmed', actions: const [])),
        },
      );
      expect(find.byKey(const Key('order-payment-notice')), findsOneWidget);
      expect(find.text('Buyer reported payment sent'), findsOneWidget);
      expect(find.textContaining('Reported by the buyer'), findsOneWidget);
      expect(find.textContaining('not verified by BROKA'), findsOneWidget);
      expect(find.text('Awaiting external confirmation'), findsOneWidget);
      expect(find.textContaining('Payment verified'), findsNothing);
      expect(find.textContaining('BROKA verified'), findsNothing);

      final report = find.byKey(const Key('order-report-seller_confirmed_receipt'));
      await tester.ensureVisible(report);
      await tester.pumpAndSettle();
      await tester.tap(report);
      await tester.pumpAndSettle();
      expect(find.text('Record that you received the payment?'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('order-prompt-field')), 'QK12AB34');
      await tester.tap(find.byKey(const Key('order-prompt-yes')));
      await tester.pumpAndSettle();
      expect(backend.bodies('POST', '/orders/o1/payment-reports').single,
          {'kind': 'seller_confirmed_receipt', 'reference': 'QK12AB34'});
    });

    testWidgets('a proposal lowers a quantity and sends every line', (tester) async {
      final backend = await openOrder(tester, _order(), more: {
        'POST /orders/o1/propose': (_) => _json(_order(
              status: 'seller_proposed_changes',
              label: 'Waiting for the buyer to review your changes',
              actions: ['propose', 'decline'],
            )),
      });
      await tester.tap(find.byKey(const Key('order-action-propose')));
      await tester.pumpAndSettle();
      expect(find.text('Propose changes'), findsWidgets);
      await tester.tap(find.byKey(const Key('propose-less-i1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('propose-qty-i1')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('propose-qty-i1'))).data, '1');
      await tester.tap(find.byKey(const Key('propose-send')));
      await tester.pumpAndSettle();
      expect(backend.bodies('POST', '/orders/o1/propose').single, {
        'items': [
          {'item_id': 'i1', 'quantity': 1, 'unit_price_minor': 1500000},
        ],
      });
      expect(find.text('Waiting for the buyer to review your changes'), findsOneWidget);
    });
  });

  group('The push about an order', () {
    tearDown(() async {
      SharedPreferences.setMockInitialValues({});
      await ApiService.loadSavedSession();
    });

    Future<List<RouteSettings>> tapPush(WidgetTester tester, Map<String, dynamic> data) async {
      final key = GlobalKey<NavigatorState>();
      NotificationService.instance.navigatorKey = key;
      final opened = <RouteSettings>[];
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        home: const SizedBox(),
        onGenerateRoute: (s) {
          opened.add(s);
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
      ));
      await NotificationService.instance.navigateFromPayload(data);
      await tester.pump();
      return opened;
    }

    testWidgets('opens the order it is about', (tester) async {
      SharedPreferences.setMockInitialValues({'auth_token': 'tok', 'user_id': 'seller-1'});
      await ApiService.loadSavedSession();
      final opened = await tapPush(tester, {
        'type': 'store_order',
        'order_id': 'o1',
        'status': 'submitted',
        'event': 'submitted',
        'role': 'seller',
        'screen': 'store_order',
      });
      expect(opened.map((s) => s.name).toList(), ['/store-order']);
      expect(opened.single.arguments, {'orderId': 'o1'});
    });

    testWidgets('a signed-out phone signs in first', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await ApiService.loadSavedSession();
      final opened = await tapPush(tester, {'type': 'store_order', 'order_id': 'o1'});
      expect(opened.map((s) => s.name).toList(), ['/auth']);
    });
  });
}
