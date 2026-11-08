// The sell wizard's premium offers as strips (2026-11-08).
//
// What must hold:
//   * Zeno's offers on Photos, Description and Price are strips, not pages:
//     under 160 dp (the cards were 260-460), so on a 360 x 800 phone each
//     step's own field is on screen without scrolling;
//   * they are still seen: the plan's tag on the strip, an amber Unlock
//     when it needs a plan, FIRST ONE FREE in the tag's place for a free
//     try, and a tap anywhere on the strip - its pill included - does it;
//   * the case moved rather than vanished: a locked strip opens the plans'
//     sheet with the example (Zeno's lines, the hidden price range, the
//     text Zeno would send), which is no longer on the step;
//   * no plan's name on a feature that is free while plans are off;
//   * the strip's sweep of light plays once and stops, and not at all
//     under reduced motion;
//   * Go live says the listing fee right above GO LIVE, not at the end of
//     the scroll, and offers texts as a strip.
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/listing_fee/data/listing_fee_repository.dart';
import 'package:broka/features/premium/data/premium_repository.dart';
import 'package:broka/features/premium/domain/premium.dart';
import 'package:broka/screens/sell_description_screen.dart';
import 'package:broka/screens/sell_photos_screen.dart';
import 'package:broka/screens/sell_price_screen.dart';
import 'package:broka/screens/sell_zeno_alert_screen.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/services/photo_upload_tracker.dart';
import 'package:broka/services/sell_wizard_data.dart';
import 'package:broka/widgets/sell_step_scaffold.dart';
import 'package:broka/widgets/sell_zeno_boost_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _allowance(int allowance, int used) =>
    {'allowance': allowance, 'used': used, 'left': allowance - used};

/// GET /premium/me, as entitlements.summary builds it. No plan and no
/// allowances: every one of Zeno's offers is locked.
PremiumStatus _me({String? plan, int descriptions = 0, int checks = 0, bool enabled = true}) =>
    PremiumStatus.fromJson({
      'enabled': enabled,
      'plan': plan == null ? null : {'id': plan, 'name': plan == 'pro' ? 'Pro' : 'Plus', 'monthly_price': 199},
      'renews_at': '2026-12-08T08:00:00',
      'usage': {
        'ai_descriptions': _allowance(descriptions, 0),
        'price_checks': _allowance(checks, 0),
        'ai_covers': _allowance(1, 0),
      },
      'trial': {'ai_descriptions': plan == null ? descriptions : 0},
    });

class _FakePremium extends PremiumRepository {
  _FakePremium(this.status);
  final PremiumStatus status;

  @override
  Future<Result<PremiumStatus>> me() async => Success(status);

