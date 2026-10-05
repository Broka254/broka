// Zeno's premium help in the sell wizard (2026-10-05), and the case the
// wizard makes for a plan while a seller is posting.
//
// What must hold:
//   * the Description step offers Zeno writing it from the photo, says why
//     (a clear description sells faster), and - without a plan - opens the
//     plans instead of asking the server;
//   * with a plan, Zeno's description lands in the seller's box with the
//     draft and the photo's id sent, and the box stays editable;
//   * a 402 the app didn't expect shows the server's words and the plans;
//   * the Price step offers pricing with Zeno, marked PRO, and opens the
//     plans without it; with Pro it opens Zeno's screen and takes back the
//     price the seller chose;
//   * Zeno's pricing screen opens with a question, offers the BROKA check
//     once, shows what it found, and hands the chosen price back;
//   * the cover step says what a cover does for the sale.
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/premium/data/premium_repository.dart';
import 'package:broka/features/premium/domain/premium.dart';
import 'package:broka/features/zeno_assistant/data/zeno_selling_repository.dart';
import 'package:broka/features/zeno_assistant/domain/zeno_selling.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_pricing_screen.dart';
import 'package:broka/screens/sell_description_screen.dart';
import 'package:broka/screens/sell_price_screen.dart';
import 'package:broka/screens/sell_showcase_screen.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/services/photo_upload_tracker.dart';
import 'package:broka/services/sell_wizard_data.dart';
import 'package:broka/services/showcase_generator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _allowance(int allowance, int used) =>
    {'allowance': allowance, 'used': used, 'left': allowance - used};

/// GET /premium/me, as entitlements.summary builds it.
PremiumStatus _me({
  String? plan,
  int descriptions = 0,
  int descriptionsUsed = 0,
  int checks = 0,
  bool enabled = true,
}) =>
    PremiumStatus.fromJson({
      'enabled': enabled,
      'plan': plan == null ? null : {'id': plan, 'name': plan == 'pro' ? 'Pro' : 'Plus', 'monthly_price': 599},
      'renews_at': '2026-10-21T08:00:00',
      'usage': {
        'ai_descriptions': _allowance(descriptions, descriptionsUsed),
        'price_checks': _allowance(checks, 0),
        'ai_covers': _allowance(plan == null ? 1 : 20, 0),
      },
      'trial': {'ai_covers': 1},
    });

class _FakePremium extends PremiumRepository {
  _FakePremium(this.status);
  PremiumStatus status;
  var calls = 0;

  @override
  Future<Result<PremiumStatus>> me() async {
    calls++;
    return Success(status);
  }
}

class _FakeSelling extends ZenoSellingRepository {
  _FakeSelling({this.description = 'A clean phone.\nBattery health:', this.error, this.turns});

  final String description;
  final ApiException? error;

  /// Answers for successive priceTurn calls.
  final List<ZenoPriceTurn>? turns;

  final describeCalls = <Map<String, dynamic>>[];
  final priceCalls = <Map<String, dynamic>>[];

  @override
  Future<String> describe({
    required Map<String, dynamic> draft,
    required String photoId,
    required String language,
  }) async {
    describeCalls.add({'draft': draft, 'photo_id': photoId, 'language': language});
    if (error != null) throw error!;
    return description;
  }

  @override
  Future<ZenoPriceTurn> priceTurn({
    required Map<String, dynamic> draft,
    required String message,
    required List<Map<String, String>> history,
    required String language,
    bool research = false,
  }) async {
    priceCalls.add({'message': message, 'research': research, 'history': history, 'draft': draft});
    if (error != null) throw error!;
    final answers = turns ?? const [];
    return answers.isEmpty
        ? const ZenoPriceTurn(reply: 'Ask 30,000.', suggestedPrice: 30000)
        : answers[priceCalls.length <= answers.length ? priceCalls.length - 1 : answers.length - 1];
  }
}

class _FakeUploader extends ImageUploadService {
  @override
  Future<UploadedImage> uploadFile(File file,
          {required String purpose, void Function(double fraction)? onProgress}) async =>
      const UploadedImage(id: 'photo-1', thumb: '/t', medium: '/m', large: '/l');
}

class _FakeGenerator extends ShowcaseGenerator {
  @override
  Future<GeneratedCover> generate({
    required String photoId,
    required String name,
    required String category,
    required String theme,
    String? condition,
    String? note,
  }) async =>
      const GeneratedCover(assetId: 'cover-1', previewUrl: '/m/cover-1', largeUrl: '/l/cover-1');
}

