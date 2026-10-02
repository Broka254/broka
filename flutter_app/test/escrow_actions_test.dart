// Buyer protection dialogs (2026-10-02): paying in parts, releasing with the
// delivery check first, asking for a refund. The rules are the backend's;
// these check what the dialogs ask, recommend and send.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/core/utils/result.dart';
import 'package:broka/features/escrow/data/repositories/escrow_repository.dart';
import 'package:broka/features/escrow/presentation/escrow_actions.dart';

class _FakeEscrow extends EscrowRepository {
  final List<double?> quoted = [];
  final List<Map<String, dynamic>> funded = [];
  final List<Map<String, dynamic>> released = [];
  final List<String> refunds = [];
  double balance = 60000;
  double paid = 40000;

  Map<String, dynamic> _quote(double goods) => {
        'goods_amount': goods,
        'merchant_commission': goods * 0.0349,
        'provider_fee': goods * 0.01,
        'total_to_pay': goods * 1.0449,
        'agreed_price': paid + balance,
        'amount_paid': paid,
        'balance': balance,
        'min_part_payment': 100,
      };

  @override
  Future<Result<Map<String, dynamic>>> feeQuote(String dealId, {double? amount}) async {
    quoted.add(amount);
    return Success(_quote(amount ?? balance));
  }

  @override
  Future<Result<Map<String, dynamic>>> fund(String dealId,
      {required String payerPhone, double? amount, String? idempotencyKey}) async {
    funded.add({'phone': payerPhone, 'amount': amount, 'key': idempotencyKey});
    return Success(_quote(amount ?? balance));
  }

  @override
  Future<Result<Map<String, dynamic>>> release(String dealId,
      {bool? itemReceived, bool? ownershipTransferred}) async {
    released.add({'item_received': itemReceived, 'ownership_transferred': ownershipTransferred});
    return const Success({'status': 'released'});
  }

  @override
  Future<Result<Map<String, dynamic>>> requestRefund(String dealId, String reason,
      {String? idempotencyKey}) async {
    refunds.add(reason);
    return const Success({'outcome': 'requested'});
  }
}

Future<void> _open(WidgetTester tester, Future<void> Function(BuildContext) show,
    {List<String>? pushed}) async {
  await tester.pumpWidget(MaterialApp(
    onGenerateRoute: (s) {
      pushed?.add(s.name ?? '');
      return MaterialPageRoute(
        settings: s,
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () => show(context), child: const Text('open')),
          ),
        ),
      );
    },
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a part payment is quoted and sent for the amount entered', (tester) async {
    final repo = _FakeEscrow();
    final pushed = <String>[];
    await _open(tester, (c) => showEscrowPayDialog(c, dealId: 'd1', repository: repo), pushed: pushed);

    expect(find.text('Add a payment'), findsOneWidget); // something was paid already
    expect(find.textContaining('Balance: KES 60,000'), findsOneWidget);
    final amount = find.byKey(const Key('escrow-pay-amount'));
    expect(tester.widget<TextField>(amount).controller!.text, '60000');

    await tester.enterText(amount, '20000');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(repo.quoted.last, 20000);

    await tester.enterText(find.widgetWithText(TextField, 'M-Pesa Phone'), '0712345678');
    await tester.tap(find.text('Pay'));
    await tester.pumpAndSettle();
    expect(repo.funded.single['amount'], 20000);
    expect(repo.funded.single['key'], isNotNull);
    expect(pushed, contains('/escrow-payment'));
  });

  testWidgets('paying the whole balance sends no amount (older backends understand it)', (tester) async {
    final repo = _FakeEscrow();
    await _open(tester, (c) => showEscrowPayDialog(c, dealId: 'd1', repository: repo));
    await tester.enterText(find.widgetWithText(TextField, 'M-Pesa Phone'), '0712345678');
    await tester.tap(find.text('Pay'));
    await tester.pumpAndSettle();
    expect(repo.funded.single['amount'], isNull);
  });

  testWidgets('releasing before delivery is recommended against, not blocked', (tester) async {
    final repo = _FakeEscrow();
    await _open(tester, (c) => showReleaseDialog(c, dealId: 'd1', amount: 100000, repository: repo));

    final confirm = find.byKey(const Key('escrow-release-confirm'));
    expect(tester.widget<ElevatedButton>(confirm).onPressed, isNull); // not answered yet

    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    expect(find.textContaining('We recommend waiting'), findsOneWidget);
    expect(find.text('Release anyway'), findsOneWidget);
    expect(find.text("I'll wait"), findsOneWidget);

    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(repo.released.single, {'item_received': false, 'ownership_transferred': null});
  });

  testWidgets('land asks about the ownership documents too', (tester) async {
    final repo = _FakeEscrow();
    await _open(tester, (c) => showReleaseDialog(c,
        dealId: 'd1', amount: 2000000, requiresOwnershipTransfer: true, repository: repo));

    expect(find.textContaining('ownership documents'), findsOneWidget);
    await tester.tap(find.text('Yes').first);
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('escrow-release-confirm'));
    expect(tester.widget<ElevatedButton>(confirm).onPressed, isNull); // documents unanswered

    await tester.tap(find.text('Yes').last);
    await tester.pumpAndSettle();
    expect(find.text('Release payment'), findsOneWidget);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(repo.released.single, {'item_received': true, 'ownership_transferred': true});
  });

  testWidgets('a refund request explains the 48 hours and sends the reason', (tester) async {
    final repo = _FakeEscrow();
    await _open(tester, (c) => showRefundRequestDialog(c, dealId: 'd1', amount: 40000, repository: repo));
    expect(find.textContaining('48 hours'), findsOneWidget);

    await tester.tap(find.text("The seller isn't responding"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request refund'));
    await tester.pumpAndSettle();
    expect(repo.refunds.single, "The seller isn't responding");
  });

  testWidgets('after a delivery claim a refund request is a dispute', (tester) async {
    final repo = _FakeEscrow();
    await _open(tester, (c) => showRefundRequestDialog(c,
        dealId: 'd1', amount: 40000, sellerClaimedDelivery: true, repository: repo));
    expect(find.text('Open a dispute'), findsOneWidget);
    expect(find.textContaining('opens a dispute'), findsOneWidget);
  });

  test('the summary reads the backend\'s naive UTC times as UTC', () {
    final inTwoDays = DateTime.now().toUtc().add(const Duration(hours: 47, minutes: 30));
    final naive = inTwoDays.toIso8601String().replaceAll('Z', '');
    final line = escrowSummary({
      'amount_paid': 40000, 'balance': 60000, 'agreed_price': 100000, 'auto_release_at': naive,
    }, isBuyer: true)!;
    expect(line, contains('Paid KES 40,000 of KES 100,000'));
    expect(line, contains('2 day(s)'));
  });
}
