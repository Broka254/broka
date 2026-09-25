// The sell wizard after the 2026-09-25 listing overhaul
// (LISTING_OVERHAUL.md). What these cover:
//   * a draft keeps everything the new steps ask for, reopens at the step
//     the seller was on - never past one they haven't finished - and reads
//     a cover pick that was pending when the app was killed as a cover
//   * the category step lists categories top to bottom, finds a category
//     by what sellers call the item (maize, boda, plot, mitumba) and shows
//     Mtumba first in Fashion
//   * Land can't pass the details step without its size
//   * the description is required
//   * the price says what it's for ("KES 3,500 / bag") and whether it's
//     fixed; the stock step asks how many and about delivery
//   * the cover step asks for the chosen look with the uploaded photo's id
//     and keeps the result by id
//   * the last step won't go live without an answer to Zeno, and sends it;
//     the answers appear once Zeno has finished asking, and once live the
//     seller chooses the Seller Dashboard or Home
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/categories/domain/category_search.dart';
import 'package:broka/features/categories/domain/models/category.dart';
import 'package:broka/screens/sell_category_screen.dart';
import 'package:broka/screens/sell_description_screen.dart';
import 'package:broka/screens/sell_details_screen.dart';
import 'package:broka/screens/sell_photos_screen.dart';
import 'package:broka/screens/sell_flow.dart';
import 'package:broka/screens/sell_price_screen.dart';
import 'package:broka/screens/sell_showcase_screen.dart';
import 'package:broka/screens/sell_stock_screen.dart';
import 'package:broka/screens/sell_zeno_alert_screen.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/services/listing_publisher.dart';
import 'package:broka/services/photo_upload_tracker.dart';
import 'package:broka/services/sell_draft_store.dart';
import 'package:broka/services/sell_photo_store.dart';
import 'package:broka/services/sell_wizard_data.dart';
import 'package:broka/services/showcase_generator.dart';
import 'package:broka/utils/land_size.dart';
import 'package:broka/utils/price_unit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── A small taxonomy, shaped like GET /categories/tree ────────────────────

Category _cat(String id, String name, [String? parent]) =>
    Category(id: id, name: name, parentId: parent);

final _tree = <CategoryNode>[
  CategoryNode(category: _cat('auto', 'Automobiles'), subcategories: [
    _cat('cars', 'Cars', 'auto'),
    _cat('boda', 'Motorcycles & Boda Bodas', 'auto'),
  ]),
  CategoryNode(category: _cat('land', 'Land'), subcategories: [
    _cat('plots', 'Residential Plots', 'land'),
    _cat('agri-land', 'Agricultural Land', 'land'),
  ]),
  CategoryNode(category: _cat('elec', 'Electronics'), subcategories: [
    _cat('phones', 'Phones', 'elec'),
  ]),
  CategoryNode(category: _cat('fashion', 'Fashion'), subcategories: [
    _cat('mtumba', SubcategoryHighlights.mtumba, 'fashion'),
    _cat('men', "Men's Clothing", 'fashion'),
  ]),
  CategoryNode(category: _cat('agri', 'Agriculture'), subcategories: [
    _cat('grains', 'Cereals & Grains', 'agri'),
    _cat('produce', 'Crops & Produce', 'agri'),
  ]),
  CategoryNode(category: _cat('other', 'Other'), subcategories: const []),
];

/// Reduced motion: the steps' backdrop and ambient loops stand still, so
/// pumpAndSettle can settle.
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

/// Taps [finder] after scrolling it into view - a 360x800 phone doesn't
/// show a whole step at once.
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

