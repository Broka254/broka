// BROKA - the look shared by every screen on the way to paying BROKA: the
// listing fee, premium plans, the payment methods and the M-Pesa screen.
//
// They used to be plain black pages with a stock AppBar and a flat green
// button - the only screens in the app that did not sit on the
// constellation the rest of it does, so paying felt like leaving BROKA.
// These are the Seller Dashboard's pieces: the starfield, a gradient title,
// card surfaces and the brand-gradient button.
import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../../utils/price_format.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/gradient_button.dart';
import '../domain/checkout.dart';

const checkoutGradient = [BrokaColors.gold, BrokaColors.neonBlue];

/// The page: starfield, header with back button and gradient title, the
/// [body], and an optional [bottom] action pinned under it.
class CheckoutScaffold extends StatelessWidget {
  const CheckoutScaffold({
    super.key,
    required this.title,
    required this.icon,
    required this.body,
    this.bottom,
  });

  final String title;
  final IconData icon;
  final Widget body;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 360;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        // Still under reduced motion, and in tests (which settle frames).
        animate: !MediaQuery.of(context).disableAnimations,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.2,
              colors: [BrokaColors.gold.withOpacity(0.13), Colors.transparent],
              stops: const [0.0, 0.55],
            ),
          ),
          child: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
                child: Row(children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, color: BrokaColors.textHigh, size: 19),
                  ),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [
                        checkoutGradient.first.withOpacity(0.28),
                        checkoutGradient.last.withOpacity(0.14),
                      ]),
                      border: Border.all(color: checkoutGradient.first.withOpacity(0.5)),
                    ),
                    child: Icon(icon, size: 18, color: BrokaColors.textHigh),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ZoneGlowText(
                      title,
                      gradient: checkoutGradient,
                      fontSize: narrow ? 17 : 19,
                      maxLines: 1,
                      letterSpacing: narrow ? 0.8 : 1.1,
                    ),
                  ),
                ]),
              ),
              Expanded(child: body),
              if (bottom != null)
                Padding(padding: const EdgeInsets.fromLTRB(18, 8, 18, 14), child: bottom!),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The card surface the dashboard's sections use.
class CheckoutCard extends StatelessWidget {
  const CheckoutCard({super.key, required this.child, this.accent, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final Color? accent;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors, begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: (accent ?? BrokaColors.border).withOpacity(accent == null ? 1 : 0.4)),
        ),
        child: child,
      );
}

/// A small spaced-out section label, as on the dashboard.
class CheckoutLabel extends StatelessWidget {
  const CheckoutLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: const TextStyle(
          color: BrokaColors.textMid, fontSize: 11, letterSpacing: 1.6, fontWeight: FontWeight.w800));
}

/// The primary action: the brand-gradient button, with a spinner while busy.
class CheckoutButton extends StatelessWidget {
  const CheckoutButton({super.key, required this.label, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: GradientButton(
          onPressed: busy ? null : onPressed,
          colors: BrokaColors.brandGradient,
          height: 54,
          child: busy
              ? const SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
              : Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w900)),
        ),
      );
}

/// What is being paid for, line by line, and the total.
class OrderSummary extends StatelessWidget {
  const OrderSummary({super.key, required this.order});
  final CheckoutOrder order;

  @override
  Widget build(BuildContext context) => CheckoutCard(
        key: const Key('checkout-summary'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(order.title,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800)),
          if (order.subject != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(order.subject!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
            ),
          if (order.lines.isNotEmpty) const SizedBox(height: 10),
          for (final l in order.lines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Expanded(child: Text(l.label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5))),
                Text('KES ${formatKesAmount(l.amount)}',
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ]),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: BrokaColors.border),
          ),
          Row(children: [
            const Expanded(
              child: Text('Total',
                  style: TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
            ),
            Text('KES ${formatKesAmount(order.total)}',
                key: const Key('checkout-total'),
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 20, fontWeight: FontWeight.w900)),
          ]),
        ]),
      );
}

/// A whole-screen state: waiting for M-Pesa, paid, slow, failed to load.
class CheckoutMessage extends StatelessWidget {
  const CheckoutMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.iconColor = BrokaColors.gold,
    this.action,
    this.onAction,
    this.busy = false,
  });
  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: iconColor.withOpacity(0.12),
                border: Border.all(color: iconColor.withOpacity(0.45), width: 1.5),
                boxShadow: [BoxShadow(color: iconColor.withOpacity(0.25), blurRadius: 28)],
              ),
              child: Icon(icon, color: iconColor, size: 46),
            ),
            const SizedBox(height: 20),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 13.5, height: 1.4)),
            if (busy) ...[
              const SizedBox(height: 22),
              const CircularProgressIndicator(color: BrokaColors.gold),
            ],
            if (action != null) ...[
              const SizedBox(height: 24),
              SizedBox(
                width: 220,
                child: GradientButton(
                  onPressed: onAction,
                  colors: BrokaColors.brandGradient,
                  child: Text(action!,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ),
            ],
          ]),
        ),
      );
}
