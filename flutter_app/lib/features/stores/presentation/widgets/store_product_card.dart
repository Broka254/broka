// A product in a store's catalogue, as a shop shows it: the photo with its
// condition, the name, the price, and Add to cart - which turns into a
// − n + stepper once it's in the cart.
//
// Not the marketplace ProductCard: that one carries the seller row (avatar,
// name, rating) and the store's own name, which are the same on every card
// inside a store (STORES_UI_REVIEW.md M6), and has nothing to buy with.
import 'package:flutter/material.dart';

import '../../../../main.dart' show BrokaColors;
import '../../../../utils/price_unit.dart';
import '../../../../widgets/broka_image.dart';
import '../../../categories/domain/category_visual.dart';
import '../../../listings/domain/models/listing.dart';
import '../../data/store_cart.dart';
import '../store_cart_screen.dart' show QuantityStepper;

class StoreProductCard extends StatelessWidget {
  const StoreProductCard({
    super.key,
    required this.listing,
    required this.cart,
    required this.onTap,
    this.onAddBlocked,
  });

  final BrokaListing listing;
  final StoreCart cart;
  final VoidCallback onTap;

  /// Called instead of adding when this buyer can't buy here (the store's
  /// own owner previewing it). Null: adding is allowed.
  final VoidCallback? onAddBlocked;

  /// Height the card needs below its photo at a text scale of 1: padding,
  /// two lines of name, the price and the 36dp button (ProductGridView's
  /// itemTextBlock).
  static const double textBlock = 128;

  /// The photo's height as a share of the card's width (ProductGridView's
  /// itemImageShare): a little taller than Home's 0.85, so a shop's
  /// products get more of the screen and the photo does the selling.
  static const double imageShare = 0.95;

  static const _accent = Color(0xFFB69CFF);

  bool get _isAuction => listing.listingType == 'auction';

  String? get _condition => switch (listing.condition) {
        'new' => 'New',
        'used' => 'Used',
        'refurbished' => 'Refurbished',
        _ => null,
      };

  /// The card's photo: the stored cover, else the first photo, else what
  /// listings not converted yet carry (the showcase, or base64 photos).
  String? get _image =>
      listing.cover?.thumb ??
      (listing.photos.isNotEmpty ? listing.photos.first.thumb : null) ??
      listing.showcaseImageUrl ??
      listing.verifiedPhotos?.split(',').firstWhere((s) => s.isNotEmpty, orElse: () => '');

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final placeholder = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: CategoryVisuals.gradientFor(listing.category)
              .map((c) => c.withOpacity(0.28)).toList(),
        ),
      ),
      alignment: Alignment.center,
      child: Text(CategoryVisuals.emojiFor(listing.category), style: const TextStyle(fontSize: 40)),
    );

    // Home's product-card surface (widgets/product_card.dart): a thin
    // violet-to-blue edge around the card gradient. This was a flat bgCard
    // fill with a grey border - the one card in the app that didn't carry
    // BROKA's colours.
    return Semantics(
      button: true,
      label: listing.name,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: listing.isFeatured
                ? BrokaColors.brandGradient
                : [BrokaColors.gold.withOpacity(0.45), BrokaColors.neonBlue.withOpacity(0.35)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(1.2),
          child: Material(
            key: Key('store-product-${listing.id}'),
            color: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.8)),
            clipBehavior: Clip.antiAlias,
            child: Ink(
              decoration: const BoxDecoration(gradient: BrokaColors.cardGradient),
              child: InkWell(
                onTap: onTap,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(
                    child: Stack(fit: StackFit.expand, children: [
                      image == null || image.isEmpty
                          ? placeholder
                          : BrokaImage(image, fit: BoxFit.cover, placeholder: placeholder),
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Wrap(spacing: 4, runSpacing: 4, children: [
                          if (_isAuction) const _Badge('Auction', color: BrokaColors.danger),
                          if (listing.isFeatured) const _Badge('Featured', color: BrokaColors.gold),
                          if (_condition != null) _Badge(_condition!, color: BrokaColors.neonBlue),
                        ]),
                      ),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        height: 36,
                        child: Text(listing.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13.5,
                                fontWeight: FontWeight.w600, height: 1.3)),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                            PriceUnits.priceLabel(listing.priceFormatted, listing.priceUnit),
                            style: const TextStyle(color: _accent, fontSize: 16,
                                fontWeight: FontWeight.w900)),
                      ),
                      const SizedBox(height: 8),
                      _isAuction ? _viewButton() : _cartControl(context),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _viewButton() => SizedBox(
        height: 36,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: BrokaColors.textHigh,
            side: const BorderSide(color: BrokaColors.border),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('View auction', style: TextStyle(fontWeight: FontWeight.w700,
              fontSize: 12.5)),
        ),
      );

  Widget _cartControl(BuildContext context) => ListenableBuilder(
        listenable: cart,
        builder: (context, _) {
          final inCart = cart.quantityOf(listing.id);
          if (inCart > 0) {
            return SizedBox(
              height: 36,
              child: Center(
                child: QuantityStepper(
                  keyPrefix: 'card-${listing.id}',
                  compact: true,
                  quantity: inCart,
                  max: CartItem.fromListing(listing).maxQuantity,
                  onChanged: (q) => cart.setQuantity(listing.id, q),
                ),
              ),
            );
          }
          return SizedBox(
            height: 36,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                borderRadius: BorderRadius.circular(10),
              ),
              child: TextButton.icon(
                key: Key('add-to-cart-${listing.id}'),
                onPressed: () {
                  if (onAddBlocked != null) {
                    onAddBlocked!();
                  } else {
                    cart.add(CartItem.fromListing(listing));
                  }
                },
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.add_shopping_cart_rounded, size: 16),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Add to cart', style: TextStyle(fontWeight: FontWeight.w800,
                      fontSize: 12.5)),
                ),
              ),
            ),
          );
        },
      );
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, {required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: BrokaColors.bg.withOpacity(0.82),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.7)),
        ),
        child: Text(label, style: TextStyle(color: Color.lerp(color, Colors.white, 0.35),
            fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.2)),
      );
}
