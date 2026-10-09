// A store's cart: what the buyer picked, how many, the total, and checkout.
//
// Checkout goes item by item, until one-payment checkout arrives with
// orders (STORES_PLAN.md phase 4): each item opens its deal room, where it
// is agreed with the store. BROKA holds no payments for now, so the buyer
// pays the store directly, after seeing the item. The cart says so before
// anyone taps, rather than promising a single payment that doesn't exist -
// or an escrow that doesn't either, which is the line a fraudster asking
// for money "into BROKA escrow" relies on.
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;
import '../../../utils/auth_gate.dart';
import '../../../utils/price_format.dart';
import '../../../utils/price_unit.dart';
import '../../../widgets/broka_image.dart';
import '../../../widgets/constellation_background.dart';
import '../../categories/domain/category_visual.dart';
import '../../safe_payment/escrow_callout.dart';
import '../../safe_payment/payments_shown.dart';
import '../data/store_cart.dart';

/// Opens the cart for [storeId] ([storeName] in the title).
Future<void> openStoreCart(BuildContext context,
    {required String storeId, required String storeName, bool animateBackground = true}) {
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => StoreCartScreen(
        storeId: storeId, storeName: storeName, animateBackground: animateBackground),
  ));
}

class StoreCartScreen extends StatelessWidget {
  const StoreCartScreen({
    super.key,
    required this.storeId,
    required this.storeName,
    this.animateBackground = true,
    this.openDeal,
  });

  final String storeId;
  final String storeName;
  final bool animateBackground;

  /// Opens an item's deal room; tests pass their own.
  final void Function(BuildContext context, CartItem item)? openDeal;

  @override
  Widget build(BuildContext context) {
    final cart = StoreCart.of(storeId);
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) => Scaffold(
        backgroundColor: BrokaColors.bg,
        appBar: AppBar(
          backgroundColor: BrokaColors.bg,
          surfaceTintColor: Colors.transparent,
          iconTheme: const IconThemeData(color: BrokaColors.textHigh),
          titleSpacing: 0,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cart.isEmpty ? 'Your cart' : 'Your cart (${cart.count})',
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18,
                    fontWeight: FontWeight.w800)),
            Text(storeName, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
          ]),
          actions: [
            if (!cart.isEmpty)
              TextButton(
                key: const Key('cart-clear'),
                onPressed: () => _confirmClear(context, cart),
                child: const Text('Clear', style: TextStyle(color: _accent,
                    fontWeight: FontWeight.w700)),
              ),
          ],
        ),
        body: ConstellationBackground(
          animate: animateBackground,
          child: cart.isEmpty ? const _EmptyCart() : _CartList(cart: cart),
        ),
        bottomNavigationBar: cart.isEmpty
            ? null
            : _CheckoutBar(
                cart: cart,
                onCheckout: () => _checkout(context, cart),
              ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, StoreCart cart) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        title: const Text('Empty your cart?', style: TextStyle(color: BrokaColors.textHigh)),
        content: Text('Everything from $storeName comes out of it.',
            style: const TextStyle(color: BrokaColors.textMid)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(d, true),
              child: const Text('Empty', style: TextStyle(color: BrokaColors.danger))),
        ],
      ),
    );
    if (ok == true) cart.clear();
  }

  Future<void> _checkout(BuildContext context, StoreCart cart) async {
    final authed = await requireAuth(context, reason: 'to check out');
    if (!authed || !context.mounted) return;
    final items = cart.items;
    // One item: straight to its deal room, nothing to choose between.
    if (items.length == 1) {
      _open(context, items.single);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheet) => _CheckoutSheet(
        storeName: storeName,
        items: items,
        onPay: (item) => _open(sheet, item),
      ),
    );
  }

  void _open(BuildContext context, CartItem item) {
    if (openDeal != null) {
      openDeal!(context, item);
      return;
    }
    Navigator.of(context).pushNamed('/negotiate',
        arguments: {'listingId': item.listingId, 'role': 'buyer'});
  }
}

// BrokaColors.gold is under 4:1 on the dark background; this lighter violet
// reads at 7:1 (the store screens' accent).
const _accent = Color(0xFFB69CFF);

String _price(CartItem i) => PriceUnits.priceLabel(formatKes(i.price), i.priceUnit);

class _EmptyCart extends StatelessWidget {
  const _EmptyCart();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [
                  BrokaColors.gold.withOpacity(0.25),
                  BrokaColors.neonBlue.withOpacity(0.15),
                ]),
                border: Border.all(color: BrokaColors.gold.withOpacity(0.5)),
              ),
              child: const Icon(Icons.shopping_cart_outlined, color: _accent, size: 38),
            ),
            const SizedBox(height: 16),
            const Text('Your cart is empty',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text('Add products from the store and they wait here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textMid, fontSize: 13.5)),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: BrokaColors.textHigh,
                side: const BorderSide(color: BrokaColors.gold),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Continue shopping'),
            ),
          ]),
        ),
      );
}

