// BROKA - how do you want to pay? The first step of paying BROKA for
// anything (the listing fee, a premium plan).
//
// Picking a method moves straight on to paying that way, so what the
// person sees about the payment itself - which number the prompt goes to -
// is on a screen of its own instead of under everything else. M-Pesa is
// the only method today; one added to PaymentMethod gets a tile here.
//
// Pops `true` once paid.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../main.dart';
import '../domain/checkout.dart';
import 'checkout_widgets.dart';
import 'mpesa_checkout_screen.dart';

class PaymentMethodScreen extends StatelessWidget {
  const PaymentMethodScreen({
    super.key,
    required this.order,
    required this.charge,
    required this.success,
    this.popOnPaid = false,
    this.pollEvery = const Duration(seconds: 3),
    this.giveUpAfter = const Duration(seconds: 150),
  });

  final CheckoutOrder order;
  final MpesaCharge charge;
  final CheckoutSuccess success;

  /// Close as soon as M-Pesa confirms, without the "paid" screen - for a
  /// caller that celebrates itself (Go live).
  final bool popOnPaid;
  final Duration pollEvery;
  final Duration giveUpAfter;

  Future<void> _choose(BuildContext context, PaymentMethod method) async {
    HapticFeedback.selectionClick();
    final paid = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => switch (method) {
        PaymentMethod.mpesa => MpesaCheckoutScreen(
            order: order,
            charge: charge,
            success: success,
            popOnPaid: popOnPaid,
            pollEvery: pollEvery,
            giveUpAfter: giveUpAfter,
          ),
      },
    ));
    if (paid == true && context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => CheckoutScaffold(
        title: 'Payment method',
        icon: Icons.account_balance_wallet_rounded,
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const CheckoutLabel('Choose how to pay'),
            const SizedBox(height: 4),
            const Text('Pick a method to continue.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
            const SizedBox(height: 14),
            _MethodTile(
              key: const Key('method-mpesa'),
              title: 'M-Pesa',
              subtitle: 'A prompt comes to your phone - enter your PIN to pay.',
              onTap: () => _choose(context, PaymentMethod.mpesa),
            ),
            const SizedBox(height: 10),
            const Row(children: [
              Icon(Icons.info_outline_rounded, size: 14, color: BrokaColors.textMid),
              SizedBox(width: 6),
              Expanded(
                child: Text('More ways to pay are on the way.',
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
              ),
            ]),
            const SizedBox(height: 26),
            const CheckoutLabel("You're paying for"),
            const SizedBox(height: 10),
            OrderSummary(order: order),
          ]),
        ),
      );
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({super.key, required this.title, required this.subtitle, required this.onTap});
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Pay with $title',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: CheckoutCard(
              accent: BrokaColors.neonGreen,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: BrokaColors.neonGreen.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.5)),
                  ),
                  child: const Icon(Icons.phone_android_rounded, color: BrokaColors.neonGreen, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title,
                        style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid),
              ]),
            ),
          ),
        ),
      );
}
