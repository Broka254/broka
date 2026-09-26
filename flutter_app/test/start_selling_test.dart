// A buyer who starts selling later is asked what signup asks (2026-09-26):
// a few items - nothing more to fill in - or a business, which goes on to
// the business details. This replaced the one-form "Become a Seller" screen,
// which demanded a business from everyone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/stores/presentation/setup/store_setup_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/screens/start_selling_screen.dart';
import 'package:broka/widgets/constellation_background.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserAccountType = 'buyer';
    clearFakeRequests();
    setFakeRoute((uri) {
      if (uri.path == '/auth/upgrade-to-seller') {
        return {'id': 'user-1', 'account_type': 'buyer_seller'};
      }
      return null;
    });
  });

  Widget app() => MaterialApp(
        home: const StartSellingScreen(animateBackground: false),
        routes: {
          '/seller-dashboard': (_) => const Scaffold(body: Text('THE DASHBOARD')),
        },
      );

  Map upgradeRequest() =>
      fakeRequests.lastWhere((r) => r.uri.path == '/auth/upgrade-to-seller').json as Map;

  Future<void> tapContinue(WidgetTester tester) async {
    await tester.tap(find.text('Continue'));
    await _settle(tester);
  }

  testWidgets("asks signup's question first, on Home's background", (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);

    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(find.text('What kind of seller?'), findsOneWidget);
    expect(find.text('Just a few items'), findsOneWidget);
    expect(find.text("I'm running a business"), findsOneWidget);
    // Nothing of the old form: no business fields up front.
    expect(find.text('Business name'), findsNothing);
    expect(find.text('Become a Seller'), findsNothing);
  });

  testWidgets('a few items: no business details, straight to the dashboard',
      (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);

    // The only step, so it finishes here.
    await tester.tap(find.text('Start selling').last);
    await _settle(tester);

    expect(upgradeRequest(), {'seller_tier': 'short_term'});
    expect(ApiService.currentUserAccountType, 'buyer_seller');
    expect(find.text('THE DASHBOARD'), findsOneWidget);
  });

  testWidgets('a business goes on to its details, checked like at signup',
      (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);

    await tester.tap(find.byKey(const Key('seller-tier-long_term')));
    await _settle(tester);
    await tapContinue(tester);
    expect(find.text('Business Name'), findsOneWidget);

    await tapContinue(tester);
    expect(find.text('Please enter your business name'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Clanix');
    await tapContinue(tester);

    expect(find.text('What You Sell'), findsOneWidget);
    await tapContinue(tester); // Electronics

    expect(find.text('Location'), findsOneWidget);
    await tapContinue(tester);
    expect(find.text('Please enter your immediate location'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Sira');
    await tapContinue(tester);

    expect(find.text('About the Business'), findsOneWidget);
    await tester.tap(find.text('Skip — add it later'));
    await _settle(tester);

    expect(find.text('Your business will appear as'), findsOneWidget);
    expect(find.text('Clanix · Electronics · Sira'), findsOneWidget);
    await tester.tap(find.text('Start selling').last);
    await _settle(tester);

    expect(upgradeRequest(), {
      'seller_tier': 'long_term',
      'business_name': 'Clanix',
      'business_category': 'Electronics',
      'business_location': 'Sira',
    });
    expect(find.text('THE DASHBOARD'), findsOneWidget);
  });

  testWidgets('Back returns through the steps, and a business can change its mind',
      (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.byKey(const Key('seller-tier-long_term')));
    await _settle(tester);
    await tapContinue(tester);
    expect(find.text('Business Name'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('seller-tier-short_term')));
    await _settle(tester);
    // Back to a single step: nothing more to ask.
    expect(find.text('Continue'), findsNothing);
    expect(find.text('Start selling'), findsWidgets);
  });

  testWidgets('a refusal from the server is shown, and nothing is lost',
      (tester) async {
    setFakeRoute((uri) => uri.path == '/auth/upgrade-to-seller'
        ? const FakeResponse({'detail': 'A business needs a name, what it sells and a location'},
            statusCode: 422)
        : null);
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.text('Start selling').last);
    await _settle(tester);

    expect(find.text('A business needs a name, what it sells and a location'), findsOneWidget);
    expect(find.text('What kind of seller?'), findsOneWidget);
    expect(ApiService.currentUserAccountType, 'buyer');
  });

  testWidgets('a buyer opening the Seller Dashboard is asked to set up first',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      routes: {'/seller-dashboard': (_) => sellerDashboardOrSetup()},
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.pushNamed(context, '/seller-dashboard'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(find.byType(StartSellingScreen), findsOneWidget);
    expect(find.text('What kind of seller?'), findsOneWidget);
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size',
      (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(app());
    await _settle(tester);
    expect(tester.takeException(), isNull);
    // Below the fold on a phone this small: scrolled to, as a person would.
    await tester.ensureVisible(find.byKey(const Key('seller-tier-long_term')));
    await tester.tap(find.byKey(const Key('seller-tier-long_term')));
    await _settle(tester);
    await tapContinue(tester);
    expect(tester.takeException(), isNull);
  });

  group('on the way to an online store', () {
    testWidgets('a buyer sets the business up first, then the store setup carries on',
        (tester) async {
      var upgraded = false;
      setFakeRoute((uri) {
        switch (uri.path) {
          case '/auth/me':
            return upgraded
                ? {'id': 'u1', 'name': 'Grace', 'account_type': 'buyer_seller',
                    'seller_tier': 'long_term', 'business_name': 'Clanix',
                    'business_category': 'Electronics', 'business_location': 'Sira'}
                : {'id': 'u1', 'name': 'Grace', 'account_type': 'buyer'};
          case '/auth/upgrade-to-seller':
            upgraded = true;
            return {'id': 'u1', 'account_type': 'buyer_seller', 'seller_tier': 'long_term'};
          case '/stores/mine':
            return const FakeResponse(null);
          case '/stores/name-available':
            return {'name': uri.queryParameters['name'], 'available': true,
                'url': 'https://broka.co.ke/store/${uri.queryParameters['name']}'};
        }
        return null;
      });
      await tester.pumpWidget(const MaterialApp(
          home: StoreSetupScreen(animateBackground: false)));
      await _settle(tester);

      // No store steps for an account that isn't a business.
      expect(find.text('Online stores are for businesses'), findsOneWidget);
      expect(find.text('Name your store'), findsNothing);

      await tester.tap(find.text('Set up my business'));
      await _settle(tester);
      // A store needs a business, so that question is already answered.
      expect(find.text('What kind of seller?'), findsNothing);
      expect(find.text('Business Name'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Clanix');
      await tapContinue(tester);
      await tapContinue(tester); // Electronics
      await tester.enterText(find.byType(TextField), 'Sira');
      await tapContinue(tester);
      await tester.tap(find.text('Skip — add it later'));
      await _settle(tester);
      expect(find.text('Clanix · Electronics · Sira'), findsOneWidget);
      await tester.tap(find.text('On to my store'));
      await _settle(tester);
      await _settle(tester);

      expect(upgradeRequest(), {
        'seller_tier': 'long_term',
        'business_name': 'Clanix',
        'business_category': 'Electronics',
        'business_location': 'Sira',
      });
      // Back in the store setup, starting from the business just set up.
      expect(find.text('Name your store'), findsOneWidget);
      expect(find.text('Clanix'), findsWidgets);
      expect(find.text('THE DASHBOARD'), findsNothing);
    });

    testWidgets('a business seller goes straight to the store steps', (tester) async {
      setFakeRoute((uri) => switch (uri.path) {
            '/auth/me' => {'id': 'u1', 'account_type': 'buyer_seller',
                'seller_tier': 'long_term', 'business_name': 'Clanix',
                'business_category': 'Electronics', 'business_location': 'Sira'},
            '/stores/mine' => const FakeResponse(null),
            '/stores/name-available' => {'name': uri.queryParameters['name'],
                'available': true},
            _ => null,
          });
      await tester.pumpWidget(const MaterialApp(
          home: StoreSetupScreen(animateBackground: false)));
      await _settle(tester);
      expect(find.text('Online stores are for businesses'), findsNothing);
      expect(find.text('Name your store'), findsOneWidget);
    });
  });
}

/// pumpAndSettle never returns (the constellation animates forever).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