class _CartList extends StatelessWidget {
  const _CartList({required this.cart});
  final StoreCart cart;

  @override
  Widget build(BuildContext context) {
    final items = cart.items;
    return ListView(
      key: const Key('cart-list'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        for (final item in items) _CartLine(item: item, cart: cart),
        const SizedBox(height: 6),
        _Summary(cart: cart),
        const SizedBox(height: 12),
        const _PayingNote(),
      ],
    );
  }
}

class _CartLine extends StatelessWidget {
  const _CartLine({required this.item, required this.cart});
  final CartItem item;
  final StoreCart cart;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('cart-item-${item.listingId}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: 76, height: 76, child: CartThumb(item: item)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5,
                        fontWeight: FontWeight.w700, height: 1.25)),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  key: Key('cart-remove-${item.listingId}'),
                  padding: EdgeInsets.zero,
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline_rounded, size: 20,
                      color: BrokaColors.textMid),
                  onPressed: () => cart.remove(item.listingId),
                ),
              ),
            ]),
            const SizedBox(height: 2),
            Text(_price(item), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
            const SizedBox(height: 8),
            Row(children: [
              QuantityStepper(
                keyPrefix: 'cart-${item.listingId}',
                quantity: item.quantity,
                max: item.maxQuantity,
                onChanged: (q) => cart.setQuantity(item.listingId, q),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(formatKes(item.total),
                      style: const TextStyle(color: _accent, fontSize: 15.5,
                          fontWeight: FontWeight.w800)),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// A cart item's picture, or its category's emoji when it has none.
class CartThumb extends StatelessWidget {
  const CartThumb({super.key, required this.item});
  final CartItem item;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: CategoryVisuals.gradientFor(item.category)
              .map((c) => c.withOpacity(0.35)).toList(),
        ),
      ),
      alignment: Alignment.center,
      child: Text(CategoryVisuals.emojiFor(item.category), style: const TextStyle(fontSize: 28)),
    );
    return item.image == null
        ? placeholder
        : BrokaImage(item.image, fit: BoxFit.cover, placeholder: placeholder);
  }
}

/// − n + for how many of a product: − at one takes it out, + stops at what
/// the listing has.
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.keyPrefix,
    required this.quantity,
    required this.max,
    required this.onChanged,
    this.compact = false,
  });

  final String keyPrefix;
  final int quantity;
  final int max;
  final ValueChanged<int> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 30.0 : 34.0;
    Widget button(IconData icon, String tip, VoidCallback? onTap, String key) => SizedBox(
          width: size,
          height: size,
          child: IconButton(
            key: Key('$keyPrefix-$key'),
            padding: EdgeInsets.zero,
            tooltip: tip,
            onPressed: onTap,
            icon: Icon(icon, size: compact ? 16 : 18),
            color: BrokaColors.textHigh,
            disabledColor: BrokaColors.textMid.withOpacity(0.4),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: BrokaColors.bg.withOpacity(0.6),
        borderRadius: BorderRadius.circular(size / 2),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.55)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        button(quantity <= 1 ? Icons.delete_outline_rounded : Icons.remove_rounded,
            quantity <= 1 ? 'Remove' : 'One less', () => onChanged(quantity - 1), 'minus'),
        ConstrainedBox(
          constraints: BoxConstraints(minWidth: compact ? 18 : 24),
          child: Text('$quantity', key: Key('$keyPrefix-qty'), textAlign: TextAlign.center,
              style: TextStyle(color: BrokaColors.textHigh, fontSize: compact ? 13 : 14.5,
                  fontWeight: FontWeight.w800)),
        ),
        button(Icons.add_rounded, quantity >= max ? 'No more available' : 'One more',
            quantity >= max ? null : () => onChanged(quantity + 1), 'plus'),
      ]),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.cart});
  final StoreCart cart;

  @override
  Widget build(BuildContext context) {
    Widget row(String label, Widget value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(color: BrokaColors.textMid,
                fontSize: 13.5))),
            // Flexible: a long value wraps instead of pushing the row off a
            // small phone.
            Flexible(child: value),
          ]),
        );
    return Container(
      key: const Key('cart-summary'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('ORDER SUMMARY', style: TextStyle(color: BrokaColors.textMid, fontSize: 11,
            fontWeight: FontWeight.w800, letterSpacing: 1.2)),
        const SizedBox(height: 6),
        row('Items (${cart.count})', Text(formatKes(cart.subtotal),
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700))),
        row('Delivery', const Text('Agreed with the store',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w600))),
        // Was "Buyer protection: Included" - escrow, which BROKA doesn't
        // offer while payments are paused. Who is paid is what the buyer
        // needs to know: the store - through an independent escrow service,
        // or directly - never a number claiming to be BROKA.
        row('Payment', Text(paymentsShown ? 'Escrow, or the store' : 'To the store, directly',
            textAlign: TextAlign.end,
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w600))),
        const Divider(color: BrokaColors.border, height: 18),
        row('Subtotal', Text(formatKes(cart.subtotal), key: const Key('cart-subtotal'),
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                fontWeight: FontWeight.w900))),
      ]),
    );
  }
}

