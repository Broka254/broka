// The Menu tab (formerly Profile), and the Profile and Settings screens it
// opens.
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/menu_screen.dart';
import 'package:broka/screens/profile_screen.dart';
import 'package:broka/screens/settings_screen.dart';
import 'package:broka/widgets/constellation_background.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _me({
  String accountType = 'buyer_seller',
  int deals = 3,
  bool locationVisible = true,
  String? photo,
}) =>
    {
      'id': 'user-1',
      'name': 'Grace Akinyi',
      'nickname': 'Grace',
      'email': 'grace@test.ke',
      'email_verified': true,
      'phone': '+254700000001',
      'account_type': accountType,
      'seller_tier': 'long_term',
      'is_verified': true,
      'rating': 4.7,
      'completed_deals': deals,
      'location_visible': locationVisible,
      'profile_photo': photo,
      'created_at': '2026-03-02T10:00:00',
    };

const _store = {
  'id': 'store-1',
  'name': 'Clanix Electronics',
  'slug': 'clanix',
  'url': 'https://broka.co.ke/store/clanix',
  'is_active': true,
  'listing_count': 12,
};

const _stats = {
  'days': 7,
  'visits': {'total': 34, 'by_day': [], 'by_source': {}, 'by_surface': {}},
  'shares': {'total': 5, 'by_channel': {}},
};

