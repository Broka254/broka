// The Seller Dashboard on Home's visual system (2026-09-26): the
// constellation, the shared header language, and a pill switcher for its
// three tabs. What the tabs contain is unchanged; this covers the shell.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/seller_dashboard_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/chat_ambient_background.dart';
import 'package:broka/widgets/collapsing_screen_header.dart';
import 'package:broka/widgets/constellation_background.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(() async {
    installFakeApi();
    // The overflow check below needs real glyph widths: the test font draws
    // every character a full em wide, roughly twice Roboto's, and reports
    // overflows no phone would show. Flutter's SDK ships Roboto.
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts';
    if (Directory(fonts).existsSync()) {
      final roboto = FontLoader('Roboto');
      for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
        roboto.addFont(Future.value(ByteData.view(File('$fonts/$f').readAsBytesSync().buffer)));
      }
      await roboto.load();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'seller-1';
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/auth/user/seller-1') {
        return {'id': 'seller-1', 'name': 'Grace Akinyi', 'rating': 4.7, 'completed_deals': 3, 'trust_score': 86};
      }
      if (p == '/stores/mine') return _store;
      if (p == '/stores/st1/stats') return _stats;
      if (p.endsWith('/revenue')) return {'total': 0, 'deals': 0, 'series': []};
      if (p.endsWith('/metrics')) return {'history': [], 'advice': []};
      return null;
    });
  });

  testWidgets("on Home's visual system, with its tabs as a pill switcher", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SellerDashboardScreen(animateBackground: false)));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(find.byType(ChatAmbientBackground), findsNothing);
    expect(find.text('SELLER DASHBOARD'), findsOneWidget);
    expect(find.byType(BrokaHeaderButton), findsNWidgets(2)); // My Store, refresh
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('LIVE'), findsNothing);

    await tester.tap(find.byKey(const Key('dashboard-tab-2')));
    await _settle(tester);
    expect(find.text('DEAL SUMMARY'), findsOneWidget);
    final deals = tester.widget<Text>(find.text('Deals'));
    expect(deals.style!.color, Colors.white, reason: 'the selected tab is lit');
  });

  testWidgets('shows the online store, and opens My Store from it and from the header',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: const SellerDashboardScreen(animateBackground: false),
      onGenerateRoute: (settings) {
        opened.add(settings.name!);
        return MaterialPageRoute(builder: (_) => Text('route ${settings.name}'));
      },
    ));
    await _settle(tester);

    expect(find.text('YOUR ONLINE STORE'), findsOneWidget);
    expect(find.text("Grace's Phones"), findsOneWidget);
    expect(find.text('broka.co.ke/store/graces-phones'), findsOneWidget);
    expect(find.text('11'), findsOneWidget); // visits this week

    await tester.ensureVisible(find.text('Manage store'));
    await _settle(tester);
    await tester.tap(find.text('Manage store'));
    await _settle(tester);
    expect(opened, ['/store-manage']);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await _settle(tester);
    await tester.tap(find.byKey(const Key('dashboard-my-store')));
    await _settle(tester);
    expect(opened, ['/store-manage', '/store-manage']);
  });

  testWidgets('without a store, the header opens the introduction to one', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/auth/user/seller-1') {
        return {'id': 'seller-1', 'name': 'Grace Akinyi', 'account_type': 'buyer_seller',
            'seller_tier': 'long_term'};
      }
      if (uri.path == '/stores/mine') return const FakeResponse(null);
      return null;
    });
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: const SellerDashboardScreen(animateBackground: false),
      onGenerateRoute: (settings) {
        opened.add(settings.name!);
        return MaterialPageRoute(builder: (_) => Text('route ${settings.name}'));
      },
    ));
    await _settle(tester);
    expect(find.text('Open your online store'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dashboard-my-store')));
    await _settle(tester);
    expect(opened, ['/store-explainer']);
  });

  testWidgets('shows how long deals take, and a dash before the first one', (tester) async {
    Map<String, dynamic>? timed;
    setFakeRoute((uri) {
      if (uri.path == '/auth/user/seller-1') {
        return {'id': 'seller-1', 'name': 'Grace Akinyi', 'completed_deals': 3, ...?timed};
      }
      // The fake's default listings are not this screen's Listing shape.
      if (uri.path == '/listings/') return <Object?>[];
      if (uri.path == '/stores/mine') return const FakeResponse(null);
      return null;
    });
    Future<void> openDashboard() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const MaterialApp(home: SellerDashboardScreen(animateBackground: false)));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 2)); // the count-up
    }

    await openDashboard();
    expect(find.text('Deals Done'), findsOneWidget);
    Text beside(String label) => tester.widget<Text>(find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
        matching: find.byType(Text)).first);
    expect(beside('Deals Done').data, '3');
    // No completed deal timed: a dash, not a 0 that reads as instant.
    expect(beside('Avg Deal Time').data, '—');

    timed = {'avg_deal_time_minutes': 2160.0, 'timed_deals': 3};
    await openDashboard();
    expect(beside('Avg Deal Time').data, '1.5d');
  });

  group('deleting a product', () {
    Map<String, dynamic> listing(String id, String name) => {
          'id': id, 'name': name, 'category': 'Electronics', 'price': 32000,
          'listing_type': 'direct', 'status': 'active', 'seller_id': 'seller-1', 'views': 4,
        };

    Future<void> openProducts(WidgetTester tester, {Object? onDelete}) async {
      setFakeRoute((uri) {
        if (uri.path == '/auth/user/seller-1') return {'id': 'seller-1', 'name': 'Grace Akinyi'};
        if (uri.path == '/listings/') {
          return [listing('listing-7', 'Samsung A54'), listing('listing-8', 'JBL Flip 6')];
        }
        if (uri.path == '/listings/listing-7') return onDelete;
        if (uri.path == '/stores/mine') return const FakeResponse(null);
        return null;
      });
      clearFakeRequests();
      await tester.pumpWidget(const MaterialApp(home: SellerDashboardScreen(animateBackground: false)));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('dashboard-tab-1')));
      await _settle(tester);
      expect(find.text('Samsung A54'), findsOneWidget);
    }

    testWidgets('asks first, then takes it off the dashboard', (tester) async {
      await openProducts(tester, onDelete: {'deleted': true, 'listing_id': 'listing-7'});

      await tester.tap(find.byKey(const Key('delete-listing-listing-7')));
      await _settle(tester);
      expect(find.text('Delete this listing?'), findsOneWidget);
      // Keep it: nothing is sent.
      await tester.tap(find.text('Keep it'));
      await _settle(tester);
      expect(fakeRequests.where((r) => r.method == 'DELETE'), isEmpty);

      await tester.tap(find.byKey(const Key('delete-listing-listing-7')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('confirm-delete-listing')));
      await _settle(tester);
      final sent = fakeRequests.singleWhere((r) => r.method == 'DELETE');
      expect(sent.uri.path, '/listings/listing-7');
      expect(find.text('Samsung A54'), findsNothing);
      expect(find.text('JBL Flip 6'), findsOneWidget);
      expect(find.text('"Samsung A54" deleted'), findsOneWidget);
    });

    testWidgets("says why when the backend won't", (tester) async {
      const why = 'A buyer has a deal in progress on this listing. '
          'You can delete it once that deal is finished.';
      await openProducts(tester, onDelete: const FakeResponse({'detail': why}, statusCode: 409));
      await tester.tap(find.byKey(const Key('delete-listing-listing-7')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('confirm-delete-listing')));
      await _settle(tester);
      expect(find.text(why), findsOneWidget);
      expect(find.text('Samsung A54'), findsOneWidget);
    });
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const MaterialApp(home: SellerDashboardScreen(animateBackground: false)));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(Key('dashboard-tab-$i')));
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: 'tab $i');
    }
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _store = {
  'id': 'st1',
  'name': "Grace's Phones",
  'slug': 'graces-phones',
  'url': 'https://broka.co.ke/store/graces-phones',
  'category': 'Electronics',
  'is_active': true,
  'listing_count': 4,
  'photos': [],
  'photo_images': [],
};

const _stats = {
  'days': 7,
  'visits': {'total': 11, 'by_day': [], 'by_source': {}, 'by_surface': {}},
  'shares': {'total': 2, 'by_channel': {}},
};
