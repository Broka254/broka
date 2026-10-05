// Paying safely while BROKA handles no deal payments (backend:
// GET /pricing/safe-payment). The pay button must lead to advice, not to a
// payment form the server refuses; the escrow services must be marked as
// independent; and the explainer must stop describing a payment buyers
// can't make.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/core/utils/result.dart';
import 'package:broka/features/escrow/data/repositories/escrow_repository.dart';
import 'package:broka/features/escrow/presentation/escrow_actions.dart';
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

    expect(find.text('Paying safely'), findsOneWidget);
    expect(find.text('Kenya Escrow'), findsOneWidget);
    expect(find.textContaining('independent'), findsOneWidget);
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

  testWidgets('without the server, the core advice still shows', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SafePaymentView(info: null))));
    expect(find.textContaining('check the item works before you pay'), findsOneWidget);
    expect(find.text('Escrow services'), findsNothing);
  });

  testWidgets('How BROKA works explains paying safely, not escrow, while payments are off', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HowBrokaWorksScreen(repository: _FakeSafePayment(_info))));
    // The ambient background never settles: pump past the fetch and the fade-in.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Paying safely'), findsOneWidget);
    expect(find.text('Escrow: how money moves'), findsNothing);
  });

  testWidgets('...and escrow again once payments are back', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HowBrokaWorksScreen(
      repository: _FakeSafePayment(const SafePaymentInfo(
          inAppPayments: true, message: '', advice: [], providers: [], disclaimer: '')),
    )));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Escrow: how money moves'), findsOneWidget);
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
      expect(find.text('Paying safely'), findsOneWidget);
      expect(find.text('Pay for your win'), findsNothing);
      expect(find.textContaining('held in escrow'), findsNothing);
    });

    testWidgets('...and the escrow payment once payments are back', (tester) async {
      await payNow(tester, _FakeSafePayment(const SafePaymentInfo(
          inAppPayments: true, message: '', advice: [], providers: [], disclaimer: '')));
      expect(find.text('Pay for your win'), findsOneWidget);
      expect(find.text('Paying safely'), findsNothing);
    });
  });
}