  // No plans to quote: the sheet works without its plan line.
  @override
  Future<Result<List<PremiumPlan>>> plans() async => const Success(<PremiumPlan>[]);
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

/// GET /pricing/listing-fee/quote for the draft: KES 84 for two months.
ListingFeeRepository _fees({bool enabled = true}) => ListingFeeRepository(
    client: ApiClient(client: MockClient((req) async => http.Response(
        jsonEncode({
          'category': 'Electronics',
          'list_price': 84,
          'monthly_fee': 84,
          'period_months': 2,
          'discount_percent': 0,
          'options': const [],
          'recommendation': const {'months': 2, 'expected_days_to_sell': 30, 'strength': 'none'},
          'fees_enabled': enabled,
          'free_listing': false,
          'store_covered': false,
        }),
        200,
        headers: {'content-type': 'application/json'}))));

SellWizardData _draft() {
  final data = SellWizardData(photoUploads: PhotoUploadTracker(service: _FakeUploader()))
    ..name = 'Samsung Galaxy A54'
    ..category = 'Electronics'
    ..categoryId = 'elec'
    ..subcategoryId = 'phones'
    ..subcategoryName = 'Phones'
    ..description = 'Clean, no scratches, with charger and box.'
    ..price = '40000'
    ..priceNegotiable = true
    ..quantity = '1'
    ..deliveryAvailable = false
    ..county = 'Nairobi'
    ..subcounty = 'Westlands';
  data.verifiedPhotos.add(File('/photos/phone.jpg'));
  data.photoUploads.restore({'/photos/phone.jpg': 'photo-1'});
  return data;
}

/// A 360 x 800 phone, standing still so pumpAndSettle can settle.
Future<void> _open(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    routes: {'/premium': (_) => const Scaffold(body: Text('plans'))},
    home: screen,
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Where the step's scroll view shows its content, on screen.
Rect _viewport(WidgetTester tester) => tester.getRect(find
    .descendant(of: find.byType(SellStepScaffold), matching: find.byType(SingleChildScrollView))
    .first);

double _height(WidgetTester tester, String key) => tester.getSize(find.byKey(Key(key))).height;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ImagePickerPlatform.instance = _NothingLost();
  });

  group('Description step', () {
    testWidgets('a strip, with the description box on screen under it', (tester) async {
      await _open(tester, SellDescriptionScreen(data: _draft(), premium: _FakePremium(_me())));
      expect(_height(tester, 'sell-zeno-describe'), lessThan(160));
      expect(tester.getRect(find.byKey(const Key('sell-description-field'))).bottom,
          lessThanOrEqualTo(_viewport(tester).bottom),
          reason: 'the step itself, without scrolling past an advert');
    });

    testWidgets("locked: the plan's tag, Unlock, and the example opens with the plans", (tester) async {
      await _open(tester, SellDescriptionScreen(data: _draft(), premium: _FakePremium(_me())));
      expect(find.byKey(const Key('zeno-boost-badge')), findsOneWidget);
      expect(find.text('PREMIUM'), findsOneWidget);
      expect(find.text('Unlock'), findsOneWidget);
      // The example is the sheet's now, not the step's.
      expect(find.byKey(const Key('zeno-before-after')), findsNothing);

      // The pill is the strip's button too.
      await _tap(tester, find.byKey(const Key('zeno-boost-cta')));
      expect(find.byKey(const Key('upsell-message')), findsOneWidget);
      expect(find.byKey(const Key('zeno-before-after')), findsOneWidget);
      // The example for the item being sold: a phone.
      expect(find.textContaining('Galaxy A54'), findsOneWidget);
    });

    testWidgets("no plan's name while plans are off", (tester) async {
      await _open(tester, SellDescriptionScreen(data: _draft(), premium: _FakePremium(_me(enabled: false))));
      expect(find.byKey(const Key('zeno-boost-badge')), findsNothing);
      expect(find.text('PREMIUM'), findsNothing);
      expect(find.text('Write it'), findsOneWidget);
    });
  });

  group('Price step', () {
    testWidgets('a strip, with the asking price on screen under it', (tester) async {
      await _open(tester, SellPriceScreen(data: _draft(), premium: _FakePremium(_me(plan: 'plus', descriptions: 30))));
      expect(_height(tester, 'sell-zeno-price'), lessThan(160));
      expect(tester.getRect(find.byKey(const Key('sell-price-field'))).bottom,
          lessThanOrEqualTo(_viewport(tester).bottom));
    });

    testWidgets('without Pro: PRO on the strip, and the hidden range opens with the plans', (tester) async {
      await _open(tester, SellPriceScreen(data: _draft(), premium: _FakePremium(_me(plan: 'plus', descriptions: 30))));
      expect(find.text('PRO'), findsOneWidget);
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.byKey(const Key('zeno-locked-range')), findsNothing);
      await _tap(tester, find.byKey(const Key('sell-zeno-price')));
      expect(find.byKey(const Key('upsell-message')), findsOneWidget);
      expect(find.byKey(const Key('zeno-locked-range')), findsOneWidget);
    });

    testWidgets("no plan's name while plans are off", (tester) async {
      await _open(tester, SellPriceScreen(data: _draft(), premium: _FakePremium(_me(enabled: false))));
      expect(find.text('PRO'), findsNothing);
      expect(find.text('Price it'), findsOneWidget);
    });
  });

  group('Photos step', () {
    testWidgets("a free try: FIRST ONE FREE in the plan tag's place, and Try free", (tester) async {
      await _open(tester, SellPhotosScreen(premium: _FakePremium(_me(descriptions: 1))));
      expect(_height(tester, 'sell-zeno-autolist'), lessThan(160));
      expect(find.byKey(const Key('zeno-boost-ribbon')), findsOneWidget);
      expect(find.byKey(const Key('zeno-boost-badge')), findsNothing);
      expect(find.text('Try free'), findsOneWidget);
    });

    testWidgets('locked: the example opens with the plans', (tester) async {
      await _open(tester, SellPhotosScreen(premium: _FakePremium(_me())));
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.byKey(const Key('zeno-before-after')), findsNothing);
      await _tap(tester, find.byKey(const Key('sell-zeno-autolist')));
      expect(find.byKey(const Key('upsell-message')), findsOneWidget);
      expect(find.byKey(const Key('zeno-before-after')), findsOneWidget);
    });
  });

  group('The strip', () {
    Widget strip({required bool locked}) => SellZenoBoostCard(
          icon: Icons.auto_awesome_rounded,
          title: 'Let Zeno write it from your photo',
          benefit: 'Clear, detailed descriptions sell faster.',
          badge: 'PREMIUM',
          locked: locked,
          cta: locked ? 'Unlock' : 'Write it',
          onTap: () {},
        );

    testWidgets('its sweep of light plays once as it appears, and again for a new offer', (tester) async {
      var locked = false;
      late StateSetter rebuild;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: StatefulBuilder(builder: (context, setState) {
              rebuild = setState;
              return strip(locked: locked);
            }),
          ),
        ),
      ));
      expect(tester.hasRunningAnimations, isTrue, reason: 'it sweeps as it appears');
      // Settles: once, not a loop.
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);

      rebuild(() => locked = true);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue, reason: 'the plan loaded: a new offer');
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('stands still under reduced motion', (tester) async {
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(body: Padding(padding: const EdgeInsets.all(20), child: strip(locked: true))),
      ));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('Go live', () {
    testWidgets('says the listing fee right above GO LIVE', (tester) async {
      await _open(tester, SellZenoAlertScreen(
        data: _draft(),
        question: 'Hello Wanjiku! So you never miss a sale: if a buyer messages about '
            '"Samsung Galaxy A54" and you\'re not around, may I text your phone?',
        feeRepository: _fees(),
      ));
      final fee = tester.getRect(find.byKey(const Key('sell-fee-teaser')));
      final goLive = tester.getRect(find.byKey(const Key('sell-go-live')));
      expect(fee.bottom, lessThanOrEqualTo(goLive.top));
      expect(goLive.top - fee.bottom, lessThan(24),
          reason: 'beside the button, not under everything else in the scroll');
      expect(find.textContaining('Listing fee KES 84 for 2 months'), findsOneWidget);
    });

    testWidgets('the availability text is free - no plans strip on Go live',
        (tester) async {
      await _open(tester, SellZenoAlertScreen(
        data: _draft(),
        question: 'Shall I text you?',
        feeRepository: _fees(enabled: false),
      ));
      expect(find.byKey(const Key('sell-sms-plans')), findsNothing);
      expect(find.byKey(const Key('sell-sms-preview')), findsNothing);
      expect(find.textContaining('One text per buyer'), findsOneWidget);
      expect(find.byKey(const Key('sell-fee-teaser')), findsNothing, reason: 'fees are off');
    });
  });
}
