// Listing with Zeno, and the sell wizard's way out (2026-10-08).
//
// What must hold:
//   * Back always leads somewhere: a wizard step that is the app's only
//     screen goes Home - its button and Android's Back - instead of doing
//     nothing. A seller reported being stuck on Photos for an hour.
//   * The splash screen reopens the wizard only for a draft saved moments
//     ago (the app killed mid-listing), not for one left days ago.
//   * Zeno lists the item from its photo: it looks with the photo's upload
//     id, the seller's answers go back with the listing, it prices it, it
//     makes a cover, and all of it lands in the draft - a skipped question
//     never as an empty "Label:" line.
//   * A refusal shows the plans' case, and the way to list it by hand.
//   * The wizard then opens at what Zeno couldn't know, with every step
//     Zeno filled in under it - Price for what sells per bag.
//   * The plans' case names the plan's own price, by the day.
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/premium/data/premium_repository.dart';
import 'package:broka/features/premium/domain/premium.dart';
import 'package:broka/features/premium/presentation/premium_upsell.dart';
import 'package:broka/features/zeno_assistant/data/zeno_selling_repository.dart';
import 'package:broka/features/zeno_assistant/domain/zeno_selling.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_autolist_screen.dart';
import 'package:broka/screens/sell_flow.dart';
import 'package:broka/screens/sell_photos_screen.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/services/photo_upload_tracker.dart';
import 'package:broka/services/sell_draft_store.dart';
import 'package:broka/services/sell_wizard_data.dart';
import 'package:broka/services/showcase_generator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _allowance(int allowance, int used) =>
    {'allowance': allowance, 'used': used, 'left': allowance - used};

PremiumStatus _me({String? plan = 'plus', int descriptionsLeft = 30, int coversLeft = 6, bool enabled = true}) =>
    PremiumStatus.fromJson({
      'enabled': enabled,
      'plan': plan == null ? null : {'id': plan, 'name': 'Plus', 'monthly_price': 199},
      'usage': {
        'ai_descriptions': _allowance(plan == null ? 1 : 30, (plan == null ? 1 : 30) - descriptionsLeft),
        'ai_covers': _allowance(plan == null ? 1 : 6, (plan == null ? 1 : 6) - coversLeft),
        'price_checks': _allowance(0, 0),
      },
      'trial': plan == null ? {'ai_covers': coversLeft, 'ai_descriptions': descriptionsLeft} : {},
    });

PremiumPlan _plus() => PremiumPlan.fromJson({
      'id': 'plus',
      'name': 'Plus',
      'pitch': '',
      'monthly_price': 199,
      'periods': const [],
      'allowances': {'ai_descriptions': 30, 'ai_covers': 6, 'sms_alerts': 30, 'voice_requests': 90},
    });

class _FakePremium extends PremiumRepository {
  _FakePremium(this.status);
  final PremiumStatus status;

  @override
  Future<Result<PremiumStatus>> me() async => Success(status);

  @override
  Future<Result<List<PremiumPlan>>> plans() async => Success([_plus()]);
}

const _phone = ZenoAutoListing(
  name: 'Samsung Galaxy A54',
  category: 'Electronics',
  categoryId: 'elec',
  subcategory: 'Phones',
  subcategoryId: 'phones',
  condition: 'used',
  attributes: {'storage': '128GB'},
  description: 'Brand: Samsung\nModel: Galaxy A54\nStorage: 128 GB',
);

class _FakeSelling extends ZenoSellingRepository {
  _FakeSelling({this.lookError});
  final ApiException? lookError;
  final looks = <String>[];
  final turns = <Map<String, dynamic>>[];
  final prices = <Map<String, dynamic>>[];

  @override
  Future<ZenoAutoTurn> autolist({
    required String photoId,
    required String language,
    Map<String, dynamic> draft = const {},
  }) async {
    looks.add(photoId);
    if (lookError != null) throw lookError!;
    return const ZenoAutoTurn(
      listing: _phone,
      reply: 'This looks like a Samsung Galaxy A54 - filed under Electronics › Phones.',
      questions: [ZenoDescribeQuestion(label: 'Battery health', question: "What's the battery health?")],
    );
  }

  @override
  Future<ZenoAutoTurn> autolistTurn({
    required ZenoAutoListing listing,
    required List<ZenoDescribeQuestion> questions,
    required String message,
    required List<Map<String, String>> history,
    required String language,
  }) async {
    turns.add({'listing': listing.name, 'questions': [for (final q in questions) q.label], 'message': message});
    return ZenoAutoTurn(
      listing: ZenoAutoListing(
        name: listing.name,
        category: listing.category,
        categoryId: listing.categoryId,
        subcategory: listing.subcategory,
        subcategoryId: listing.subcategoryId,
        condition: listing.condition,
        attributes: {...listing.attributes, 'battery_health': '91'},
        description: '${listing.description}\nBattery health: 91%',
      ),
      reply: 'Added. Ready for a price.',
    );
  }

