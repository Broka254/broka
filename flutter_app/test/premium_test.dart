// BROKA Premium in the app (PRICING.md section 4): the plans and where the
// user stands as the server sends them, buying a plan, and what a refused
// premium feature does.
//
// What must hold:
//   * the Premium screen shows the plan running and what is left of it, or
//     the free AI cover tries of someone without one;
//   * Continue goes to the payment methods, then the M-Pesa screen, which
//     asks for the plan and months chosen, under one key per attempt, and
//     waits for M-Pesa rather than assuming;
//   * a cheaper plan than the one running is not offered for payment - the
//     server would refuse it - and the screen says when it can be;
//   * with plans off, nothing is sold;
//   * the AI cover step says how many tries are left; with none left it
//     offers the plans instead of asking the server again, and a refusal
//     the app didn't see coming shows the server's words and the plans;
//   * Go live says, before the seller answers, that texts need a plan.
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/premium/data/premium_repository.dart';
import 'package:broka/features/premium/domain/premium.dart';
import 'package:broka/features/premium/presentation/premium_screen.dart';
import 'package:broka/features/premium/presentation/premium_upsell.dart';
import 'package:broka/screens/sell_showcase_screen.dart';
import 'package:broka/screens/sell_zeno_alert_screen.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/services/photo_upload_tracker.dart';
import 'package:broka/services/sell_wizard_data.dart';
import 'package:broka/services/showcase_generator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// period_prices() for a plan: [monthly, 3 months, 6, 12], as plans.py
/// rounds them.
List<Map<String, dynamic>> _periods(List<int> totals) => [
      for (final (i, months) in const [1, 3, 6, 12].indexed)
        {
          'months': months, 'total': totals[i], 'per_month': totals[i] / months,
          'saving_percent': (100 * (1 - totals[i] / (totals[0] * months))).round(),
        },
    ];

/// GET /pricing/plans, as plans.py builds it (the premium part).
Map<String, dynamic> _catalog() => {
      'premium': [
        {
          'id': 'plus', 'name': 'Plus', 'pitch': 'For the occasional buyer and seller.', 'monthly_price': 169,
          'periods': _periods([169, 469, 859, 1619]),
          'allowances': {'voice_requests': 90, 'sms_alerts': 30, 'agent_watches': 1, 'auto_negotiations': 0,
            'ai_covers': 6, 'ai_cover_listings': 2, 'auctions_hosted': 0, 'priority_support_minutes': 0},
        },
        {
          'id': 'pro', 'name': 'Pro', 'pitch': 'For regular sellers.', 'monthly_price': 499,
          'periods': _periods([499, 1379, 2539, 4789]),
          'allowances': {'voice_requests': 180, 'sms_alerts': 80, 'agent_watches': 3, 'auto_negotiations': 25,
            'ai_covers': 20, 'ai_cover_listings': 7, 'auctions_hosted': 2, 'priority_support_minutes': 0},
        },
        {
          'id': 'elite', 'name': 'Elite', 'pitch': 'For full-time traders.', 'monthly_price': 1249,
          'periods': _periods([1249, 3449, 6369, 11989]),
          'allowances': {'voice_requests': 360, 'sms_alerts': 150, 'agent_watches': 10, 'auto_negotiations': 50,
            'ai_covers': 60, 'ai_cover_listings': 20, 'auctions_hosted': 5, 'priority_support_minutes': 15},
        },
      ],
    };

Map<String, dynamic> _usage(Map<String, List<int>> spent) => {
      for (final e in spent.entries)
        e.key: {'allowance': e.value[0], 'used': e.value[1], 'left': e.value[0] - e.value[1]},
    };

