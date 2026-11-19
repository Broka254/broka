// What a store may hold, and the seller's details in the description.
//   * a store is offered on the Review step only for a listing it may hold
//     (Store.mayHold): an online store takes no land, vehicles, property,
//     services or Other - and a store set before Review ("Add a product"
//     from My Store, a draft) is dropped for one, with the reason said;
//   * Go live checks the store again before quoting and publishing, since
//     a draft reopened there never passed through Review;
//   * the Description step opens with the Details step's answers as lines
//     ("RAM: 8GB"), brings lines it wrote up to date when a detail changes,
//     and leaves the seller's own words alone.
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/categories/domain/models/category.dart';
import 'package:broka/features/listing_fee/data/listing_fee_repository.dart';
import 'package:broka/features/listings/data/repositories/listings_repository.dart';
import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/presentation/my_store_screen.dart';
import 'package:broka/screens/sell_description_screen.dart';
import 'package:broka/screens/sell_details_screen.dart';
import 'package:broka/screens/sell_review_screen.dart';
import 'package:broka/screens/sell_zeno_alert_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/services/listing_publisher.dart';
import 'package:broka/services/photo_upload_tracker.dart';
import 'package:broka/services/sell_wizard_data.dart';
import 'package:broka/utils/listing_details_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _open(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: screen,
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

class _FakeUploader extends ImageUploadService {
  @override
  Future<UploadedImage> uploadFile(File file,
          {required String purpose, void Function(double fraction)? onProgress}) async =>
      const UploadedImage(id: 'photo-1', thumb: '/t', medium: '/m', large: '/l');
}

/// An online store, as GET /stores/mine sends it.
Store _shop({List<String>? excluded = const ['Automobiles', 'Land', 'Other', 'Property', 'Services']}) =>
    Store.fromJson({
      'id': 'store-1', 'name': 'Clanix', 'slug': 'clanix', 'category': 'Electronics',
      'categories': ['Electronics'],
      if (excluded != null) 'excluded_listing_categories': excluded,
    });