class _PayingNote extends StatelessWidget {
  const _PayingNote();

  // Escrow first (2026-10-08): a store buyer is often across town or in
  // another county, so most can't see the item before paying - and the
  // escrow services are independent, never BROKA's (escrow_callout.dart).
  @override
  Widget build(BuildContext context) => Column(
        key: const Key('cart-paying-note'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (paymentsShown) ...[
            const EscrowCallout(),
            const SizedBox(height: 10),
          ],
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: BrokaColors.success.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: BrokaColors.success.withOpacity(0.35)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.visibility_outlined, color: BrokaColors.success, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  paymentsShown
                      ? "BROKA doesn't hold payments for now. Can't see the item before paying? Use "
                        "an escrow service - they're independent, not run by BROKA. Collecting it? "
                        'See the item first, then pay the store directly. Never send a deposit to '
                        '"hold" an item.'
                      : "BROKA doesn't hold payments: you pay the store directly. See the item "
                        'first, then pay. Never send a deposit to "hold" an item.',
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, height: 1.4)),
              ),
            ]),
          ),
        ],
      );
}

class _CheckoutBar extends StatelessWidget {
  const _CheckoutBar({required this.cart, required this.onCheckout});
  final StoreCart cart;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: const BoxDecoration(
            color: BrokaColors.bgMid,
            border: Border(top: BorderSide(color: BrokaColors.border)),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                const Text('Total', style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(formatKes(cart.subtotal), style: const TextStyle(
                      color: BrokaColors.textHigh, fontSize: 20, fontWeight: FontWeight.w900)),
                ),
              ]),
            ),
            const SizedBox(width: 12),
            _GradientPill(
              key: const Key('cart-checkout'),
              onTap: onCheckout,
              icon: Icons.lock_rounded,
              label: 'Checkout',
            ),
          ]),
        ),
      );
}

class _GradientPill extends StatelessWidget {
  const _GradientPill({super.key, required this.onTap, required this.icon, required this.label});
  final VoidCallback onTap;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.4), blurRadius: 14)],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: Colors.white, size: 17),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w800, fontSize: 15)),
            ]),
          ),
        ),
      );
}

/// Checkout for a cart of several products: each one is paid in its own
/// deal room, so the sheet lists them with a Pay button each, and ticks
/// the ones already opened.
class _CheckoutSheet extends StatefulWidget {
  const _CheckoutSheet({required this.storeName, required this.items, required this.onPay});
  final String storeName;
  final List<CartItem> items;
  final ValueChanged<CartItem> onPay;

  @override
  State<_CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<_CheckoutSheet> {
  final _opened = <String>{};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          key: const Key('checkout-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          children: [
            Center(
              child: Container(width: 40, height: 4, decoration: BoxDecoration(
                  color: BrokaColors.border, borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 16),
            Text('Checkout · ${widget.storeName}', maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 19,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              paymentsShown
                  ? 'Each product has its own deal room: agree it with the store there, then '
                    'pay through an escrow service - Zeno walks you through it - or pay the '
                    'store directly once you have seen it.'
                  : 'Each product has its own deal room: agree it with the store there, then '
                    'pay the store directly once you have seen it.',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.4)),
            const SizedBox(height: 14),
            for (final item in widget.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(width: 48, height: 48, child: CartThumb(item: item)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: BrokaColors.textHigh,
                              fontWeight: FontWeight.w700)),
                      Text('${item.quantity} × ${_price(item)}', maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  _opened.contains(item.listingId)
                      ? const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.check_circle_rounded, color: BrokaColors.success, size: 18),
                          SizedBox(width: 4),
                          Text('Opened', style: TextStyle(color: BrokaColors.success,
                              fontWeight: FontWeight.w700, fontSize: 12.5)),
                        ])
                      : FilledButton(
                          key: Key('checkout-pay-${item.listingId}'),
                          onPressed: () {
                            setState(() => _opened.add(item.listingId));
                            widget.onPay(item);
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: BrokaColors.gold,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          child: const Text('Pay'),
                        ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
