// The listing screen on Home's visual system (2026-09-29): the constellation
// and Home's header, the deal's terms where a buyer looks first, the seller
// dashboard's rating / completion rate / response time for the seller, and
// the Zeno Insight card opening Zeno about this listing.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/main.dart' show BrokaColors, ZoneGlowText;
import 'package:broka/models/listing.dart';
import 'package:broka/screens/product_screen.dart';
import 'package:broka/screens/zeno_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/constellation_background.dart';

import 'support/fake_api.dart';

Listing _listing({
  String sellerId = 'seller-1',
  bool negotiable = true,
  bool? delivers = true,
  String? deliveryNote = 'Within Nairobi CBD for KES 300',
}) => Listing(
      id: 'listing-1',
      name: 'iPhone 13 128GB',
      category: 'Electronics',
      price: 78000,
      description: 'Battery health 89%. Comes with the box, no charger.',
      priceNegotiable: negotiable,
      deliveryAvailable: delivers,
      deliveryNote: deliveryNote,
      locationName: 'Westlands, Nairobi',
      listingType: 'direct',
      status: 'active',
      views: 42,
      sellerId: sellerId,
      sellerName: 'Grace Akinyi',
      sellerCompletedDeals: 14,
    );

const _standing = {
  'overall_rating': 8.5,
  'dcr': 92.3,
  'dcr_provisional': false,
  'median_response_minutes': 25.0,
  'completed_deals': 14,
  'as_of': '2026-09-28',
};