SellWizardData _complete() {
  final data = SellWizardData(photoUploads: PhotoUploadTracker(service: _FakeUploader()))
    ..name = 'Dry maize'
    ..category = 'Agriculture'
    ..categoryId = 'agri'
    ..subcategoryId = 'grains'
    ..subcategoryName = 'Cereals & Grains'
    ..description = 'Dry maize from this season, clean bags.'
    ..price = '3500'
    ..priceUnit = '90kg bag'
    ..priceNegotiable = true
    ..quantity = '100'
    ..deliveryAvailable = false
    ..county = 'Nakuru'
    ..subcounty = 'Njoro';
  data.verifiedPhotos.add(File('/photos/maize.jpg'));
  data.photoUploads.restore({'/photos/maize.jpg': 'photo-1'});
  return data;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Draft', () {
    test('keeps every new answer, and an old "Vehicles" draft is Automobiles', () {
      final data = _complete()
        ..resumeStep = 6
        ..pendingPick = 'showcase'
        ..deliveryNote = 'Within Nakuru'
        ..smsAlerts = false
        ..setAiShowcase(assetId: 'ai-1', previewUrl: '/m/ai-1', theme: 'wood');
      final json = data.toDraftJson();
      // A photo that still exists on the phone, for fromDraftJson to keep.
      final dir = Directory.systemTemp.createTempSync('sell');
      final photo = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
      json['verifiedPhotoPaths'] = [photo.path];

      final restored = SellWizardData.fromDraftJson(json)!;
      expect(restored.resumeStep, 6);
      expect(restored.pendingPick, 'showcase');
      expect(restored.priceUnit, '90kg bag');
      expect(restored.priceNegotiable, isTrue);
      expect(restored.quantity, '100');
      expect(restored.deliveryNote, 'Within Nakuru');
      expect(restored.smsAlerts, isFalse);
      expect(restored.showcaseAssetId, 'ai-1');
      expect(restored.showcaseTheme, 'wood');

      final old = SellWizardData.fromDraftJson({'name': 'Probox', 'category': 'Vehicles'})!;
      expect(old.category, 'Automobiles');
      dir.deleteSync(recursive: true);
    });

    test('a gallery cover whose file is gone is no cover', () {
      final restored = SellWizardData.fromDraftJson({
        'name': 'Sofa',
        'showcaseImageSource': 'gallery',
        'showcaseLocalPath': '/nowhere/cover.jpg',
      })!;
      expect(restored.hasShowcase, isFalse);
      expect(restored.showcaseImageSource, isNull);
    });

    test('reopens at the saved step, but never past an unfinished one', () {
      final data = _complete()..resumeStep = SellFlow.showcase;
      expect(SellFlow.resumableStep(data), SellFlow.showcase);

      data.description = 'too short';
      expect(SellFlow.resumableStep(data), SellFlow.description);

      data.verifiedPhotos.clear();
      expect(SellFlow.resumableStep(data), SellFlow.photos);
    });

    test('land is not finished without its size', () {
      final data = _complete()
        ..category = 'Land'
        ..categoryId = 'land'
        ..subcategoryId = 'plots'
        ..resumeStep = SellFlow.price;
      expect(SellFlow.resumableStep(data), SellFlow.details);
      data.attributes = {'land_size': '0.125', 'land_size_unit': 'acres'};
      expect(SellFlow.resumableStep(data), SellFlow.price);
    });
  });

  group('A pick lost to Android killing the app', () {
    testWidgets('a gallery cover comes back as the cover, not as a camera photo', (tester) async {
      final dir = Directory.systemTemp.createTempSync('lost');
      final lost = File('${dir.path}/cover.jpg')..writeAsBytesSync([1, 2, 3]);
      addTearDown(() => dir.deleteSync(recursive: true));
      SharedPreferences.setMockInitialValues({
        'broka_sell_draft_v1': jsonEncode({'name': 'Sofa set', 'pendingPick': 'showcase'}),
      });
      ImagePickerPlatform.instance = _LostPick(lost.path);
      SellPhotoStore.baseDirectory = () async => throw UnsupportedError('no storage in tests');

      await _open(tester, const SellPhotosScreen());

      final draft = (await SellDraftStore.load())!;
      expect(draft['verifiedPhotoPaths'], isEmpty,
          reason: 'a gallery image is never a camera-verified listing photo');
      expect(draft['showcaseLocalPath'], lost.path);
      expect(draft['showcaseImageSource'], 'gallery');
      expect(draft['pendingPick'], isNull);
    });

    testWidgets('an image with no pending pick is ignored', (tester) async {
      final dir = Directory.systemTemp.createTempSync('lost');
      final lost = File('${dir.path}/x.jpg')..writeAsBytesSync([1]);
      addTearDown(() => dir.deleteSync(recursive: true));
      SharedPreferences.setMockInitialValues({
        'broka_sell_draft_v1': jsonEncode({'name': 'Sofa set'}),
      });
      ImagePickerPlatform.instance = _LostPick(lost.path);
      await _open(tester, const SellPhotosScreen());
      expect(find.text('0 / 6'), findsOneWidget);
    });
  });

  group('Coming back after the app was killed', () {
    Future<void> reopen(WidgetTester tester, Duration age) async {
      final dir = Directory.systemTemp.createTempSync('resume');
      addTearDown(() => dir.deleteSync(recursive: true));
      final photo = File('${dir.path}/front.jpg')..writeAsBytesSync([1, 2, 3]);
      final json = _complete().toDraftJson()
        ..['verifiedPhotoPaths'] = [photo.path]
        // Uploaded before the kill: nothing to upload again.
        ..['photoAssetIds'] = {photo.path: 'photo-1'}
        ..['resumeStep'] = SellFlow.description
        ..['savedAt'] = DateTime.now().subtract(age).toIso8601String();
      SharedPreferences.setMockInitialValues({'broka_sell_draft_v1': jsonEncode(json)});
      ImagePickerPlatform.instance = _NothingLost();
      await _open(tester, const SellPhotosScreen());
    }

    testWidgets('a draft saved moments ago reopens at the step it was on', (tester) async {
      await reopen(tester, const Duration(minutes: 2));
      expect(find.text('Description'), findsOneWidget);
      expect(find.text('4 / 10'), findsOneWidget);
    });

    testWidgets('a draft left for days opens at Photos, offering to start over', (tester) async {
      await reopen(tester, const Duration(days: 3));
      expect(find.text('1 / 10'), findsOneWidget);
      expect(find.text('Start over'), findsOneWidget);
    });
  });

  group('Land size', () {
    test('reads the way Kenyans say it', () {
      expect(LandSize.describe({'land_size': '0.125', 'land_size_unit': 'acres'}), '⅛ acre');
      expect(LandSize.describe({'land_size': 2.5, 'land_size_unit': 'acres'}), '2½ acres');
      expect(LandSize.describe({'land_size': '2', 'land_size_unit': '50x100 plots'}), '2 plots (50×100)');
      expect(LandSize.describe({'land_size': '450', 'land_size_unit': 'square metres'}), '450 m²');
      // A Property/Land listing from before the size was its own field.
      expect(LandSize.describe({'acreage': '5'}), '5 acres');
      expect(LandSize.describe({'make': 'Toyota'}), isNull);
    });

    test('says what is missing', () {
      expect(LandSize.problem({}), isNotNull);
      expect(LandSize.problem({'land_size': '1'}), isNotNull);
      expect(LandSize.problem({'land_size': '-1', 'land_size_unit': 'acres'}), isNotNull);
      expect(LandSize.problem({'land_size': '1', 'land_size_unit': 'Hectares'}), isNull);
    });
  });

  group('Price units', () {
    test('clean the way the server does', () {
      expect(PriceUnits.clean('per Bag'), 'bag');
      expect(PriceUnits.clean('item'), isNull);
      expect(PriceUnits.problem('bag; drop'), isNotNull);
      expect(PriceUnits.problem('crate'), isNull);
    });

    test('count and label', () {
      expect(PriceUnits.quantity(100, 'bag'), '100 bags');
      expect(PriceUnits.quantity(1, 'bag'), '1 bag');
      expect(PriceUnits.quantity(2, 'box'), '2 boxes');
      expect(PriceUnits.quantity(1500, 'kg'), '1,500 kg');
      expect(PriceUnits.plural('acre per year'), 'acres per year');
      expect(PriceUnits.priceLabel('KES 3,500', 'bag'), 'KES 3,500 / bag');
      expect(PriceUnits.priceLabel('KES 3,500', null), 'KES 3,500');
    });

    test('suggest units that fit the item', () {
      expect(PriceUnits.suggestionsFor('Agriculture', 'Cereals & Grains').first, '90kg bag');
      expect(PriceUnits.suggestionsFor('Fashion', SubcategoryHighlights.mtumba), contains('bale'));
      expect(PriceUnits.suggestionsFor('Land', 'Residential Plots'), contains('plot'));
    });
  });

  group('Category search', () {
    String? top(String q) {
      final m = CategorySearch.search(q, _tree);
      return m.isEmpty ? null : (m.first.subcategory?.name ?? m.first.node.category.name);
    }

    test('finds items by what sellers call them', () {
      expect(top('mahindi'), 'Cereals & Grains');
      expect(top('maize'), 'Cereals & Grains');
      expect(top('dry maize 90kg'), 'Cereals & Grains');
      expect(top('boda'), 'Motorcycles & Boda Bodas');
      expect(top('plot'), 'Residential Plots');
      expect(top('shamba'), 'Agricultural Land');
      expect(top('mitumba'), SubcategoryHighlights.mtumba);
      expect(top('iphone'), 'Phones');
    });

    test('a single letter searches nothing', () {
      expect(CategorySearch.search('m', _tree), isEmpty);
    });
  });

  group('Category step', () {
    Future<SellWizardData> open(WidgetTester tester) async {
      final data = SellWizardData();
      await _open(tester, SellCategoryScreen(
          data: data, loadTree: () async => Success(_tree)));
      return data;
    }

    testWidgets('lists the categories one under another', (tester) async {
      await open(tester);
      final ys = [
        for (final name in ['Automobiles', 'Land', 'Electronics', 'Fashion'])
          tester.getTopLeft(find.byKey(Key('sell-category-$name'))).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      final xs = ['Automobiles', 'Land'].map(
          (n) => tester.getTopLeft(find.byKey(Key('sell-category-$n'))).dx).toSet();
      expect(xs, hasLength(1), reason: 'one column, not a wrap of chips');
    });

    testWidgets('Fashion opens with Mtumba first, marked popular, and it sets used',
        (tester) async {
      final data = await open(tester);
      await tester.tap(find.byKey(const Key('sell-category-Fashion')));
      await tester.pumpAndSettle();
      final mtumba = find.byKey(const Key('sell-subcategory-${SubcategoryHighlights.mtumba}'));
      final men = find.byKey(const Key("sell-subcategory-Men's Clothing"));
      expect(tester.getTopLeft(mtumba).dy, lessThan(tester.getTopLeft(men).dy));
      expect(find.text('POPULAR'), findsOneWidget);

      await tester.tap(mtumba);
      await tester.pumpAndSettle();
      expect(data.category, 'Fashion');
      expect(data.subcategoryId, 'mtumba');
      expect(data.condition, 'used');
      expect(find.text('FILED UNDER'), findsOneWidget);
    });

    testWidgets('search finds the subcategory and picks it', (tester) async {
      final data = await open(tester);
      await tester.enterText(find.byKey(const Key('sell-category-search')), 'mahindi');
      await tester.pumpAndSettle();
      expect(find.text('in Agriculture'), findsWidgets);
      await tester.tap(find.text('Cereals & Grains'));
      await tester.pumpAndSettle();
      expect(data.subcategoryName, 'Cereals & Grains');
      expect(data.categoryId, 'agri');
    });

    testWidgets('Next asks for the type of item', (tester) async {
      final data = await open(tester);
      await tester.tap(find.byKey(const Key('sell-category-Land')));
      await tester.pumpAndSettle();
      data.categoryId = 'land';
      await _tap(tester, find.text('NEXT'));
      await tester.pump();
      expect(find.textContaining('Choose'), findsWidgets);
    });
  });

  group('Details step', () {
    testWidgets('land needs its size before going on', (tester) async {
      final data = SellWizardData()
        ..category = 'Land'
        ..categoryId = 'land'
        ..subcategoryId = 'plots'
        ..subcategoryName = 'Residential Plots';
      await _open(tester, SellDetailsScreen(
        data: data,
        loadFields: (_) async => Success([
          CategoryFilterField(fieldName: 'land_size', fieldType: 'number_range'),
          CategoryFilterField(fieldName: 'land_size_unit', fieldType: 'select',
              options: const ['Acres', 'Hectares']),
          CategoryFilterField(fieldName: 'title_deed', fieldType: 'select', options: const ['Yes', 'No']),
        ]),
      ));
      expect(find.text('LAND SIZE  (REQUIRED)'), findsOneWidget);
      // The generic fields don't ask for the size a second time.
      expect(find.text('LAND SIZE'), findsNothing);
      expect(find.text('CONDITION'), findsNothing, reason: 'land is not new or used');

      await tester.enterText(find.byKey(const Key('sell-name-field')), 'Plot in Kitengela');
      await _tap(tester, find.text('NEXT'));
      await tester.pump();
      expect(find.text('Enter the size of the land.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('sell-land-size')), '0.125');
      await _tap(tester, find.byKey(const Key('sell-land-unit-acres')));
      await tester.pump();
      expect(data.attributes, {'land_size': '0.125', 'land_size_unit': 'acres'});
      expect(find.text('⅛ acre'), findsOneWidget);
    });
  });

  group('Description step', () {
    testWidgets('is required', (tester) async {
      final data = SellWizardData()..category = 'Electronics';
      await _open(tester, SellDescriptionScreen(data: data));
      await tester.enterText(find.byKey(const Key('sell-description-field')), 'Nice phone');
      await _tap(tester, find.text('NEXT'));
      await tester.pump();
      expect(find.textContaining('at least 20 characters'), findsOneWidget);
      expect(find.text('10 more characters'), findsOneWidget);
    });
  });

  group('Price step', () {
    testWidgets('says what the price is for, and asks if it is fixed', (tester) async {
      final data = SellWizardData()
        ..category = 'Agriculture'
        ..subcategoryName = 'Cereals & Grains';
      await _open(tester, SellPriceScreen(data: data));
      await tester.enterText(find.byKey(const Key('sell-price-field')), '3500');
      await _tap(tester, find.byKey(const Key('sell-unit-90kg bag')));
      await tester.pumpAndSettle();
      expect(find.text('KES 3,500 / 90kg bag'), findsOneWidget);

      await _tap(tester, find.text('NEXT'));
      await tester.pump();
      expect(find.text('Say whether the price is fixed or open to offers.'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('sell-negotiable-no')));
      await tester.pump();
      expect(data.priceNegotiable, isFalse);
      expect(data.priceUnit, '90kg bag');
    });

    testWidgets('a unit of the seller\'s own', (tester) async {
      final data = SellWizardData()..category = 'Other';
      await _open(tester, SellPriceScreen(data: data));
      await _tap(tester, find.byKey(const Key('sell-unit-other')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sell-unit-field')), 'per Trip');
      await tester.pump();
      expect(data.priceUnit, 'trip');
    });
  });

  group('Stock step', () {
    testWidgets('counts in the price unit and needs a delivery answer', (tester) async {
      final data = SellWizardData()..priceUnit = 'bag';
      await _open(tester, SellStockScreen(data: data));
      expect(find.text('HOW MANY BAGS DO YOU HAVE?'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('sell-quantity-field')), '100');
      await tester.pump();
      expect(find.text('100 bags available'), findsOneWidget);

      await _tap(tester, find.text('NEXT'));
      await tester.pump();
      expect(find.text('Say whether you can arrange delivery.'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('sell-delivery-yes')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sell-delivery-note')), findsOneWidget);
      expect(data.deliveryAvailable, isTrue);
      expect(data.quantity, '100');
    });
  });

  group('Cover step', () {
    testWidgets('asks for the chosen look with the photo id, and keeps the result by id',
        (tester) async {
      final generator = _FakeGenerator();
      final data = _complete();
      await _open(tester, SellShowcaseScreen(data: data, generator: generator));
      // Agriculture's likeliest look.
      expect(find.text("ZENO'S PICK"), findsOneWidget);

      await tester.scrollUntilVisible(find.byKey(const Key('showcase-theme-neon')), 150,
          scrollable: find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.right));
      await _tap(tester, find.byKey(const Key('showcase-theme-neon')));
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('showcase-generate')));
      await tester.pump();
      expect(find.text('Zeno is creating your cover'), findsOneWidget);
      expect(generator.calls.single, {'photoId': 'photo-1', 'theme': 'neon'});

      generator.finish();
      await tester.pumpAndSettle();
      expect(find.text('Zeno is creating your cover'), findsNothing);
      await _tap(tester, find.byKey(const Key('showcase-use')));
      await tester.pumpAndSettle();
      expect(data.showcaseAssetId, 'cover-1');
      expect(data.showcaseImageSource, 'ai');
      expect(data.showcaseTheme, 'neon');
    });

    testWidgets('a cancelled generation is ignored when it lands', (tester) async {
      final generator = _FakeGenerator();
      final data = _complete();
      await _open(tester, SellShowcaseScreen(data: data, generator: generator));
      await _tap(tester, find.byKey(const Key('showcase-generate')));
      await tester.pump();
      await _tap(tester, find.text('Cancel'));
      await tester.pump();
      generator.finish();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('showcase-use')), findsNothing);
      expect(data.hasShowcase, isFalse);
    });

    testWidgets('a refusal reads as the server\'s sentence', (tester) async {
      final generator = _FakeGenerator(error: const ApiException(429,
          "You've made as many AI covers as we allow in a hour.", code: 'SHOWCASE_LIMIT'));
      await _open(tester, SellShowcaseScreen(data: _complete(), generator: generator));
      await _tap(tester, find.byKey(const Key('showcase-generate')));
      await tester.pumpAndSettle();
      expect(find.textContaining('as many AI covers'), findsOneWidget);
    });
  });

  group('Go live', () {
    testWidgets('needs an answer to Zeno, then publishes it', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      final client = ApiClient(client: MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'id': 'l1'}), 201,
            headers: {'content-type': 'application/json'});
      }));
      final data = _complete();
      await _open(
        tester,
        SellZenoAlertScreen(
            data: data, publisher: ListingPublisher(client: client, uploader: _FakeUploader())),
        routes: {'/home': (_) => const Text('HOME')},
      );
      await _tap(tester, find.byKey(const Key('sell-go-live')));
      await tester.pump();
      expect(find.text('Tell Zeno yes or no first.'), findsOneWidget);
      expect(bodies, isEmpty);

      await _tap(tester, find.byKey(const Key('sell-sms-no')));
      await tester.pump();
      await _tap(tester, find.byKey(const Key('sell-go-live')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Your listing is live!'), findsOneWidget);
      await tester.pumpAndSettle();
      // No leaving on its own: the seller picks where to go.
      expect(find.text('HOME'), findsNothing);
      expect(find.byKey(const Key('sell-open-dashboard')), findsOneWidget);
      expect(bodies.single['sms_alerts'], isFalse);
      expect(bodies.single['price_unit'], '90kg bag');
      expect(bodies.single['quantity'], 100);

      await tester.tap(find.byKey(const Key('sell-back-home')));
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
      expect(find.byKey(const Key('sell-open-dashboard')), findsNothing);
    });

    testWidgets('offers the Seller Dashboard once live, with Home under it', (tester) async {
      final client = ApiClient(client: MockClient((req) async => http.Response(
          jsonEncode({'id': 'l1'}), 201, headers: {'content-type': 'application/json'})));
      await _open(
        tester,
        SellZenoAlertScreen(
            data: _complete()..smsAlerts = true,
            publisher: ListingPublisher(client: client, uploader: _FakeUploader())),
        routes: {
          '/home': (_) => const Text('HOME'),
          '/seller-dashboard': (context) => Scaffold(
                body: TextButton(onPressed: () => Navigator.of(context).pop(),
                    child: const Text('DASHBOARD')),
              ),
        },
      );
      // Before going live there's nothing to open.
      expect(find.byKey(const Key('sell-open-dashboard')), findsNothing);
      await _tap(tester, find.byKey(const Key('sell-go-live')));
      await tester.pumpAndSettle();
      expect(find.text('Open my Seller Dashboard'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sell-open-dashboard')));
      await tester.pumpAndSettle();
      expect(find.text('DASHBOARD'), findsOneWidget);
      // Back from the dashboard is Home, not the finished wizard.
      await tester.tap(find.text('DASHBOARD'));
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
      expect(find.byType(SellZenoAlertScreen), findsNothing);
    });

    testWidgets('the answers wait until Zeno has finished asking', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      const question = 'Hi Wanjiku! Want a heads-up by SMS when a buyer shows interest '
          'in "Dry maize" and you haven\'t replied?';
      final data = _complete();
      await tester.pumpWidget(MaterialApp(
          home: SellZenoAlertScreen(data: data, question: question)));
      await tester.pump(const Duration(milliseconds: 200));
      // Thinking first; nothing to answer yet, and a tap does nothing.
      expect(find.text('Zeno is thinking…'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sell-sms-yes')), warnIfMissed: false);
      await tester.pump();
      expect(data.smsAlerts, isNull);

      // Then the words, a few at a time.
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('Zeno is thinking…'), findsNothing);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // All of it - the caret gone - and the answers with it.
      expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == question),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('sell-sms-yes')));
      await tester.pump();
      expect(data.smsAlerts, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('every step draws its animations without error', (tester) async {
      final data = _complete()..category = 'Land'..categoryId = 'land';
      await _animate(tester, SellCategoryScreen(data: data, loadTree: () async => Success(_tree)));
      await _animate(tester, SellPriceScreen(data: _complete()));
      await _animate(tester, SellStockScreen(data: _complete()));
      await _animate(tester, SellZenoAlertScreen(data: _complete()));
      final generator = _FakeGenerator();
      await tester.pumpWidget(MaterialApp(
          home: SellShowcaseScreen(data: _complete(), generator: generator)));
      // Every look, painted - in the order shown: Zeno's pick first.
      for (final id in ['nature', 'studio', 'luxury', 'wood', 'neon', 'pastel']) {
        final tile = find.byKey(Key('showcase-theme-$id'));
        await tester.scrollUntilVisible(tile, 150, scrollable: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.right));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.ensureVisible(find.byKey(const Key('showcase-generate')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('showcase-generate')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      generator.finish();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.byKey(const Key('showcase-use')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    test('masks the phone number it will text', () {
      expect(_masked('+254712345678'), '07•• ••• 678');
      expect(_masked('0712345678'), '07•• ••• 678');
      expect(_masked('123'), isNull);
    });
  });
}

String? _masked(String phone) => maskedPhone(phone);

/// Runs [screen] with animations ON for a few seconds of frames - the
/// painted looks, the orbit, the ripples - then removes it, failing on any
/// exception along the way.
Future<void> _animate(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: screen));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  expect(tester.takeException(), isNull);
  // Gone, so the endless loops stop with it.
  await tester.pumpWidget(const SizedBox());
}

class _NothingLost extends ImagePickerPlatform {
  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

class _LostPick extends ImagePickerPlatform {
  _LostPick(this.path);
  final String path;

  @override
  Future<LostDataResponse> getLostData() async =>
      LostDataResponse(file: XFile(path), type: RetrieveType.image);
}

class _FakeGenerator extends ShowcaseGenerator {
  _FakeGenerator({this.error});
  final ApiException? error;
  final calls = <Map<String, String>>[];
  final _done = Completer<void>();

  void finish() => _done.complete();

  @override
  Future<GeneratedCover> generate({
    required String photoId,
    required String name,
    required String category,
    required String theme,
    String? condition,
    String? note,
  }) async {
    calls.add({'photoId': photoId, 'theme': theme});
    if (error != null) throw error!;
    await _done.future;
    return const GeneratedCover(assetId: 'cover-1', previewUrl: '/m/cover-1', largeUrl: '/l/cover-1');
  }
}