/// GET /premium/me, as entitlements.summary builds it.
Map<String, dynamic> _me({String? plan, int coversLeft = 2, int smsLeft = 0, bool enabled = true}) {
  if (!enabled) {
    return {'enabled': false, 'plan': null, 'paid_until': null, 'renews_at': null, 'usage': {}, 'trial': {}};
  }
  if (plan == 'pro') {
    return {
      'enabled': true,
      'plan': {'id': 'pro', 'name': 'Pro', 'monthly_price': 499},
      'paid_until': '2026-11-20T08:00:00',
      'renews_at': '2026-10-21T08:00:00',
      'priority_support': false,
      'usage': _usage({
        'voice_requests': [180, 20], 'sms_alerts': [80, 80 - smsLeft], 'auto_negotiations': [25, 5],
        'ai_covers': [20, 20 - coversLeft], 'auctions_hosted': [2, 0], 'agent_watches': [3, 1],
      }),
      'trial': {},
      'ai_cover_tries_per_listing': 3,
    };
  }
  return {
    'enabled': true, 'plan': null, 'paid_until': null, 'renews_at': null, 'priority_support': false,
    'usage': _usage({
      'voice_requests': [0, 0], 'sms_alerts': [0, 0], 'auto_negotiations': [0, 0],
      'ai_covers': [2, 2 - coversLeft], 'auctions_hosted': [0, 0], 'agent_watches': [0, 0],
    }),
    'trial': {'ai_covers': coversLeft},
    'ai_cover_tries_per_listing': 3,
  };
}

/// The premium endpoints: records what was bought, and answers the status
/// poll with [statuses] in turn.
class _PremiumBackend {
  _PremiumBackend({Map<String, dynamic>? me, List<String>? statuses})
      : me = me ?? _me(),
        statuses = statuses ?? ['pending', 'success'];

  Map<String, dynamic> me;
  final List<String> statuses;
  final subscribes = <Map<String, dynamic>>[];
  final keys = <String?>[];
  var meCalls = 0;
  var polls = 0;

  PremiumRepository get repository => PremiumRepository(client: ApiClient(client: MockClient((req) async {
        final path = req.url.path;
        if (path == '/premium/me') {
          meCalls++;
          return _json(me);
        }
        if (path == '/pricing/plans') return _json(_catalog());
        if (path == '/premium/subscribe') {
          subscribes.add(jsonDecode(req.body) as Map<String, dynamic>);
          keys.add(req.headers['X-Idempotency-Key']);
          return _json({'payment_id': 'sp1', 'status': 'pending', 'plan_id': 'pro', 'months': 3, 'amount': 1379});
        }
        if (path == '/premium/payments/sp1') {
          final status = statuses[polls < statuses.length ? polls : statuses.length - 1];
          polls++;
          return _json({
            'payment_id': 'sp1', 'status': status, 'plan_id': 'pro', 'months': 3, 'amount': 1379,
            'failure_reason': status == 'failed' ? 'Request cancelled by user' : null,
            'paid_until': status == 'success' ? '2026-12-26T10:00:00' : null,
          });
        }
        return _json({'detail': 'Not found'}, 404);
      })));
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
  await tester.pump();
}

const _poll = Duration(milliseconds: 100);

/// Continue -> pick M-Pesa -> the M-Pesa screen, with [phone] typed in.
Future<void> _toMpesa(WidgetTester tester, String phone) async {
  await _tap(tester, find.byKey(const Key('premium-continue')));
  await tester.pumpAndSettle();
  await _tap(tester, find.byKey(const Key('method-mpesa')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('mpesa-phone')), phone);
}

