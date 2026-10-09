// Paying safely while BROKA handles no deal payments (backend:
// GET /pricing/safe-payment). The pay button must lead to escrow and advice,
// not to a payment form the server refuses; the escrow services must be
// marked as independent, and Zeno offered to guide; and the explainer must
// stop describing a payment buyers can't make - including while it is
// still finding out.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/features/safe_payment/payments_shown.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/escrow/data/repositories/escrow_repository.dart';
import 'package:broka/features/escrow/presentation/escrow_actions.dart';
import 'package:broka/features/safe_payment/escrow_callout.dart';
import 'package:broka/features/safe_payment/escrow_services_screen.dart';
import 'package:broka/features/safe_payment/safe_payment.dart';
import 'package:broka/screens/auction_screen.dart';
import 'package:broka/screens/how_broka_works_screen.dart';
import 'package:broka/services/api_service.dart';

import 'support/fake_api.dart';

const _info = SafePaymentInfo(
  inAppPayments: false,
  message: 'Paying through BROKA is paused.',
  advice: ['Meet in a busy public place and check the item works before you pay.'],
  providers: [EscrowProvider(name: 'Kenya Escrow', url: 'https://www.kenyaescrow.com', note: 'Holds the money.')],
  disclaimer: "These are independent services. BROKA doesn't run them.",
);

class _FakeSafePayment extends SafePaymentRepository {
  _FakeSafePayment(this.info);
  final SafePaymentInfo? info;

  @override
  Future<SafePaymentInfo?> fetch() async => info;
}

class _PaymentsOff extends EscrowRepository {
  @override
  Future<Result<Map<String, dynamic>>> feeQuote(String dealId, {double? amount}) async =>
      const Failure('Paying through BROKA is paused.', statusCode: 409, code: paymentsOffCode);
}