SellWizardData _listing({required String category, String? storeId}) {
  final data = SellWizardData(photoUploads: PhotoUploadTracker(service: _FakeUploader()))
    ..name = category == 'Land' ? 'Plot in Kitengela' : 'Samsung A54'
    ..category = category
    ..categoryId = category.toLowerCase()
    ..subcategoryId = category == 'Land' ? 'plots' : 'phones'
    ..subcategoryName = category == 'Land' ? 'Residential Plots' : 'Phones'
    ..description = 'Selling it as it is.'
    ..price = category == 'Land' ? '900000' : '32000'
    ..priceNegotiable = true
    ..quantity = '1'
    ..deliveryAvailable = false
    ..county = 'Kajiado'
    ..subcounty = 'Kitengela'
    ..smsAlerts = true
    ..storeId = storeId;
  if (category == 'Land') {
    data.attributes['land_size'] = '2';
    data.attributes['land_size_unit'] = 'acres';
  }
  data.verifiedPhotos.add(File('/photos/item.jpg'));
  data.photoUploads.restore({'/photos/item.jpg': 'photo-1'});
  return data;
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('What a store may hold', () {
    test("an online store holds none of the dealers' trades, as the server says", () {
      final shop = _shop();
      expect(shop.mayHold('Electronics'), isTrue);
      expect(shop.mayHold('Fashion'), isTrue);
      for (final trade in ['Land', 'land', 'Automobiles', 'Property', 'Services', 'Other']) {
        expect(shop.mayHold(trade), isFalse, reason: trade);
      }
      // Filed as the server files them: the old name of Automobiles, and
      // free text from an older build as Other.
      expect(shop.mayHold('Vehicles'), isFalse);
      expect(shop.mayHold('furniture'), isFalse);
      expect(shop.mayHold(''), isFalse);
    });

    test('a car yard holds cars, not land', () {
      final yard = Store.fromJson({
        'id': 'y', 'name': 'Yard', 'slug': 'yard', 'category': 'Automobiles',
        'excluded_listing_categories': ['Land', 'Other', 'Property', 'Services'],
      });
      expect(yard.mayHold('Automobiles'), isTrue);
      expect(yard.mayHold('vehicles'), isTrue);
      expect(yard.mayHold('Land'), isFalse);
    });

    test('from a backend before the rule, the online exclusions apply - less its own trade', () {
      expect(_shop(excluded: null).mayHold('Land'), isFalse);
      expect(_shop(excluded: null).mayHold('Electronics'), isTrue);
      final yard = Store.fromJson({'id': 'y', 'name': 'Yard', 'slug': 'yard', 'category': 'Automobiles'});
      expect(yard.mayHold('Automobiles'), isTrue);
      expect(yard.mayHold('Property'), isFalse);
    });
  });

  group('Review', () {
    testWidgets('a land listing is not offered the online store, and a preset store is dropped',
        (tester) async {
      final data = _listing(category: 'Land', storeId: 'store-1');
      await _open(tester, SellReviewScreen(data: data, loadMyStore: () async => Success(_shop())));
      expect(find.text('LIST UNDER'), findsNothing);
      expect(find.text('No Store'), findsNothing);
      expect(find.byKey(const Key('sell-store-not-for-category')), findsOneWidget);
      expect(find.textContaining("Land listings can't go in Clanix"), findsOneWidget);
      expect(data.storeId, isNull);
    });

    testWidgets('a phone is offered the store, and a preset store is kept', (tester) async {
      final data = _listing(category: 'Electronics', storeId: 'store-1');
      await _open(tester, SellReviewScreen(data: data, loadMyStore: () async => Success(_shop())));
      expect(find.text('LIST UNDER'), findsOneWidget);
      expect(find.text('No Store'), findsOneWidget);
      expect(find.text('Clanix'), findsOneWidget);
      expect(find.byKey(const Key('sell-store-not-for-category')), findsNothing);
      expect(data.storeId, 'store-1');
    });

    testWidgets('a preset store that is gone is dropped', (tester) async {
      final data = _listing(category: 'Electronics', storeId: 'store-1');
      await _open(tester, SellReviewScreen(data: data, loadMyStore: () async => const Success(null)));
      expect(find.text('LIST UNDER'), findsNothing);
      expect(data.storeId, isNull);
    });
  });

  group('Move listings in', () {
    Map<String, dynamic> row(String id, String name, String category) => {
          'id': id, 'seller_id': 'seller-1', 'name': name, 'category': category,
          'price': 1000, 'lat': -1.0, 'lng': 36.0,
        };

    Future<void> openSheet(WidgetTester tester, List<Map<String, dynamic>> rows) async {
      ApiService.currentUserId = 'seller-1';
      addTearDown(() => ApiService.currentUserId = null);
      final repo = ListingsRepository(client: ApiClient(client: MockClient((_) async => _json(rows))));
      await _open(tester, Scaffold(
        body: Builder(builder: (ctx) => TextButton(
              onPressed: () => showAddExistingListings(ctx, _shop(), listings: repo),
              child: const Text('open'),
            )),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('offers only what the store may hold', (tester) async {
      await openSheet(tester, [
        row('l1', 'Samsung A54', 'Electronics'),
        row('l2', 'Plot in Kitengela', 'Land'),
        row('l3', 'Old shelf item', 'furniture'),
      ]);
      expect(find.text('Samsung A54'), findsOneWidget);
      expect(find.text('Plot in Kitengela'), findsNothing);
      expect(find.text('Old shelf item'), findsNothing);
    });

    testWidgets('says why there is nothing to move in', (tester) async {
      await openSheet(tester, [row('l2', 'Plot in Kitengela', 'Land')]);
      expect(find.byKey(const Key('move-in-empty')), findsOneWidget);
      expect(find.textContaining("categories your store doesn't sell"), findsOneWidget);
    });
  });

  group('Go live', () {
    testWidgets('a reopened land draft set to the store is quoted and posted as the seller\'s own',
        (tester) async {
      final quotes = <Map<String, String>>[];
      final bodies = <Map<String, dynamic>>[];
      final fees = ListingFeeRepository(client: ApiClient(client: MockClient((req) async {
        quotes.add(req.url.queryParameters);
        return _json({'detail': 'not in this test'}, 404);
      })));
      final publisher = ListingPublisher(
          client: ApiClient(client: MockClient((req) async {
            bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
            return _json({'id': 'l1'}, 201);
          })),
          uploader: _FakeUploader());
      final data = _listing(category: 'Land', storeId: 'store-1');
      await _open(tester, SellZenoAlertScreen(
        data: data, question: 'Shall I text you?', feeRepository: fees, publisher: publisher,
        loadMyStore: () async => Success(_shop()),
      ));
      expect(data.storeId, isNull);
      expect(quotes.single.containsKey('store_id'), isFalse);

      await _tap(tester, find.byKey(const Key('sell-go-live')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(bodies.single.containsKey('store_id'), isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets('a phone set to the store still goes into it', (tester) async {
      final quotes = <Map<String, String>>[];
      final fees = ListingFeeRepository(client: ApiClient(client: MockClient((req) async {
        quotes.add(req.url.queryParameters);
        return _json({'detail': 'not in this test'}, 404);
      })));
      final data = _listing(category: 'Electronics', storeId: 'store-1');
      await _open(tester, SellZenoAlertScreen(
        data: data, question: 'Shall I text you?', feeRepository: fees,
        loadMyStore: () async => Success(_shop()),
      ));
      expect(data.storeId, 'store-1');
      expect(quotes.single['store_id'], 'store-1');
    });
  });

  group('The details in the description', () {
    test('lines a buyer scans: condition first, the details in their order', () {
      expect(
        ListingDetailsText.compose(condition: 'used', attributes: {
          'brand': 'Samsung', 'storage': '128GB', 'ram': '8GB', 'battery_health': '91', 'warranty': ' ',
        }),
        'Condition: Used\nBrand: Samsung\nStorage: 128GB\nRAM: 8GB\nBattery health: 91',
      );
      expect(ListingDetailsText.label('smart_tv'), 'Smart TV');
      expect(ListingDetailsText.label('bale_weight_kg'), 'Bale weight (kg)');
      expect(ListingDetailsText.compose(attributes: const {}), '');
    });

    test("a plot's size is one line, the server's derived acres none", () {
      expect(
        ListingDetailsText.compose(attributes: {
          'land_size': '0.125', 'land_size_unit': 'acres', 'land_size_acres': '0.125', 'title_deed': 'Yes',
        }),
        'Size: ⅛ acre\nTitle deed: Yes',
      );
    });

    test('never longer than a description may be', () {
      final text = ListingDetailsText.compose(
          attributes: {for (var i = 0; i < 30; i++) 'field_$i': 'x' * 190}, maxLength: 2000);
      expect(text.length, lessThanOrEqualTo(2000));
      expect(text, isNotEmpty);
    });

    SellWizardData phone({String description = '', String autoDescription = ''}) =>
        _listing(category: 'Electronics')
          ..condition = 'used'
          ..attributes = {'brand': 'Samsung', 'storage': '128GB', 'ram': '8GB'}
          ..description = description
          ..autoDescription = autoDescription;

    String box(WidgetTester tester) => tester
        .widget<TextField>(find.descendant(
            of: find.byKey(const Key('sell-description-field')), matching: find.byType(TextField)))
        .controller!
        .text;

    testWidgets('an empty box opens with the details in it, ready to skip', (tester) async {
      final data = phone();
      await _open(tester, SellDescriptionScreen(data: data));
      const lines = 'Condition: Used\nBrand: Samsung\nStorage: 128GB\nRAM: 8GB';
      expect(box(tester), lines);
      expect(data.description, lines);
      expect(find.byKey(const Key('sell-description-details-in')), findsOneWidget);
    });

    testWidgets('lines it wrote follow a changed detail; the seller\'s words stay', (tester) async {
      const before = 'Condition: Used\nBrand: Samsung\nStorage: 128GB\nRAM: 4GB';
      final data = phone(description: '$before\n\nComes with the box.', autoDescription: before);
      await _open(tester, SellDescriptionScreen(data: data));
      expect(box(tester), 'Condition: Used\nBrand: Samsung\nStorage: 128GB\nRAM: 8GB\n\nComes with the box.');
    });

    testWidgets('what the seller wrote is left as it is', (tester) async {
      final own = phone(description: 'Barely used, no scratches.');
      await _open(tester, SellDescriptionScreen(data: own));
      expect(box(tester), 'Barely used, no scratches.');
      expect(own.description, 'Barely used, no scratches.');
      expect(find.byKey(const Key('sell-description-details-in')), findsNothing);
    });

    test('a box left empty posts the details, as Review shows them', () {
      final data = phone();
      expect(data.descriptionToPost, 'Condition: Used\nBrand: Samsung\nStorage: 128GB\nRAM: 8GB');
      Map<String, dynamic> payload() => ListingPublisher.payloadFor(
          data, photoIds: const ['photo-1'], showcaseId: null, lat: -1.0, lng: 36.0);
      expect(payload()['description'], data.descriptionToPost);
      data.description = '  Barely used.  ';
      expect(payload()['description'], 'Barely used.');
    });

    testWidgets('Review shows the description buyers will read', (tester) async {
      final data = phone();
      await _open(tester, SellReviewScreen(data: data, loadMyStore: () async => const Success(null)));
      expect(find.text('Condition: Used\nBrand: Samsung\nStorage: 128GB\nRAM: 8GB'), findsOneWidget);
    });

    testWidgets('the Details step keeps them in the order it asks for them', (tester) async {
      final data = _listing(category: 'Electronics')..attributes = {};
      await _open(tester, SellDetailsScreen(
        data: data,
        loadFields: (_) async => Success([
          CategoryFilterField(fieldName: 'storage', fieldType: 'select', options: ['64GB', '128GB']),
          CategoryFilterField(fieldName: 'ram', fieldType: 'select', options: ['4GB', '8GB']),
          CategoryFilterField(fieldName: 'brand', fieldType: 'text', options: ['Samsung', 'Apple']),
        ]),
      ));
      // Tapped last to first; kept brand first (the step's own order), then
      // storage and RAM as the fields came.
      await _tap(tester, find.text('8GB'));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('128GB'));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Samsung'));
      await tester.pumpAndSettle();
      expect(data.attributes.keys.toList(), ['brand', 'storage', 'ram']);
      expect(ListingDetailsText.compose(attributes: data.attributes),
          'Brand: Samsung\nStorage: 128GB\nRAM: 8GB');
    });

    testWidgets('lines the seller edited are theirs, and stay as edited', (tester) async {
      const written = 'Condition: Used\nBrand: Samsung\nStorage: 128GB\nRAM: 4GB';
      final edited = phone(
          description: 'Condition: Used\nBrand: Samsung\nStorage: 64GB', autoDescription: written);
      await _open(tester, SellDescriptionScreen(data: edited));
      expect(box(tester), 'Condition: Used\nBrand: Samsung\nStorage: 64GB');
    });
  });
}