SellWizardData _draft() {
  final data = SellWizardData(photoUploads: PhotoUploadTracker(service: _FakeUploader()))
    ..name = 'Samsung Galaxy A54'
    ..category = 'Electronics'
    ..categoryId = 'elec'
    ..subcategoryName = 'Phones'
    ..condition = 'used'
    ..price = '40000'
    ..priceNegotiable = true;
  data.attributes['storage'] = '128GB';
  data.verifiedPhotos.add(File('/photos/phone.jpg'));
  data.photoUploads.restore({'/photos/phone.jpg': 'photo-1'});
  return data;
}

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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Description step', () {
    testWidgets('offers Zeno, and says what it does for the sale', (tester) async {
      await _open(tester, SellDescriptionScreen(
          data: _draft(), premium: _FakePremium(_me(plan: 'plus', descriptions: 30)),
          selling: _FakeSelling()));
      expect(find.byKey(const Key('sell-zeno-describe')), findsOneWidget);
      expect(find.text('Let Zeno write it from your photo'), findsOneWidget);
      expect(find.textContaining('sell faster'), findsOneWidget);
      expect(find.text('30 of 30 left this month'), findsOneWidget);
    });

    testWidgets('without a plan it offers the plans, not the server', (tester) async {
      final selling = _FakeSelling();
      await _open(
        tester,
        SellDescriptionScreen(data: _draft(), premium: _FakePremium(_me()), selling: selling),
        routes: {'/premium': (_) => const Scaffold(body: Text('plans'))},
      );
      await _tap(tester, find.byKey(const Key('sell-zeno-describe')));
      expect(selling.describeCalls, isEmpty, reason: 'the server would only refuse it');
      expect(tester.widget<Text>(find.byKey(const Key('upsell-message'))).data,
          contains('sell faster'));
      await _tap(tester, find.byKey(const Key('upsell-see-plans')));
      expect(find.text('plans'), findsOneWidget);
    });

    testWidgets('writes into the seller\'s own box, with the draft and the photo', (tester) async {
      final selling = _FakeSelling();
      final data = _draft();
      await _open(tester, SellDescriptionScreen(
          data: data, premium: _FakePremium(_me(plan: 'plus', descriptions: 30)), selling: selling));
      await tester.enterText(find.byKey(const Key('sell-description-field')), 'Bought it last year');
      await tester.pump();
      await _tap(tester, find.byKey(const Key('sell-zeno-describe')));

      expect(selling.describeCalls, hasLength(1));
      final sent = selling.describeCalls.single;
      expect(sent['photo_id'], 'photo-1');
      final draft = sent['draft'] as Map<String, dynamic>;
      expect(draft['name'], 'Samsung Galaxy A54');
      expect(draft['attributes'], {'storage': '128GB'});
      // What the seller had already written goes with it, so Zeno keeps it.
      expect(draft['description'], 'Bought it last year');

      expect(tester.widget<TextFormField>(find.byKey(const Key('sell-description-field')))
          .controller?.text, 'A clean phone.\nBattery health:');
      expect(data.description, 'A clean phone.\nBattery health:');
      // Still the seller's to finish.
      await tester.enterText(find.byKey(const Key('sell-description-field')), 'A clean phone. 128GB.');
      await tester.pump();
      expect(data.description, 'A clean phone. 128GB.');
    });

    testWidgets("a refusal the app didn't expect shows the server's words", (tester) async {
      final selling = _FakeSelling(error: const ApiException(402,
          "You've used this month's 30 descriptions by Zeno on BROKA Plus.",
          code: 'ALLOWANCE_USED', details: {'upgrade_to': 'pro'}));
      await _open(tester, SellDescriptionScreen(
          data: _draft(), premium: _FakePremium(_me(plan: 'plus', descriptions: 30)), selling: selling));
      await _tap(tester, find.byKey(const Key('sell-zeno-describe')));
      expect(selling.describeCalls, hasLength(1));
      expect(tester.widget<Text>(find.byKey(const Key('upsell-message'))).data,
          "You've used this month's 30 descriptions by Zeno on BROKA Plus.");
    });
  });

  group('Price step', () {
    testWidgets('offers pricing with Zeno as a Pro feature', (tester) async {
      await _open(tester, SellPriceScreen(
          data: _draft(), premium: _FakePremium(_me(plan: 'pro', checks: 40))));
      expect(find.text('Price it to sell with Zeno'), findsOneWidget);
      expect(find.textContaining('sell faster'), findsOneWidget);
      expect(find.text('40 of 40 price checks left this month'), findsOneWidget);
    });

    testWidgets('without Pro it offers Pro', (tester) async {
      var opened = false;
      await _open(tester, SellPriceScreen(
        data: _draft(),
        premium: _FakePremium(_me(plan: 'plus', descriptions: 30)),
        openPricing: (_, __) async {
          opened = true;
          return null;
        },
      ));
      await _tap(tester, find.byKey(const Key('sell-zeno-price')));
      expect(opened, isFalse);
      expect(tester.widget<Text>(find.byKey(const Key('upsell-message'))).data,
          contains('BROKA Pro'));
    });

    testWidgets('takes back the price the seller chose with Zeno', (tester) async {
      final data = _draft();
      await _open(tester, SellPriceScreen(
        data: data,
        premium: _FakePremium(_me(plan: 'pro', checks: 40)),
        openPricing: (_, draft) async {
          // The draft reaches Zeno as typed so far.
          expect(draft.price, '40000');
          return 32000;
        },
      ));
      await _tap(tester, find.byKey(const Key('sell-zeno-price')));
      expect(find.text('32,000'), findsOneWidget);
      expect(data.price, '32000');
    });
  });

  group("Zeno's pricing screen", () {
    testWidgets('opens with the question and offers the BROKA check once', (tester) async {
      final selling = _FakeSelling(turns: [
        const ZenoPriceTurn(reply: 'Around KES 30,000, but let me check.',
            suggestedPrice: 30000, offerResearch: true),
        ZenoPriceTurn(
          reply: 'Three similar ones ask 28-33K. I would ask 31,000.',
          suggestedPrice: 31000,
          comparables: ZenoComparables.fromJson(const {
            'count': 3, 'low': 28000, 'median': 30000, 'high': 33000, 'listings': [],
          }),
        ),
      ]);
      await _open(tester, ZenoPricingScreen(
          data: _draft(), repository: selling, animateBackground: false));

      // Zeno is asked the moment the screen opens - the seller came for a
      // number, not for a blank chat.
      expect(selling.priceCalls, hasLength(1));
      expect(selling.priceCalls.first['message'], contains('Samsung Galaxy A54'));
      expect(selling.priceCalls.first['research'], isFalse);
      expect(find.byKey(const Key('zeno-pricing-draft')), findsOneWidget);
      expect(find.text('Around KES 30,000, but let me check.'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('zeno-check-broka')));
      expect(selling.priceCalls, hasLength(2));
      expect(selling.priceCalls.last['research'], isTrue);
      expect(find.byKey(const Key('zeno-comparables')), findsOneWidget);
      expect(find.text('3 similar listings on BROKA'), findsOneWidget);
      expect(find.text('KES 28,000'), findsOneWidget);
      // Never offered twice: a second check would spend another.
      expect(find.byKey(const Key('zeno-check-broka')), findsNothing);
    });

    testWidgets('hands the chosen price back to the wizard', (tester) async {
      int? chosen;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                chosen = await Navigator.of(context).push<int>(MaterialPageRoute(
                    builder: (_) => ZenoPricingScreen(
                        data: _draft(), repository: _FakeSelling(), animateBackground: false)));
              },
              child: const Text('price it'),
            ),
          ),
        ),
      ));
      await _tap(tester, find.text('price it'));
      await _tap(tester, find.byKey(const Key('zeno-use-price-30000')));
      expect(chosen, 30000);
    });

    testWidgets('a refusal shows the plans', (tester) async {
      final selling = _FakeSelling(error: const ApiException(402,
          'Pricing your listing with Zeno is part of BROKA Pro - from KES 599 a month.',
          code: 'PREMIUM_REQUIRED', details: {'upgrade_to': 'pro'}));
      await _open(tester, ZenoPricingScreen(
          data: _draft(), repository: selling, animateBackground: false));
      expect(tester.widget<Text>(find.byKey(const Key('upsell-message'))).data,
          contains('BROKA Pro'));
    });
  });

  group('Cover step', () {
    testWidgets('says what a cover does for the sale', (tester) async {
      await _open(tester, SellShowcaseScreen(
          data: _draft(), generator: _FakeGenerator(), premium: _FakePremium(_me(plan: 'pro'))));
      expect(find.byKey(const Key('showcase-sells-faster')), findsOneWidget);
      expect(find.textContaining('faster sale'), findsOneWidget);
      expect(find.textContaining('A cover that stands out gets more taps'), findsOneWidget);
    });
  });
}