SellWizardData _draft() {
  final data = SellWizardData(photoUploads: PhotoUploadTracker(service: _FakeUploader()))
    ..name = 'Dry maize'
    ..category = 'Agriculture'
    ..categoryId = 'agri'
    ..subcategoryId = 'grains'
    ..description = 'Dry maize from this season, clean bags.'
    ..price = '3500'
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

  group('What the server says', () {
    test('a plan, what is left, and the free tries', () {
      final pro = PremiumStatus.fromJson(_me(plan: 'pro', coversLeft: 7));
      expect(pro.hasPlan, isTrue);
      expect(pro.planName, 'Pro');
      expect(pro.left(PremiumFeature.aiCovers), 7);
      expect(pro.paidUntil, DateTime.utc(2026, 11, 20, 8).toLocal());

      final free = PremiumStatus.fromJson(_me(coversLeft: 0));
      expect(free.hasPlan, isFalse);
      expect(free.canUse(PremiumFeature.aiCovers), isFalse);
      expect(free.canUse(PremiumFeature.voice), isFalse);

      final off = PremiumStatus.fromJson(_me(enabled: false));
      expect(off.canUse(PremiumFeature.voice), isTrue, reason: 'with plans off everything is free');
    });

    test('the plans, with their periods and what the cover tries come to', () {
      final plans = [for (final p in _catalog()['premium'] as List) PremiumPlan.fromJson(p)];
      expect(plans.map((p) => p.monthlyPrice), [169, 499, 1249]);
      expect(plans[1].allowance(PremiumFeature.aiCovers), 20);
      expect(plans[1].aiCoverListings, 7);
      expect(plans[1].period(12)!.savingPercent, 20);
      expect(plans[2].prioritySupportMinutes, 15);
    });

    test("a plan refusal keeps the plan that would do", () async {
      final client = ApiClient(client: MockClient((_) async => _json({
            'detail': {'code': 'PREMIUM_REQUIRED', 'message': 'Voice mode is part of BROKA Plus.',
              'feature': 'voice_requests', 'plan': null, 'upgrade_to': 'plus'},
          }, 402)));
      try {
        await client.post('/zeno/assistant/turn', {'message': 'hi', 'mode': 'voice'});
        fail('a 402 is an error');
      } on ApiException catch (e) {
        expect(isPlanRefusal(e.statusCode), isTrue);
        expect(e.message, 'Voice mode is part of BROKA Plus.');
        expect(e.code, 'PREMIUM_REQUIRED');
        expect(upgradeToOf(e), 'plus');
      }
    });
  });

  group('Premium screen', () {
    testWidgets('no plan: the free tries, the plans, and the suggested one picked', (tester) async {
      final backend = _PremiumBackend();
      await _open(tester, PremiumScreen(highlight: 'pro', repository: backend.repository));
      expect(find.byKey(const Key('premium-trial')), findsOneWidget);
      expect(find.text('You have 2 free AI cover tries left.'), findsOneWidget);
      for (final id in ['plus', 'pro', 'elite']) {
        expect(find.byKey(Key('premium-plan-$id')), findsOneWidget);
      }
      final pro = tester.widget<Semantics>(find.descendant(
          of: find.byKey(const Key('premium-plan-pro')), matching: find.byType(Semantics)).first);
      expect(pro.properties.selected, isTrue);
      expect(find.text('20 AI cover tries - covers for about 7 listings'), findsOneWidget);
      expect(find.text('Continue to payment · KES 499'), findsOneWidget);
    });

    testWidgets('pays for the plan and months chosen, then waits for M-Pesa', (tester) async {
      final backend = _PremiumBackend();
      await _open(tester, PremiumScreen(repository: backend.repository, pollEvery: _poll));
      await _tap(tester, find.byKey(const Key('premium-plan-pro')));
      await _tap(tester, find.byKey(const Key('premium-months-3')));
      expect(find.text('Continue to payment · KES 1,379'), findsOneWidget);
      await _toMpesa(tester, '0712 345 678');
      expect(find.text('Pay KES 1,379'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      await tester.pump();
      expect(find.byKey(const Key('checkout-waiting')), findsOneWidget);
      expect(backend.subscribes.single, {'plan_id': 'pro', 'months': 3, 'phone_number': '0712 345 678'});
      expect(backend.keys.single, isNotNull);

      await tester.pump(_poll); // pending
      expect(find.byKey(const Key('checkout-waiting')), findsOneWidget);
      await tester.pump(_poll); // success
      await tester.pump();
      expect(find.byKey(const Key('checkout-paid')), findsOneWidget);
      expect(find.text("You're on BROKA Pro"), findsOneWidget);
      expect(find.text('Paid until 26 Dec 2026.'), findsOneWidget);
    });

    testWidgets('a cancelled prompt says so and Pay is there again', (tester) async {
      final backend = _PremiumBackend(statuses: ['failed']);
      await _open(tester, PremiumScreen(repository: backend.repository, pollEvery: _poll));
      await _toMpesa(tester, '0712345678');
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      await tester.pump();
      await tester.pump(_poll);
      await tester.pump();
      expect(find.byKey(const Key('checkout-error')), findsOneWidget);
      expect(find.byKey(const Key('mpesa-pay')), findsOneWidget);
    });

    testWidgets('on a plan: what is left, and a cheaper plan waits for it to end', (tester) async {
      final backend = _PremiumBackend(me: _me(plan: 'pro', coversLeft: 7));
      await _open(tester, PremiumScreen(repository: backend.repository));
      expect(find.byKey(const Key('premium-usage')), findsOneWidget);
      expect(find.text('7 of 20 left'), findsOneWidget);
      expect(find.text('1 of 3 running'), findsOneWidget, reason: 'watches are held at once, not spent');
      expect(find.text('Your plan'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('premium-plan-plus')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('premium-downgrade-note')), findsOneWidget);
      expect(find.textContaining('You can move to Plus when it ends'), findsOneWidget);
      expect(find.byKey(const Key('premium-continue')), findsNothing);

      await _tap(tester, find.byKey(const Key('premium-plan-elite')));
      await tester.pumpAndSettle();
      expect(find.textContaining('unused Pro days become Elite days'), findsOneWidget);
      expect(find.byKey(const Key('premium-continue')), findsOneWidget);
    });

    testWidgets('with plans off, nothing is sold', (tester) async {
      final backend = _PremiumBackend(me: _me(enabled: false));
      await _open(tester, PremiumScreen(repository: backend.repository));
      expect(find.byKey(const Key('premium-off')), findsOneWidget);
      expect(find.byKey(const Key('premium-continue')), findsNothing);
    });

    testWidgets('a number too short to be one is caught before any prompt', (tester) async {
      final backend = _PremiumBackend();
      await _open(tester, PremiumScreen(repository: backend.repository));
      await _toMpesa(tester, '0712');
      await _tap(tester, find.byKey(const Key('mpesa-pay')));
      expect(find.byKey(const Key('checkout-error')), findsOneWidget);
      expect(backend.subscribes, isEmpty);
    });
  });

  group('A refused feature', () {
    testWidgets('"See plans" opens the plans with the suggested one', (tester) async {
      Object? opened;
      await _open(
        tester,
        Builder(builder: (context) => TextButton(
              onPressed: () => showPremiumUpsell(context, message: 'Voice mode is part of BROKA Plus.',
                  upgradeTo: 'plus'),
              child: const Text('talk'),
            )),
        routes: {
          '/premium': (ctx) {
            opened = ModalRoute.of(ctx)?.settings.arguments;
            return const Scaffold(body: Text('plans'));
          },
        },
      );
      await tester.tap(find.text('talk'));
      await tester.pumpAndSettle();
      expect(find.text('Voice mode is part of BROKA Plus.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('upsell-see-plans')));
      await tester.pumpAndSettle();
      expect(find.text('plans'), findsOneWidget);
      expect(opened, 'plus');
    });
  });

  group('AI cover step', () {
    testWidgets('says how many free tries are left', (tester) async {
      final backend = _PremiumBackend(me: _me(coversLeft: 2));
      await _open(tester, SellShowcaseScreen(
          data: _draft(), generator: _FakeGenerator(), premium: backend.repository));
      expect(find.byKey(const Key('showcase-tries-left')), findsOneWidget);
      expect(find.text('2 free AI cover tries left'), findsOneWidget);
    });

    testWidgets('with none left, offers the plans without asking for a cover', (tester) async {
      final backend = _PremiumBackend(me: _me(coversLeft: 0));
      final generator = _FakeGenerator();
      await _open(
        tester,
        SellShowcaseScreen(data: _draft(), generator: generator, premium: backend.repository),
        routes: {'/premium': (_) => const Scaffold(body: Text('plans'))},
      );
      expect(find.text('🔒  Get more AI covers'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('showcase-generate')));
      await tester.pumpAndSettle();
      expect(generator.calls, isEmpty, reason: 'the server would only refuse it');
      expect(find.textContaining("You've used your free AI cover tries"), findsOneWidget);
      expect(find.textContaining('upload a cover from your gallery, free'), findsOneWidget);
    });

    testWidgets("a refusal the app didn't expect shows the server's words and the plans", (tester) async {
      // Two tries left on this phone's last look; the other phone spent them.
      final backend = _PremiumBackend(me: _me(plan: 'pro', coversLeft: 2));
      final generator = _FakeGenerator(error: const ApiException(402,
          "You've used this month's 20 AI cover tries on BROKA Pro.", code: 'ALLOWANCE_USED',
          details: {'code': 'ALLOWANCE_USED', 'upgrade_to': 'elite'}));
      await _open(tester, SellShowcaseScreen(data: _draft(), generator: generator, premium: backend.repository));
      expect(find.text('2 of 20 AI cover tries left this month'), findsOneWidget);
      backend.me = _me(plan: 'pro', coversLeft: 0);
      await _tap(tester, find.byKey(const Key('showcase-generate')));
      await tester.pumpAndSettle();
      expect(generator.calls, hasLength(1));
      expect(tester.widget<Text>(find.byKey(const Key('upsell-message'))).data,
          "You've used this month's 20 AI cover tries on BROKA Pro.");
      await tester.tap(find.byKey(const Key('upsell-not-now')));
      await tester.pumpAndSettle();
      expect(find.text('0 of 20 AI cover tries left this month'), findsOneWidget,
          reason: 'the count is fetched again after a refusal');
      expect(find.text('🔒  Get more AI covers'), findsOneWidget);
    });

    testWidgets('with plans off, nothing about tries', (tester) async {
      final backend = _PremiumBackend(me: _me(enabled: false));
      await _open(tester, SellShowcaseScreen(
          data: _draft(), generator: _FakeGenerator(), premium: backend.repository));
      expect(find.byKey(const Key('showcase-tries-left')), findsNothing);
      expect(find.textContaining('Create my'), findsOneWidget);
    });
  });

  group('Go live', () {
    testWidgets('says before the answer that texts need a plan', (tester) async {
      final backend = _PremiumBackend(me: _me());
      await _open(tester, SellZenoAlertScreen(
          data: _draft(), question: 'Shall I text you?', premiumRepository: backend.repository));
      expect(find.textContaining('Texts come with a BROKA plan'), findsOneWidget);
      expect(find.byKey(const Key('sell-sms-plans')), findsOneWidget);
    });

    testWidgets('a plan with texts left: as before', (tester) async {
      final backend = _PremiumBackend(me: _me(plan: 'pro', smsLeft: 40));
      await _open(tester, SellZenoAlertScreen(
          data: _draft(), question: 'Shall I text you?', premiumRepository: backend.repository));
      expect(find.textContaining('Texts come with a BROKA plan'), findsNothing);
      expect(find.byKey(const Key('sell-sms-plans')), findsNothing);
    });
  });
}

class _FakeGenerator extends ShowcaseGenerator {
  _FakeGenerator({this.error});
  final ApiException? error;
  final calls = <String>[];

  @override
  Future<GeneratedCover> generate({
    required String photoId,
    required String name,
    required String category,
    required String theme,
    String? condition,
    String? note,
  }) async {
    calls.add(theme);
    if (error != null) throw error!;
    return const GeneratedCover(assetId: 'cover-1', previewUrl: '/m/cover-1', largeUrl: '/l/cover-1');
  }
}

class _FakeUploader extends ImageUploadService {
  @override
  Future<UploadedImage> uploadFile(File file,
          {required String purpose, void Function(double fraction)? onProgress}) async =>
      const UploadedImage(id: 'photo-1', thumb: '/t', medium: '/m', large: '/l');
}