  @override
  Future<ZenoPriceRange> autolistPrice({required Map<String, dynamic> draft, required String language}) async {
    prices.add(draft);
    return const ZenoPriceRange(
      reply: 'My estimate is KES 28,000-36,000. I would ask 32,000.',
      low: 28000,
      high: 36000,
      suggested: 32000,
    );
  }
}

class _FakeGenerator extends ShowcaseGenerator {
  final calls = <Map<String, String>>[];

  @override
  Future<GeneratedCover> generate({
    required String photoId,
    required String name,
    required String category,
    required String theme,
    String? condition,
    String? note,
  }) async {
    calls.add({'photoId': photoId, 'theme': theme, 'name': name});
    return const GeneratedCover(assetId: 'cover-1', previewUrl: '/m/cover-1', largeUrl: '/l/cover-1');
  }
}

class _FakeUploader extends ImageUploadService {
  @override
  Future<UploadedImage> uploadFile(File file,
          {required String purpose, void Function(double fraction)? onProgress}) async =>
      const UploadedImage(id: 'photo-1', thumb: '/t', medium: '/m', large: '/l');
}

class _NothingLost extends ImagePickerPlatform {
  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

SellWizardData _draft() {
  final data = SellWizardData(photoUploads: PhotoUploadTracker(service: _FakeUploader()));
  data.verifiedPhotos.add(File('/photos/phone.jpg'));
  data.photoUploads.restore({'/photos/phone.jpg': 'photo-1'});
  return data;
}

Future<void> _app(WidgetTester tester, Widget home, {Map<String, WidgetBuilder>? routes}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    routes: routes ?? const {},
    home: home,
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Opens Zeno's screen over a launcher, so its result can be read.
Future<List<bool?>> _openZeno(WidgetTester tester, SellWizardData data,
    {required _FakeSelling selling, _FakeGenerator? generator, PremiumStatus? status}) async {
  final results = <bool?>[];
  await _app(tester, Builder(
    builder: (ctx) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () async => results.add(await Navigator.of(ctx).push<bool>(MaterialPageRoute(
            builder: (_) => ZenoAutolistScreen(
              data: data,
              repository: selling,
              generator: generator ?? _FakeGenerator(),
              premium: _FakePremium(status ?? _me()),
              animateBackground: false,
            ),
          ))),
          child: const Text('open'),
        ),
      ),
    ),
  ), routes: {'/premium': (_) => const Scaffold(body: Text('plans'))});
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Back always leads somewhere', () {
    final home = {'/home': (_) => const Scaffold(body: Text('HOME'))};

    testWidgets('the Photos step as the only screen goes Home', (tester) async {
      ImagePickerPlatform.instance = _NothingLost();
      await _app(tester, SellPhotosScreen(premium: _FakePremium(_me())), routes: home);
      await tester.tap(find.byKey(const Key('sell-back')));
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets("and so does Android's Back - it doesn't close the app", (tester) async {
      ImagePickerPlatform.instance = _NothingLost();
      await _app(tester, SellPhotosScreen(premium: _FakePremium(_me())), routes: home);
      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handled, isTrue);
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('opened over Home, Back returns to it', (tester) async {
      ImagePickerPlatform.instance = _NothingLost();
      await _app(tester, Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute(builder: (_) => SellPhotosScreen(premium: _FakePremium(_me())))),
            child: const Text('Home underneath'),
          ),
        ),
      ));
      await tester.tap(find.text('Home underneath'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sell-back')));
      await tester.pumpAndSettle();
      expect(find.text('Home underneath'), findsOneWidget);
    });
  });

  group('At launch', () {
    Future<bool> fresh(Duration? age) async {
      SharedPreferences.setMockInitialValues({
        if (age != null)
          'broka_sell_draft_v1': jsonEncode({
            'name': 'Sofa',
            'savedAt': DateTime.now().subtract(age).toIso8601String(),
          }),
      });
      return SellDraftStore.hasFreshDraft(SellFlow.resumeWindow);
    }

    test('only a draft saved moments ago reopens the wizard', () async {
      expect(await fresh(const Duration(minutes: 2)), isTrue);
      expect(await fresh(const Duration(days: 3)), isFalse,
          reason: 'a draft left on purpose waits behind Sell, not in front of Home');
      expect(await fresh(null), isFalse);
    });
  });

  group('Zeno lists it from the photo', () {
    testWidgets('looks, takes the answers, prices it, makes a cover, and hands it all over',
        (tester) async {
      final selling = _FakeSelling();
      final generator = _FakeGenerator();
      final data = _draft();
      final results = await _openZeno(tester, data, selling: selling, generator: generator);

      // The look: by the photo's upload id, shown as the listing buyers see.
      expect(selling.looks, ['photo-1']);
      expect(find.byKey(const Key('zeno-autolist-name')), findsOneWidget);
      expect(find.text('Samsung Galaxy A54'), findsOneWidget);
      expect(find.text('Electronics › Phones'), findsOneWidget);
      expect(find.byKey(const Key('zeno-autolist-question-Battery health')), findsOneWidget);

      // An answer goes back with the listing and what was asked.
      await tester.enterText(find.byKey(const Key('zeno-autolist-input')), 'Battery is 91%');
      await _tap(tester, find.byKey(const Key('zeno-autolist-send')));
      expect(selling.turns.single,
          {'listing': 'Samsung Galaxy A54', 'questions': ['Battery health'], 'message': 'Battery is 91%'});
      expect(find.textContaining('Battery health: 91%', findRichText: true), findsOneWidget);

      // The price: a range, and Zeno's number taken.
      await _tap(tester, find.byKey(const Key('zeno-autolist-price')));
      expect(selling.prices.single['name'], 'Samsung Galaxy A54');
      expect(find.byKey(const Key('zeno-autolist-range')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('zeno-autolist-take-price')));
      await _tap(tester, find.byKey(const Key('zeno-autolist-offers')));

      // The cover, in the look Electronics sellers pick, kept.
      expect(find.byKey(const Key('zeno-autolist-footnote')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('zeno-autolist-cover')));
      expect(generator.calls.single, {'photoId': 'photo-1', 'theme': 'neon', 'name': 'Samsung Galaxy A54'});
      await _tap(tester, find.byKey(const Key('zeno-autolist-keep-cover')));

      expect(find.byKey(const Key('zeno-autolist-done')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('zeno-autolist-finish')));
      expect(results, [true]);
      expect(data.name, 'Samsung Galaxy A54');
      expect((data.categoryId, data.subcategoryId, data.subcategoryName), ('elec', 'phones', 'Phones'));
      expect(data.condition, 'used');
      expect(data.attributes, {'storage': '128GB', 'battery_health': '91'});
      expect(data.description, 'Brand: Samsung\nModel: Galaxy A54\nStorage: 128 GB\nBattery health: 91%');
      expect(data.price, '32000');
      expect(data.priceNegotiable, isTrue);
      expect(data.showcaseAssetId, 'cover-1');
      // Left for the seller: how many and delivery first.
      expect(SellFlow.stepAfterZeno(data), SellFlow.stock);
    });

    testWidgets('a refusal makes the case for a plan, and the seller can list it themselves',
        (tester) async {
      final selling = _FakeSelling(lookError: const ApiException(402,
          "You've used your free descriptions by Zeno.", details: {'upgrade_to': 'plus'}));
      final data = _draft();
      final results = await _openZeno(tester, data, selling: selling, status: _me(plan: null, descriptionsLeft: 0));
      expect(find.text('Let Zeno write listings that sell'), findsOneWidget);
      expect(find.text('BROKA Plus · KES 199 a month'), findsOneWidget);
      expect(find.text('About KES 7 a day'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('upsell-not-now')));
      await _tap(tester, find.byKey(const Key('zeno-autolist-myself')));
      expect(results, [false]);
      expect(data.name, isEmpty);
    });

    testWidgets('leaving early keeps what Zeno filled in, without the open questions', (tester) async {
      final data = _draft();
      final results = await _openZeno(tester, data, selling: _FakeSelling());
      await _tap(tester, find.byKey(const Key('zeno-autolist-back')));
      expect(results, [false]);
      expect(data.name, 'Samsung Galaxy A54');
      expect(data.categoryId, 'elec');
      expect(data.description, isNot(contains('Battery health')));
    });

    testWidgets('with plans off there is no AI cover to offer', (tester) async {
      final data = _draft();
      await _openZeno(tester, data, selling: _FakeSelling(), status: _me(enabled: false));
      await _tap(tester, find.byKey(const Key('zeno-autolist-price')));
      await _tap(tester, find.byKey(const Key('zeno-autolist-take-price')));
      await _tap(tester, find.byKey(const Key('zeno-autolist-fixed')));
      expect(find.byKey(const Key('zeno-autolist-cover')), findsNothing);
      expect(find.byKey(const Key('zeno-autolist-done')), findsOneWidget);
      expect(data.priceNegotiable, isFalse);
    });
  });

  group('Into the wizard', () {
    test("an item Zeno couldn't file keeps the seller's category; another kind drops old details", () {
      final data = SellWizardData()
        ..category = 'Fashion'
        ..categoryId = 'fashion'
        ..attributes = {'size': 'M'};
      applyZenoListing(data, const ZenoAutoListing(name: 'Blue dress', description: 'Colour: Blue'));
      expect((data.category, data.categoryId), ('Fashion', 'fashion'));
      expect(data.attributes, {'size': 'M'});

      applyZenoListing(data, _phone);
      expect((data.category, data.subcategoryId), ('Electronics', 'phones'));
      expect(data.attributes, {'storage': '128GB'});
    });

    test('opens where Zeno stopped: stock for a phone, price for maize, category when unfiled', () {
      final phone = SellWizardData()
        ..price = '32000'
        ..priceNegotiable = true
        ..county = 'Nairobi'
        ..subcounty = 'Westlands';
      phone.verifiedPhotos.add(File('/p.jpg'));
      applyZenoListing(phone, _phone);
      expect(SellFlow.stepAfterZeno(phone), SellFlow.stock);
      phone.deliveryAvailable = false;
      expect(SellFlow.stepAfterZeno(phone), SellFlow.review);

      // Maize sells by the bag: Zeno priced the lot, the seller says per what.
      final maize = SellWizardData()
        ..price = '3500'
        ..priceNegotiable = true
        ..deliveryAvailable = false
        ..county = 'Nakuru'
        ..subcounty = 'Njoro';
      applyZenoListing(maize, const ZenoAutoListing(
          name: 'Dry maize', category: 'Agriculture', categoryId: 'agri',
          subcategory: 'Cereals & Grains', subcategoryId: 'grains',
          description: 'Type: Dry white maize\nPacked: 90 kg bags'));
      expect(SellFlow.stepAfterZeno(maize), SellFlow.price);

      final unfiled = SellWizardData();
      applyZenoListing(unfiled, const ZenoAutoListing(name: 'Router', description: 'Brand: Airtel 4G router'));
      expect(SellFlow.stepAfterZeno(unfiled), SellFlow.category);
    });

    testWidgets("the Photos step's card opens Zeno, and then the wizard where Zeno stopped",
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('zeno');
      addTearDown(() => dir.deleteSync(recursive: true));
      final photo = File('${dir.path}/front.jpg')..writeAsBytesSync([1, 2, 3]);
      SharedPreferences.setMockInitialValues({
        'broka_sell_draft_v1': jsonEncode({
          'verifiedPhotoPaths': [photo.path],
          'photoAssetIds': {photo.path: 'photo-1'},
          // Left a while ago: it opens at Photos, as a seller coming back.
          'savedAt': DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
        }),
      });
      ImagePickerPlatform.instance = _NothingLost();
      SellWizardData? given;
      await _app(tester, SellPhotosScreen(
        premium: _FakePremium(_me(plan: null, descriptionsLeft: 1)),
        openZeno: (_, data) async {
          given = data;
          applyZenoListing(data, _phone);
          data
            ..price = '32000'
            ..priceNegotiable = true;
          return true;
        },
      ));
      // A seller without a plan: the first one is free, and the card says so.
      expect(find.byKey(const Key('zeno-boost-ribbon')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('sell-zeno-autolist')));
      expect(given?.verifiedPhotos.single.path, photo.path);
      expect(find.text('Stock & delivery'), findsOneWidget);
      expect(find.text('${SellFlow.stock} / ${SellFlow.total}'), findsOneWidget);

      // Every step Zeno filled in is under it.
      await _tap(tester, find.byKey(const Key('sell-back')));
      expect(find.text('Price'), findsOneWidget);
    });
  });

  group("The plans' case", () {
    testWidgets('says what the feature does for the sale, and the plan by the day', (tester) async {
      await _app(tester, Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showPremiumUpsell(ctx,
              message: 'Texts from Zeno come with BROKA Plus and up.',
              upgradeTo: 'plus',
              feature: PremiumFeature.sms,
              premium: _FakePremium(_me())),
          child: const Text('ask'),
        ),
      ));
      await _tap(tester, find.text('ask'));
      expect(find.text('Never miss a buyer'), findsOneWidget);
      expect(find.textContaining('even with the app closed'), findsOneWidget);
      expect(find.byKey(const Key('upsell-plan')), findsOneWidget);
      expect(find.text('About KES 7 a day'), findsOneWidget);
    });
  });
}