void main() {
  setUpAll(() async {
    installFakeApi();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Zeno's screen, opened from the card, owns a player.
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    // Real glyph widths for the overflow check: the test font draws every
    // character a full em wide and reports overflows no phone would show.
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts';
    if (Directory(fonts).existsSync()) {
      final roboto = FontLoader('Roboto');
      for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
        roboto.addFont(Future.value(ByteData.view(File('$fonts/$f').readAsBytesSync().buffer)));
      }
      await roboto.load();
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'auth_token': 'tok', 'user_id': 'buyer-1', 'user_name': 'Amina'});
    await ApiService.loadSavedSession();
    clearFakeRequests();
    setFakeRoute((uri) {
      if (uri.path == '/auth/user/seller-1') {
        return {'id': 'seller-1', 'name': 'Grace Akinyi', 'is_verified': true,
            'completed_deals': 14, 'seller_standing': _standing};
      }
      if (uri.path == '/zeno/assistant/turn') return {'reply': 'It comes with the box.', 'action': null};
      return null;
    });
  });

  tearDown(() => setFakeRoute(null));

  /// The listing screen as the app opens it: a named route with the listing
  /// as its argument. Anywhere else it leads shows the route's name.
  Future<List<String>> open(WidgetTester tester, Listing listing) async {
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (s) {
        if (s.name == '/') {
          return MaterialPageRoute(
            settings: RouteSettings(name: '/product', arguments: listing),
            builder: (_) => const ProductScreen(animateBackground: false),
          );
        }
        opened.add(s.name!);
        return MaterialPageRoute(builder: (_) => Scaffold(body: Text('route ${s.name}')));
      },
    ));
    await tester.pumpAndSettle();
    return opened;
  }

  Future<void> pumpFor(WidgetTester tester, Duration total) async {
    for (var t = Duration.zero; t < total; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  String textIn(WidgetTester tester, Key key) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(key), matching: find.byType(Text)))
      .map((t) => t.data ?? t.textSpan!.toPlainText())
      .join(' | ');

  Color valueColour(WidgetTester tester, Key key) {
    final rich = tester.widget<Text>(find.descendant(of: find.byKey(key), matching: find.byType(Text)).at(1));
    return (rich.textSpan! as TextSpan).children!.first.style!.color!;
  }

  testWidgets("on Home's visual system", (tester) async {
    await open(tester, _listing());
    expect(tester.takeException(), isNull);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(find.byType(SliverAppBar), findsNothing);
    // The category's glowing name in the header, as in its Zone.
    expect(find.widgetWithText(ZoneGlowText, 'ELECTRONICS'), findsOneWidget);
    expect(find.text('DIRECT SALE'), findsOneWidget);
  });

  group('deal terms', () {
    testWidgets('a negotiable listing the seller delivers', (tester) async {
      await open(tester, _listing());
      expect(find.text('DEAL TERMS'), findsOneWidget);
      expect(textIn(tester, const Key('deal-term-price')), contains('Negotiable'));
      expect(textIn(tester, const Key('deal-term-delivery')),
          allOf(contains('Seller delivers'), contains('Within Nairobi CBD for KES 300')));
      expect(find.text('Start Negotiation'), findsOneWidget);
    });

    testWidgets('a fixed price, collected from the seller', (tester) async {
      await open(tester, _listing(negotiable: false, delivers: false));
      expect(textIn(tester, const Key('deal-term-price')), contains('Fixed price'));
      expect(textIn(tester, const Key('deal-term-delivery')), contains('Pickup only'));
      // A fixed price is agreed with the seller, not negotiated.
      expect(find.text('Contact Seller'), findsOneWidget);
      expect(find.text('Start Negotiation'), findsNothing);
    });

    testWidgets('delivery the seller never mentioned is said to be unknown', (tester) async {
      await open(tester, _listing(delivers: null, deliveryNote: null));
      expect(textIn(tester, const Key('deal-term-delivery')),
          allOf(contains('Delivery not stated'), contains('Ask the seller before you pay')));
    });
  });

  group("the seller's standing", () {
    testWidgets("shows the dashboard's rating, completion rate and reply time", (tester) async {
      await open(tester, _listing());
      expect(textIn(tester, const Key('standing-rating')), contains('8.5/10'));
      expect(textIn(tester, const Key('standing-dcr')), allOf(contains('92%'), contains('of deals completed')));
      expect(textIn(tester, const Key('standing-response')), allOf(contains('25m'), contains('typical reply')));
      // In the dashboard's colours: all three are in its green band.
      for (final k in ['standing-rating', 'standing-dcr', 'standing-response']) {
        expect(valueColour(tester, Key(k)), BrokaColors.neonGreen, reason: k);
      }
      // The made-up "credibility" score is gone.
      expect(find.textContaining('credibility'), findsNothing);
    });

    testWidgets('a slow, thin record is shown as it is', (tester) async {
      setFakeRoute((uri) => uri.path == '/auth/user/seller-1'
          ? {'id': 'seller-1', 'name': 'Grace', 'seller_standing': {
              'overall_rating': 5.2, 'dcr': 75.0, 'dcr_provisional': true,
              'median_response_minutes': 300.0, 'completed_deals': 3}}
          : null);
      await open(tester, _listing());
      expect(textIn(tester, const Key('standing-dcr')), contains('Early - few deals'));
      expect(textIn(tester, const Key('standing-response')), contains('5.0h'));
      expect(valueColour(tester, const Key('standing-rating')), BrokaColors.danger);
      expect(valueColour(tester, const Key('standing-dcr')), BrokaColors.warning);
      expect(valueColour(tester, const Key('standing-response')), BrokaColors.danger);
    });

    testWidgets('a seller with no figures yet is not given any', (tester) async {
      setFakeRoute((uri) => uri.path == '/auth/user/seller-1' ? {'id': 'seller-1', 'name': 'Grace'} : null);
      await open(tester, _listing());
      expect(textIn(tester, const Key('standing-rating')), contains('Not rated yet'));
      expect(textIn(tester, const Key('standing-dcr')), contains('No deals yet'));
      expect(textIn(tester, const Key('standing-response')), contains('Not measured yet'));
      expect(find.text('10.0/10'), findsNothing);
    });
  });

  group('Zeno insight', () {
    testWidgets('opens Zeno about this listing, which asks with its id', (tester) async {
      await open(tester, _listing());
      await tester.ensureVisible(find.byKey(const Key('ask-zeno')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ask-zeno')));
      // Not pumpAndSettle: Zeno's avatar breathes for as long as it is open.
      await pumpFor(tester, const Duration(seconds: 2));

      final zeno = tester.widget<ZenoScreen>(find.byType(ZenoScreen));
      expect(zeno.mode, ZenoMode.assistant);
      expect(zeno.aboutListing!.id, 'listing-1');
      expect(zeno.aboutListing!.negotiable, isTrue);
      expect(find.byKey(const Key('zeno-about-listing')), findsOneWidget);
      expect(find.textContaining('Ask me anything about "iPhone 13 128GB"'), findsOneWidget);
      // Nothing is asked until the buyer asks.
      expect(fakeRequests.where((r) => r.uri.path == '/zeno/assistant/turn'), isEmpty);
    });

    testWidgets('a question on the card is asked as Zeno opens', (tester) async {
      await open(tester, _listing());
      await tester.ensureVisible(find.text('Is this seller reliable?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Is this seller reliable?'));
      await pumpFor(tester, const Duration(seconds: 2));
      final turn = fakeRequests.singleWhere((r) => r.uri.path == '/zeno/assistant/turn').json as Map;
      expect(turn['message'], 'Is this seller reliable?');
      expect(turn['listing_id'], 'listing-1');
    });

    testWidgets('a guest is asked to sign in first', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await ApiService.loadSavedSession();
      await open(tester, _listing());
      await tester.ensureVisible(find.byKey(const Key('ask-zeno')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ask-zeno')));
      await tester.pumpAndSettle();
      expect(find.byType(ZenoScreen), findsNothing);
      expect(find.textContaining('ask Zeno about this listing'), findsOneWidget);
    });
  });

  testWidgets("the seller's own listing has no buy button", (tester) async {
    ApiService.currentUserId = 'seller-1';
    await open(tester, _listing());
    expect(find.byKey(const Key('product-cta')), findsNothing);
    expect(find.text('Ask Zeno about your listing'), findsOneWidget);
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(tester, _listing(negotiable: false, delivers: null, deliveryNote: null));
    expect(tester.takeException(), isNull);
    // Scroll through every section so each one is laid out.
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'after scroll $i');
    }
  });
}