void main() {
  // Written for a build that shows payments. The default build hides them
  // (payments_shown.dart): see the "payments hidden" tests.
  setUpAll(() => paymentsShown = true);
  tearDownAll(() => paymentsShown = false);

  setUpAll(installFakeApi);

  testWidgets('the pay button opens the safe-paying advice instead of a payment form', (tester) async {
    bool? opened;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () async => opened = await showEscrowPayDialog(context,
              dealId: 'd1', repository: _PaymentsOff(), safePayment: _FakeSafePayment(_info)),
          child: const Text('open'),
        ),
      )),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Pay safely with escrow'), findsOneWidget);
    expect(find.text('Kenya Escrow'), findsOneWidget);
    expect(find.textContaining('independent'), findsOneWidget);
    expect(find.text('Let Zeno guide me, step by step'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'no payment form');

    await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
    await tester.pumpAndSettle();
    expect(opened, isFalse);
  });

  testWidgets('a provider opens in the browser', (tester) async {
    final urls = <Uri>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SafePaymentView(info: _info, openUrl: (u) async { urls.add(u); return true; }),
    )));
    await tester.tap(find.text('Kenya Escrow'));
    expect(urls, [Uri.parse('https://www.kenyaescrow.com')]);
  });

  testWidgets('without the server, the services and the core advice still show', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SafePaymentView(info: null))));
    expect(find.textContaining('check the item works before you pay'), findsOneWidget);
    // By name and address: fees come from the server or not at all.
    expect(find.text('Escrow services'), findsOneWidget);
    expect(find.text('E-Confirm'), findsOneWidget);
    expect(find.text('Shikilia'), findsOneWidget);
  });

  Future<void> scrollTo(WidgetTester tester, Finder f) =>
      tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);

  testWidgets('How BROKA works explains paying with escrow, not BROKA escrow, while payments are off', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HowBrokaWorksScreen(repository: _FakeSafePayment(_info))));
    // The ambient background never settles: pump past the fetch and the fade-in.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Buying on BROKA'), findsOneWidget);
    await scrollTo(tester, find.text('Pay safely with escrow'));
    expect(find.text('Pay safely with escrow'), findsOneWidget);
    expect(find.byType(EscrowCallout), findsOneWidget);
    expect(find.text('Escrow: how money moves'), findsNothing);
    await scrollTo(tester, find.text('Zeno, on your side'));
    expect(find.textContaining('walks you through paying with escrow one step at a time'), findsOneWidget);
  });

  // It showed "The buyer pays BROKA... BROKA holds it" until the server
  // answered - and for good when it couldn't be reached.
  testWidgets("before the server answers - or if it can't - it never says BROKA holds the money", (tester) async {
    await tester.pumpWidget(MaterialApp(home: HowBrokaWorksScreen(repository: _FakeSafePayment(null))));
    await tester.pump(const Duration(seconds: 1));
    await scrollTo(tester, find.text('Pay safely with escrow'));
    expect(find.text('Escrow: how money moves'), findsNothing);
  });

  testWidgets('...and escrow again once payments are back', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HowBrokaWorksScreen(
      repository: _FakeSafePayment(const SafePaymentInfo(
          inAppPayments: true, message: '', advice: [], providers: [], disclaimer: '')),
    )));
    await tester.pump(const Duration(seconds: 1));
    await scrollTo(tester, find.text('Escrow: how money moves'));
    expect(find.text('Escrow: how money moves'), findsOneWidget);
    expect(find.byType(EscrowCallout), findsNothing);
  });

  group('with payments hidden (the default build)', () {
    setUp(() => paymentsShown = false);
    tearDown(() => paymentsShown = true);

    testWidgets('How BROKA works says to pay directly, with nothing leading to escrow or a badge',
        (tester) async {
      await tester.pumpWidget(MaterialApp(home: HowBrokaWorksScreen(repository: _FakeSafePayment(_info))));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Check it, then pay'), findsOneWidget);
      expect(find.byType(EscrowCallout), findsNothing);
      await scrollTo(tester, find.text('Paying safely'));
      expect(find.text('Paying safely'), findsOneWidget);
      expect(find.text('Pay safely with escrow'), findsNothing);
      await scrollTo(tester, find.text('Ranking, and what buyers see first'));
      expect(find.textContaining('Verified badge is paid for'), findsNothing);
      expect(find.textContaining('Nothing on BROKA buys a higher place'), findsOneWidget);
      expect(find.textContaining('Pay with escrow'), findsNothing);
      expect(find.text('Walk me through paying with escrow'), findsNothing);
    });
  });

  group('the escrow services screen', () {
    const full = SafePaymentInfo(
      inAppPayments: false,
      message: '',
      advice: ['Collecting in person? Meet in a busy public place.'],
      providers: [
        EscrowProvider(id: 'econfirm', name: 'E-Confirm', url: 'https://econfirm.co.ke',
            note: 'M-Pesa escrow.', tagline: 'M-Pesa escrow for most deals',
            fees: 'A commission on top, shown before you pay.', limits: 'It takes KES 100 to 500,000 a deal.',
            pay: 'an M-Pesa prompt', start: 'Tap Start Escrow.', release: 'approve with the code.',
            payout: 'E-Confirm pays you by M-Pesa.', dispute: 'The money stays held.'),
        EscrowProvider(id: 'shikilia', name: 'Shikilia', url: 'https://www.shikilia.co.ke',
            note: 'On WhatsApp.', tagline: 'Escrow on WhatsApp'),
      ],
      escrowRules: ['Never use an escrow link the other person sends you.'],
      disclaimer: "These are independent services. BROKA doesn't run them.",
    );

    testWidgets("each service: what it costs, its site, and Zeno to guide", (tester) async {
      final opened = <Uri>[];
      final asked = <String>[];
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: EscrowServicesScreen(
        repository: _FakeSafePayment(full),
        openUrl: (u) async { opened.add(u); return true; },
        onZeno: asked.add,
      )));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Pay safely with escrow'), findsOneWidget);
      expect(find.textContaining('Never use an escrow link'), findsOneWidget);
      await tester.tap(find.text('Let Zeno guide me, step by step'));
      expect(asked, [zenoEscrowPrompt]);

      await scrollTo(tester, find.text('Open E-Confirm'));
      await tester.ensureVisible(find.text('Open E-Confirm'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('A commission on top, shown before you pay.', findRichText: true), findsOneWidget);
      await tester.tap(find.text('Open E-Confirm'));
      await tester.pump();
      expect(opened, [Uri.parse('https://econfirm.co.ke')]);
      await tester.tap(find.text('Zeno, guide me').first);
      await tester.pump();
      expect(asked.last, 'Walk me through paying with E-Confirm');
      expect(find.textContaining('independent'), findsWidgets);
    });

    testWidgets('offline, the services still show by name', (tester) async {
      await tester.pumpWidget(MaterialApp(home: EscrowServicesScreen(repository: _FakeSafePayment(null))));
      await tester.pump(const Duration(seconds: 1));
      await scrollTo(tester, find.text('Lipasafe'));
      expect(find.text('Lipasafe'), findsOneWidget);
    });
  });

  testWidgets('the escrow callout opens the services, and Ask Zeno the walkthrough', (tester) async {
    var opened = 0, zeno = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      EscrowCallout(onOpen: () => opened++, onZeno: () => zeno++),
      EscrowCallout(compact: true, onOpen: () => opened++, onZeno: () => zeno++),
    ]))));
    await tester.pumpAndSettle(); // the shine runs once, then stops
    expect(find.text('Pay with escrow'), findsNWidgets(2));
    await tester.tap(find.text('See escrow services  ›'));
    await tester.tap(find.text('Ask Zeno').last);
    expect((opened, zeno), (1, 1));
  });

  group("an auction winner's Pay now", () {
    // A won auction, as GET /auctions/{id} returns it to its winner.
    setUp(() {
      ApiService.currentUserId = 'buyer-1';
      setFakeRoute((uri) => switch (uri.path) {
            '/auctions/a1' => {
                'id': 'a1', 'name': 'iPhone 13', 'status': 'ended', 'bid_count': 4,
                'outcome': 'won', 'winner_id': 'buyer-1', 'winning_amount': 85000,
                'deal_id': 'deal-1',
              },
            '/auction/a1/leaderboard' => <Object?>[],
            _ => null,
          });
    });
    tearDown(() {
      ApiService.currentUserId = null;
      setFakeRoute(null);
    });

    Future<void> payNow(WidgetTester tester, SafePaymentRepository payments) async {
      await tester.pumpWidget(MaterialApp(
          home: AuctionScreen(listingId: 'a1', safePayment: payments)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Pay now'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    // It went straight to a form saying "your payment is held in escrow" -
    // a promise BROKA can't keep while it holds no payments, made just
    // before the server refused the payment.
    testWidgets('opens the advice, not an escrow form, while payments are off', (tester) async {
      await payNow(tester, _FakeSafePayment(_info));
      expect(find.text('Pay safely with escrow'), findsOneWidget);
      expect(find.text('Pay for your win'), findsNothing);
      expect(find.textContaining('held in escrow'), findsNothing);
    });

    testWidgets('...and the escrow payment once payments are back', (tester) async {
      await payNow(tester, _FakeSafePayment(const SafePaymentInfo(
          inAppPayments: true, message: '', advice: [], providers: [], disclaimer: '')));
      expect(find.text('Pay for your win'), findsOneWidget);
      expect(find.text('Pay safely with escrow'), findsNothing);
    });
  });
}
