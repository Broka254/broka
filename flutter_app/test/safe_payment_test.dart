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
import 'package:broka/screens/how_broka_works_screen.dart';

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
}
