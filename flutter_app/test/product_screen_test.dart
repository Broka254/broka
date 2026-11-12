// The listing screen on Home's visual system (2026-09-29): the constellation
// and Home's header, the deal's terms where a buyer looks first, the seller
// dashboard's rating / completion rate / response time for the seller - and
// since 2026-09-30 how long their deals take - and the Zeno Insight card
// opening Zeno about this listing.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/core/network/data_saver.dart';
import 'package:broka/features/stores/presentation/storefront_launcher.dart';
import 'package:broka/main.dart' show BrokaColors, ZoneGlowText;
import 'package:broka/models/listing.dart';
import 'package:broka/models/listing_photo.dart';
import 'package:broka/screens/product_screen.dart';
import 'package:broka/screens/zeno_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/constellation_background.dart';

import 'support/fake_api.dart';
import 'support/fake_network_image.dart';

Listing _listing({
  String sellerId = 'seller-1',
  bool negotiable = true,
  bool? delivers = true,
  String? deliveryNote = 'Within Nairobi CBD for KES 300',
  String status = 'active',
  bool soldOut = false,
  int? quantity,
  int? unitsLeft,
  String? priceUnit,
  String? storeId,
  String listingType = 'direct',
  String sellerName = 'Grace Akinyi',
  List<ListingPhoto> photos = const [],
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
      listingType: listingType,
      status: status,
      soldOut: soldOut,
      quantity: quantity,
      unitsLeft: unitsLeft,
      priceUnit: priceUnit,
      views: 42,
      sellerId: sellerId,
      sellerName: sellerName,
      photos: photos,
      sellerCompletedDeals: 14,
      storeId: storeId,
      storeName: storeId == null ? null : 'Clanix Electronics',
      storeSlug: storeId == null ? null : 'clanix',
    );

// A 1x1 JPEG selfie, as signup sends it: bare base64 starting "/9j/".
const _selfie =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdA'
    'SFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2Nj'
    'Y2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAABAAEDASIAAhEBAxEB/8QA'
    'HwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIh'
    'MUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW'
    'V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXG'
    'x8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQF'
    'BgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAV'
    'YnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE'
    'hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq'
    '8vP09fb3+Pn6/9oADAMBAAIRAxEAPwBtFFFfQGp//9k=';

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
            'completed_deals': 14, 'seller_standing': _standing,
            'avg_deal_time_minutes': 150.0, 'timed_deals': 12,
            'last_seen': '2026-09-30T13:05:00', 'is_online': false,
            'last_seen_label': 'Active 12m ago'};
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

  // A like and a save are two things (2026-10-09): the heart only saved,
  // and nothing counted a like.
  group('likes and saves', () {
    List<FakeRequest> sent(String method, String path) => fakeRequests
        .where((r) => r.method == method && r.uri.path == path).toList();

    testWidgets('a buyer likes it with the heart and saves it with the bookmark', (tester) async {
      setFakeRoute((uri) => switch (uri.path) {
            '/listings/listing-1/engagement' => {'liked': false, 'saved': false},
            '/listings/listing-1/like' => {'liked': true},
            '/listings/listing-1/save' => {'saved': true},
            _ => null,
          });
      await open(tester, _listing());
      expect(find.byTooltip('Like'), findsOneWidget);
      expect(find.byTooltip('Save'), findsOneWidget);

      await tester.tap(find.byKey(const Key('product-like')));
      await tester.pumpAndSettle();
      expect(sent('POST', '/listings/listing-1/like'), hasLength(1));
      expect(find.byTooltip('Unlike'), findsOneWidget);
      // A like keeps nothing in Saved items.
      expect(sent('POST', '/listings/listing-1/save'), isEmpty);

      await tester.tap(find.byKey(const Key('product-save')));
      await tester.pumpAndSettle();
      expect(sent('POST', '/listings/listing-1/save'), hasLength(1));
      expect(find.byTooltip('Remove from saved'), findsOneWidget);
      expect(find.textContaining('Saved items'), findsOneWidget);
    });

    testWidgets('what the buyer already did shows when it opens', (tester) async {
      setFakeRoute((uri) => uri.path == '/listings/listing-1/engagement'
          ? {'liked': true, 'saved': true} : null);
      await open(tester, _listing());
      expect(find.byTooltip('Unlike'), findsOneWidget);
      expect(find.byTooltip('Remove from saved'), findsOneWidget);
    });

    testWidgets('its seller sees how many liked and saved it, and no buttons', (tester) async {
      setFakeRoute((uri) => uri.path == '/listings/listing-1/engagement'
          ? {'liked': false, 'saved': false, 'likes': 7, 'saves': 2} : null);
      await open(tester, _listing(sellerId: 'buyer-1'));
      expect(find.byKey(const Key('product-like')), findsNothing);
      expect(find.byKey(const Key('product-save')), findsNothing);
      expect(find.bySemanticsLabel('7 likes, 2 saves'), findsOneWidget);
    });
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
      // What it measures since 2026-11-12: the wait for the seller's first
      // answer to a buyer's first message, not for every reply.
      expect(textIn(tester, const Key('standing-response')),
          allOf(contains('25m'), contains("to a buyer's first message")));
      expect(textIn(tester, const Key('standing-deal-time')),
          allOf(contains('2.5h'), contains('agreed to paid · 12 deals')));
      // In the dashboard's colours: all four are in its green band.
      for (final k in ['standing-rating', 'standing-dcr', 'standing-response', 'standing-deal-time']) {
        expect(valueColour(tester, Key(k)), BrokaColors.neonGreen, reason: k);
      }
      // The made-up "credibility" score is gone.
      expect(find.textContaining('credibility'), findsNothing);
    });

    testWidgets('a slow, thin record is shown as it is', (tester) async {
      setFakeRoute((uri) => uri.path == '/auth/user/seller-1'
          ? {'id': 'seller-1', 'name': 'Grace', 'seller_standing': {
              'overall_rating': 5.2, 'dcr': 75.0, 'dcr_provisional': true,
              'median_response_minutes': 300.0, 'completed_deals': 3},
              'avg_deal_time_minutes': 12000.0, 'timed_deals': 1}
          : null);
      await open(tester, _listing());
      expect(textIn(tester, const Key('standing-dcr')), contains('Early - few deals'));
      expect(textIn(tester, const Key('standing-response')), contains('5.0h'));
      expect(valueColour(tester, const Key('standing-rating')), BrokaColors.danger);
      expect(valueColour(tester, const Key('standing-dcr')), BrokaColors.warning);
      expect(valueColour(tester, const Key('standing-response')), BrokaColors.danger);
      // Over a week from agreement to payout, on one deal.
      expect(textIn(tester, const Key('standing-deal-time')),
          allOf(contains('8.3d'), contains('1 deal')));
      expect(valueColour(tester, const Key('standing-deal-time')), BrokaColors.danger);
    });

    testWidgets('a seller with no figures yet is not given any', (tester) async {
      setFakeRoute((uri) => uri.path == '/auth/user/seller-1' ? {'id': 'seller-1', 'name': 'Grace'} : null);
      await open(tester, _listing());
      expect(textIn(tester, const Key('standing-rating')), contains('Not rated yet'));
      expect(textIn(tester, const Key('standing-dcr')), contains('No deals yet'));
      expect(textIn(tester, const Key('standing-response')), contains('Not measured yet'));
      expect(textIn(tester, const Key('standing-deal-time')), contains('No completed deals'));
      expect(find.text('10.0/10'), findsNothing);
    });

    testWidgets("last seen is the server's reading, not a UTC-shifted guess", (tester) async {
      // last_seen is naive UTC; parsed here as local time, a seller active
      // minutes ago in Kenya read "3h ago".
      await open(tester, _listing());
      expect(find.text('Active 12m ago'), findsOneWidget);
      expect(find.textContaining('3h ago'), findsNothing);
    });
  });

  group('the seller card', () {
    testWidgets("a business is named, and so is the person behind it", (tester) async {
      setFakeRoute((uri) => uri.path == '/auth/user/seller-1'
          ? {'id': 'seller-1', 'name': 'Xavier Bravin Odhaimbo', 'business_name': 'Clanix',
              'account_type': 'buyer_seller', 'profile_photo': _selfie,
              'last_seen_label': 'Active 4h ago'}
          : null);
      await open(tester, _listing(sellerName: 'Clanix'));
      expect(tester.widget<Text>(find.byKey(const Key('seller-card-name'))).data, 'Clanix');
      expect(tester.widget<Text>(find.byKey(const Key('seller-card-official-name'))).data,
          'Xavier Bravin Odhaimbo');
    });

    testWidgets('someone selling as themselves has the one name', (tester) async {
      await open(tester, _listing());
      expect(tester.widget<Text>(find.byKey(const Key('seller-card-name'))).data, 'Grace Akinyi');
      expect(find.byKey(const Key('seller-card-official-name')), findsNothing);
    });

    testWidgets("shows the seller's selfie, not their initial", (tester) async {
      // A JPEG's base64 starts "/9j/", which was taken for a server path:
      // the photo was fetched from the API, failed, and "C" showed instead.
      setFakeRoute((uri) => uri.path == '/auth/user/seller-1'
          ? {'id': 'seller-1', 'name': 'Xavier Bravin Odhaimbo', 'business_name': 'Clanix',
              'profile_photo': _selfie}
          : null);
      await open(tester, _listing(sellerName: 'Clanix'));
      final photos = tester.widgetList<Image>(find.byType(Image))
          .where((i) => i.image is MemoryImage);
      expect(photos, isNotEmpty);
      expect(find.text('C'), findsNothing);
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

  group('when there is nothing left to buy', () {
    // Every list a buyer browses leaves these out; a link, a notification or
    // a chat still opens them.
    testWidgets('a sold-out listing says so instead of offering a deal', (tester) async {
      await open(tester, _listing(status: 'pending', soldOut: true));
      expect(find.byKey(const Key('product-cta')), findsNothing);
      expect(textIn(tester, const Key('product-unavailable')), contains('Sold out'));
    });

    testWidgets('a deleted one says the seller removed it', (tester) async {
      await open(tester, _listing(status: 'cancelled'));
      expect(find.byKey(const Key('product-cta')), findsNothing);
      expect(textIn(tester, const Key('product-unavailable')), contains('Removed by the seller'));
    });

    testWidgets('a listing of several units says how many are left', (tester) async {
      await open(tester, _listing(quantity: 100, unitsLeft: 12, priceUnit: 'bag'));
      expect(textIn(tester, const Key('units-left')), '12 of 100 bags left');
      expect(find.byKey(const Key('product-cta')), findsOneWidget);
    });

    testWidgets('before any are sold, the total', (tester) async {
      await open(tester, _listing(quantity: 100, priceUnit: 'bag'));
      expect(textIn(tester, const Key('units-left')), '100 bags available');
    });

    testWidgets('a single item says it is the only one', (tester) async {
      // Buyers saw no stock at all on a one-off listing.
      await open(tester, _listing());
      expect(textIn(tester, const Key('units-left')), 'Only 1 available');
    });

    testWidgets('a sold-out listing shows no stock line', (tester) async {
      await open(tester, _listing(status: 'pending', soldOut: true, quantity: 10, unitsLeft: 0));
      expect(find.byKey(const Key('units-left')), findsNothing);
    });
  });

  group("a store's product", () {
    testWidgets('offers Visit Store beside the main action, never Add to cart', (tester) async {
      final opened = await open(tester, _listing(storeId: 's1', quantity: 5, unitsLeft: 3));
      expect(find.byKey(const Key('product-cta')), findsOneWidget);
      expect(find.byKey(const Key('product-visit-store')), findsOneWidget);
      expect(find.text('Visit Store'), findsOneWidget);
      expect(find.byKey(const Key('product-add-to-cart')), findsNothing);
      expect(find.text('Add to cart'), findsNothing);

      // The store's home in the app, by its immutable slug - not the web
      // storefront (storefront_launcher.dart, 2026-11-08). The website stays
      // for shared links and a seller previewing their own shop.
      Uri? website;
      storeUrlLauncherOverride = (uri, mode) async {
        website = uri;
        return true;
      };
      addTearDown(() => storeUrlLauncherOverride = null);
      await tester.tap(find.byKey(const Key('product-visit-store')));
      await tester.pumpAndSettle();
      expect(website, isNull);
      expect(opened, contains('/store-view'));
    });

    testWidgets('a personal listing or an auction has no Visit Store', (tester) async {
      await open(tester, _listing());
      expect(find.byKey(const Key('product-visit-store')), findsNothing);
      await open(tester, _listing(storeId: 's1', listingType: 'auction'));
      expect(find.byKey(const Key('product-visit-store')), findsNothing);
    });
  });

  // The gallery asked for each photo's large file and nothing else, so one
  // missing file was an emoji where the photo should be (2026-10-19).
  // It now asks for the medium size first: the large file was two to three
  // times the bytes for a 320dp-tall box (mobile-data pass).
  group('the photo gallery', () {
    const base = 'https://media.test/img/g1';
    final photo = const ListingPhoto(
      id: 'g1',
      thumb: '$base/thumb.webp',
      medium: '$base/medium.webp',
      large: '$base/large.webp',
    );

    tearDown(DataSaver.reset);

    testWidgets('shows the medium size, and never downloads the large file for it', (tester) async {
      final net = FakeImageNetwork(available: {'$base/medium.webp', '$base/large.webp'})..install();
      addTearDown(net.uninstall);

      await open(tester, _listing(photos: [photo]));

      expect(tester.takeException(), isNull);
      expect(net.loaded('$base/medium.webp'), findsOneWidget);
      expect(net.requested.where((u) => u.startsWith(base)), ['$base/medium.webp']);
    });

    testWidgets('a photo whose medium file is missing shows its large size', (tester) async {
      final net = FakeImageNetwork(available: {'$base/large.webp'})..install();
      addTearDown(net.uninstall);

      await open(tester, _listing(photos: [photo]));

      expect(net.requested.take(2), ['$base/medium.webp', '$base/large.webp']);
      expect(net.loaded('$base/large.webp'), findsOneWidget);
      expect(net.requested, isNot(contains('$base/thumb.webp'))); // stops at the first file that works
    });

    testWidgets('with medium and large both missing it falls back to the thumbnail', (tester) async {
      final net = FakeImageNetwork(available: {'$base/thumb.webp'})..install();
      addTearDown(net.uninstall);

      await open(tester, _listing(photos: [photo]));

      expect(net.loaded('$base/thumb.webp'), findsOneWidget);
    });

    testWidgets('with Data saver on it shows the thumbnail the card already downloaded', (tester) async {
      DataSaver.enabled.value = true;
      final net = FakeImageNetwork(
          available: {'$base/thumb.webp', '$base/medium.webp', '$base/large.webp'})..install();
      addTearDown(net.uninstall);

      await open(tester, _listing(photos: [photo]));

      expect(net.loaded('$base/thumb.webp'), findsOneWidget);
      expect(net.requested.where((u) => u.startsWith(base)), ['$base/thumb.webp']);
    });

    testWidgets('with Data saver on a missing thumbnail falls back to medium, never large', (tester) async {
      DataSaver.enabled.value = true;
      final net = FakeImageNetwork(available: {'$base/large.webp'})..install();
      addTearDown(net.uninstall);

      await open(tester, _listing(photos: [photo]));

      expect(net.requested.where((u) => u.startsWith(base)),
          ['$base/thumb.webp', '$base/medium.webp']);
      expect(net.requested, isNot(contains('$base/large.webp')));
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

    await open(tester, _listing(negotiable: false, delivers: null, deliveryNote: null,
        storeId: 's1'));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('product-visit-store')), findsOneWidget);
    // Scroll through every section so each one is laid out.
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'after scroll $i');
    }
  });

  // 2026-11-12: Like and Save were two half-width 52dp slabs, and the price
  // and Start Negotiation sat in a bordered panel with two links under it.
  group('the foot of the screen', () {
    testWidgets('Like and Save are compact pills that still take a full tap', (tester) async {
      await open(tester, _listing());
      for (final k in ['product-like', 'product-save']) {
        final size = tester.getSize(find.byKey(Key(k)));
        // 36dp to see, 48dp to tap.
        expect(size.height, 48, reason: k);
        expect(size.width, lessThan(200), reason: k);
      }
      // Side by side at the start of the row, not stretched across it.
      final like = tester.getRect(find.byKey(const Key('product-like')));
      final save = tester.getRect(find.byKey(const Key('product-save')));
      expect(save.left, greaterThan(like.right));
      expect(save.right, lessThan(400));
    });

    testWidgets('the price and Start Negotiation stand at the bottom, with no panel or links', (tester) async {
      await open(tester, _listing());
      final screen = tester.getRect(find.byType(ProductScreen));
      final bar = find.byKey(const Key('product-cta-bar'));
      // closeTo: the Scaffold places the bar at (height - barHeight), so
      // its bottom can be a rounding step off the screen's.
      expect(tester.getRect(bar).bottom, closeTo(screen.bottom, 0.5));
      expect(find.descendant(of: bar, matching: find.byKey(const Key('product-cta'))), findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('Start Negotiation')), findsOneWidget);
      // The two "something is wrong" links moved into the page.
      for (final k in ['product-report', 'product-report-sold-out']) {
        expect(find.descendant(of: bar, matching: find.byKey(Key(k))), findsNothing, reason: k);
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      // No panel: a fade into the page, with no fill or border of its own.
      final deco = tester.widget<DecoratedBox>(bar).decoration as BoxDecoration;
      expect(deco.border, isNull);
      expect(deco.color, isNull);
      expect((deco.gradient! as LinearGradient).colors.first.opacity, 0);
      // The page runs on under the two, to the foot of the screen...
      expect(tester.getRect(find.byType(SingleChildScrollView)).bottom, closeTo(screen.bottom, 0.5));
      // ...and its end stops above them, so the last thing on it is readable.
      await tester.ensureVisible(find.byKey(const Key('product-report')));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const Key('product-report'))).bottom,
          lessThan(tester.getRect(find.byKey(const Key('product-cta'))).top));
    });
  });

  group('marking it unavailable', () {
    Map<String, dynamic> reportedJson() => {
          'id': 'listing-1',
          'name': 'iPhone 13 128GB',
          'category': 'Electronics',
          'price': 78000,
          'listing_type': 'direct',
          'status': 'active',
          'seller_id': 'seller-1',
          'seller_name': 'Grace Akinyi',
          'views': 42,
          'created_at': '2026-11-01T10:00:00',
          'sold_out': true,
          'reported_sold_out': true,
        };

    testWidgets('a buyer finds it by the stock line, and is told the seller can undo it', (tester) async {
      var reported = false;
      setFakeRoute((uri) {
        if (uri.path == '/listings/listing-1/sold-out') {
          reported = true;
          return {'listing_id': 'listing-1', 'reported_sold_out': true};
        }
        if (uri.path == '/listings/listing-1' && reported) return reportedJson();
        return null;
      });
      await open(tester, _listing());
      // A strip in the page under the stock line, saying what happens next -
      // it was 11.5px grey text under the buy button.
      final strip = find.byKey(const Key('product-availability'));
      expect(find.descendant(of: strip, matching: find.byKey(const Key('product-report-sold-out'))),
          findsOneWidget);
      expect(textIn(tester, const Key('product-availability')),
          allOf(contains('Mark as unavailable'), contains('The seller is texted and can undo it')));
      expect(tester.getRect(strip).top, greaterThan(tester.getRect(find.byKey(const Key('units-left'))).bottom));

      List<FakeRequest> reports() => fakeRequests
          .where((r) => r.method == 'POST' && r.uri.path == '/listings/listing-1/sold-out').toList();
      await tester.ensureVisible(find.byKey(const Key('product-report-sold-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-report-sold-out')));
      await tester.pumpAndSettle();
      expect(find.text('Mark as unavailable?'), findsOneWidget);
      expect(find.textContaining('the seller gets a text'), findsOneWidget);
      expect(reports(), isEmpty, reason: 'nothing is sent before the buyer confirms');

      await tester.tap(find.byKey(const Key('confirm-mark-unavailable')));
      await tester.pumpAndSettle();
      expect(reports(), hasLength(1));
      expect(find.textContaining('The seller has been told and can undo it'), findsOneWidget);
      // Hidden now: the foot of the screen says so, and nothing is offered.
      expect(textIn(tester, const Key('product-unavailable')),
          allOf(contains('Marked unavailable'), contains('The seller has been texted')));
      expect(find.byKey(const Key('product-availability')), findsNothing);
      expect(find.byKey(const Key('product-cta')), findsNothing);
    });

    final notOffered = {
      "the seller's own listing": () => _listing(sellerId: 'buyer-1'),
      'an auction': () => _listing(listingType: 'auction'),
      'a listing already sold out': () => _listing(status: 'pending', soldOut: true),
    };
    for (final e in notOffered.entries) {
      testWidgets('is not offered on ${e.key}', (tester) async {
        await open(tester, e.value());
        expect(find.byKey(const Key('product-report-sold-out')), findsNothing);
        expect(find.byKey(const Key('product-availability')), findsNothing);
      });
    }
  });

  group("the seller's number", () {
    testWidgets('is on the seller card, to call or copy', (tester) async {
      setFakeRoute((uri) => uri.path == '/auth/user/seller-1'
          ? {'id': 'seller-1', 'name': 'Grace Akinyi', 'phone': '0712345678'}
          : null);
      String? copied;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await open(tester, _listing());
      // As a Kenyan number reads, however the account stored it.
      expect(tester.widget<Text>(find.byKey(const Key('seller-card-phone-number'))).data,
          '+254 712 345 678');
      await tester.ensureVisible(find.byKey(const Key('seller-card-phone-copy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('seller-card-phone-copy')));
      await tester.pumpAndSettle();
      expect(copied, '+254712345678');
      expect(find.text('Number copied'), findsOneWidget);
    });

    testWidgets('a guest is asked to sign in for it', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await ApiService.loadSavedSession();
      await open(tester, _listing());
      expect(find.byKey(const Key('seller-card-phone-number')), findsNothing);
      expect(find.byKey(const Key('seller-card-phone-sign-in')), findsOneWidget);
    });

    testWidgets('a seller without one shows no number row', (tester) async {
      await open(tester, _listing());
      expect(find.byKey(const Key('seller-card-phone')), findsNothing);
      expect(find.byKey(const Key('seller-card-phone-sign-in')), findsNothing);
    });
  });

  // A free account asks Zeno about two listings a day (backend
  // premium/zeno_sessions.py); the card says so before the limit is met.
  group("today's free Zeno sessions", () {
    Map<String, dynamic> today(List<String> askedAbout, {int left = 1, bool limited = true}) => {
          'limited': limited,
          'day': '2026-11-12',
          'renews_at': '2026-11-12T21:00:00',
          'listing': {
            'limit': limited ? 2 : null,
            'used': 2 - left,
            'left': limited ? left : null,
            'listing_ids': askedAbout,
          },
          'agent': {'limit': limited ? 2 : null, 'used': 0, 'left': limited ? 2 : null},
        };

    void answer(Map<String, dynamic> sessions) => setFakeRoute((uri) => switch (uri.path) {
          '/zeno/sessions/today' => sessions,
          '/auth/user/seller-1' => {'id': 'seller-1', 'name': 'Grace Akinyi'},
          _ => null,
        });

    testWidgets('the Zeno card says how many are left', (tester) async {
      answer(today(['listing-7']));
      await open(tester, _listing());
      expect(textIn(tester, const Key('zeno-sessions-left')),
          contains('1 of 2 free Zeno sessions left today'));
    });

    testWidgets('a listing already asked about today costs nothing more', (tester) async {
      answer(today(['listing-1']));
      await open(tester, _listing());
      expect(textIn(tester, const Key('zeno-sessions-left')), contains('ask as much as you like'));
    });

    testWidgets('used up, it says when they come back', (tester) async {
      answer(today(['listing-7', 'listing-8'], left: 0));
      await open(tester, _listing());
      expect(textIn(tester, const Key('zeno-sessions-left')),
          allOf(contains("used today's 2 free Zeno sessions"), contains('midnight')));
    });

    testWidgets('nothing is counted with a plan', (tester) async {
      answer(today(const [], limited: false));
      await open(tester, _listing());
      expect(find.byKey(const Key('zeno-sessions-left')), findsNothing);
    });

    testWidgets("the seller's own listing is never counted, so nothing is asked", (tester) async {
      answer(today(const []));
      await open(tester, _listing(sellerId: 'buyer-1'));
      expect(find.byKey(const Key('zeno-sessions-left')), findsNothing);
      expect(fakeRequests.where((r) => r.uri.path == '/zeno/sessions/today'), isEmpty);
    });
  });

  group('reporting a problem', () {
    testWidgets('a buyer reports the listing with it and its seller attached', (tester) async {
      RouteSettings? report;
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (s) {
          if (s.name == '/') {
            return MaterialPageRoute(
              settings: RouteSettings(name: '/product', arguments: _listing()),
              builder: (_) => const ProductScreen(animateBackground: false),
            );
          }
          if (s.name == '/feedback') report = s;
          return MaterialPageRoute(builder: (_) => Scaffold(body: Text('route ${s.name}')));
        },
      ));
      await tester.pumpAndSettle();
      expect(find.text('Report a problem'), findsOneWidget);
      // At the end of the page since 2026-11-12, not under the buy button.
      await tester.ensureVisible(find.byKey(const Key('product-report')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-report')));
      await tester.pumpAndSettle();
      expect(report, isNotNull);
      final args = report!.arguments! as Map;
      expect(args['kind'], 'complaint');
      expect(args['category'], 'listing');
      expect(args['relatedListingId'], 'listing-1');
      expect(args['relatedUserId'], 'seller-1');
      expect(args['contextLabel'], contains('iPhone 13 128GB'));
    });

    testWidgets("the seller's own listing has no report button", (tester) async {
      await open(tester, _listing(sellerId: 'buyer-1'));
      expect(find.byKey(const Key('product-report')), findsNothing);
    });
  });
}