/// The account endpoints every screen here reads, plus whatever [extra]
/// answers first.
FakeRoute _account({
  Map<String, dynamic>? me,
  Object? myStore,
  FakeRoute? extra,
}) =>
    (uri) {
      final routed = extra?.call(uri);
      if (routed != null) return routed;
      final path = uri.path;
      if (path == '/auth/me') return me ?? _me();
      if (path.startsWith('/listings') && uri.queryParameters['seller_id'] != null) {
        return {'items': <Object?>[], 'total': 7};
      }
      // JSON null - "no store" - has to be wrapped: a bare null falls
      // through to the default route.
      if (path == '/stores/mine') return FakeResponse(myStore);
      if (path.endsWith('/stats')) return _stats;
      return null;
    };

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    setFakeRoute(null);
    SharedPreferences.setMockInitialValues({});
  });

  Widget app(Widget home) => MaterialApp(
        home: home,
        routes: {
          '/profile': (_) => const ProfileScreen(animateBackground: false),
          '/settings': (_) => const SettingsScreen(animateBackground: false),
        },
      );

  group('Menu', () {
    testWidgets('profile card, selling, store and account - on the constellation',
        (tester) async {
      setFakeRoute(_account());
      await tester.pumpWidget(app(const MenuScreen(animateBackground: false)));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.text('MENU'), findsOneWidget);
      // Profile card: preferred name, contact, real numbers.
      expect(find.text('Grace'), findsOneWidget);
      expect(find.text('+254700000001'), findsOneWidget);
      expect(find.text('7'), findsOneWidget); // active listings, from the total
      expect(find.text('4.7'), findsOneWidget);
      // Sections.
      expect(find.text('SELLING'), findsOneWidget);
      expect(find.text('Seller Dashboard'), findsOneWidget);
      expect(find.text('ONLINE STORE'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Settings'), 200);
      expect(find.text('Settings'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Sign out'), 200);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('a buyer is offered selling, and a store all the same',
        (tester) async {
      setFakeRoute(_account(me: _me(accountType: 'buyer', deals: 0)));
      await tester.pumpWidget(app(const MenuScreen(animateBackground: false)));
      await _settle(tester);

      expect(find.text('Become a seller'), findsOneWidget);
      expect(find.text('Seller Dashboard'), findsNothing);
      // No finished deal, no rating - the column's default is not a score.
      expect(find.text('New'), findsOneWidget);
      // The store wizard takes buyers (it collects business details first);
      // Profile used to hide this from them.
      expect(find.text('Open your online store'), findsOneWidget);
      expect(find.text('Open a store'), findsOneWidget);
    });

    testWidgets('with a store: its link, status, products and last week',
        (tester) async {
      setFakeRoute(_account(myStore: _store));
      await tester.pumpWidget(app(const MenuScreen(animateBackground: false)));
      await _settle(tester);

      expect(find.text('Clanix Electronics'), findsOneWidget);
      expect(find.text('broka.co.ke/store/clanix'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('34'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('Manage store'), findsOneWidget);
      expect(find.byTooltip('Share store link'), findsOneWidget);
    });

    testWidgets('a store that fails to load says so and can be retried',
        (tester) async {
      setFakeRoute(_account(
          extra: (uri) => uri.path == '/stores/mine' ? const FakeResponse.error() : null));
      await tester.pumpWidget(app(const MenuScreen(animateBackground: false)));
      await _settle(tester);
      expect(find.text("Couldn't load your store"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('the profile card opens Profile', (tester) async {
      setFakeRoute(_account());
      await tester.pumpWidget(app(const MenuScreen(animateBackground: false)));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('menu-profile-card')));
      await _settle(tester);
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.text('ACCOUNT DETAILS'), findsOneWidget);
    });
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size',
      (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    for (final (name, screen, store) in [
      ('menu, no store', const MenuScreen(animateBackground: false), null),
      ('menu, store', const MenuScreen(animateBackground: false), _store),
      ('profile', const ProfileScreen(animateBackground: false), null),
      ('settings', const SettingsScreen(animateBackground: false), null),
    ]) {
      setFakeRoute(_account(myStore: store));
      await tester.pumpWidget(app(screen));
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: name);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: '$name, scrolled');
    }
  });

  group('Profile', () {
    testWidgets('shows real numbers, on the constellation', (tester) async {
      setFakeRoute(_account(me: _me(deals: 0)));
      await tester.pumpWidget(app(const ProfileScreen(animateBackground: false)));
      await _settle(tester);

      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.text('7'), findsOneWidget); // active listings
      expect(find.text('New'), findsOneWidget); // no deals, no rating
      // "Traded" read a field /auth/me has never sent: always KES 0.
      expect(find.text('Traded'), findsNothing);
      expect(find.text('grace@test.ke'), findsOneWidget);
      expect(find.text('Mar 2026'), findsOneWidget);
    });

    testWidgets('a photo stored as a BROKA image URL renders', (tester) async {
      setFakeRoute(_account(me: _me(photo: 'https://media.broka.co.ke/avatars/a.webp')));
      await tester.pumpWidget(app(const ProfileScreen()));
      await _settle(tester);
      // Image.memory(base64Decode(url)) threw here.
      expect(tester.takeException(), isNull);
      expect(find.byType(CachedNetworkImage), findsOneWidget);
    });
  });

  group('Settings', () {
    testWidgets('location starts from the account, not from "on"', (tester) async {
      setFakeRoute(_account(me: _me(locationVisible: false)));
      await tester.pumpWidget(app(const SettingsScreen(animateBackground: false)));
      await _settle(tester);
      final toggle = tester.widget<Switch>(find.byKey(const Key('settings-location-switch')));
      expect(toggle.value, isFalse);
      // The two switches that did nothing are gone.
      expect(find.text('Dark mode'), findsNothing);
      expect(find.text('Push notifications'), findsNothing);
    });

    testWidgets('a change the server refuses is undone and explained',
        (tester) async {
      setFakeRoute(_account(
          me: _me(locationVisible: false),
          extra: (uri) =>
              uri.path == '/auth/location-visibility' ? const FakeResponse.error() : null));
      await tester.pumpWidget(app(const SettingsScreen(animateBackground: false)));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('settings-location-switch')));
      await _settle(tester);
      final toggle = tester.widget<Switch>(find.byKey(const Key('settings-location-switch')));
      expect(toggle.value, isFalse);
      expect(find.textContaining("Couldn't change your location setting"), findsOneWidget);
    });

    testWidgets('sign-out-everywhere that fails leaves you signed in and says so',
        (tester) async {
      setFakeRoute(_account(
          extra: (uri) =>
              uri.path == '/auth/token/revoke-all' ? const FakeResponse.error() : null));
      await tester.pumpWidget(app(const SettingsScreen(animateBackground: false)));
      await _settle(tester);

      await tester.scrollUntilVisible(find.text('Sign out of all devices'), 200);
      await tester.tap(find.text('Sign out of all devices'));
      await _settle(tester);
      await tester.tap(find.text('Sign out everywhere'));
      await _settle(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.textContaining('nothing was signed out'), findsOneWidget);
    });
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
