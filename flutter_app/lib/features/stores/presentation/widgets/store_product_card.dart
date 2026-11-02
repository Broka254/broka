// A product in a store's catalogue, as a shop shows it: the photo with its
// condition, a save heart, the name, the price, how many are left, and Add
// to cart - which turns into a − n + stepper once it's in the cart.
//
// Not the marketplace ProductCard: that one carries the seller row (avatar,
// name, rating) and the store's own name, which are the same on every card
// inside a store (STORES_UI_REVIEW.md M6), and has nothing to buy with.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/utils/result.dart';
import '../../../../main.dart' show BrokaColors;
import '../../../../services/api_service.dart';
import '../../../../utils/auth_gate.dart';
import '../../../../utils/price_unit.dart';
import '../../../../widgets/broka_image.dart';
import '../../../categories/domain/category_visual.dart';
import '../../../listings/data/repositories/listings_repository.dart';
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
    this.showSave = true,
    this.listings,
  });

  final BrokaListing listing;
  final StoreCart cart;
  final VoidCallback onTap;

  /// Called instead of adding when this buyer can't buy here (the store's
  /// own owner previewing it). Null: adding is allowed.
  final VoidCallback? onAddBlocked;

  /// The save heart. False on the owner's own preview - saving your own
  /// product is meaningless, and the heart would only mis-tap.
  final bool showSave;

  /// Injectable for tests; the app uses the shared repository.
  final ListingsRepository? listings;

  /// Height the card needs below its photo at a text scale of 1: padding,
  /// one line of name, the price, the stock line and the 34dp button
  /// (ProductGridView's itemTextBlock). Same overall tile as Home's
  /// ProductCard, so the store's shelf reads as the same shop.
  static const double textBlock = 132;

  /// The photo's height as a share of the card's width (ProductGridView's
  /// itemImageShare): the same 0.85 as Home's cards, so a store's shelf
  /// and the marketplace feed show the same tile.
  static const double imageShare = 0.85;

  static const _accent = Color(0xFFB69CFF);

  bool get _isAuction => listing.listingType == 'auction';

  String? get _condition => switch (listing.condition) {
        'new' => 'New',
        'used' => 'Used',
        'refurbished' => 'Refurbished',
        _ => null,
      };

  /// How many are left, as the card says it: "Only 3 left" when the
  /// shelf is nearly empty, "In stock" while it isn't, and "Sold out"
  /// at zero. A quantity the seller never stated reads as in stock -
  /// the listing is active and buyable, which is what the line promises.
  ({String label, Color color, IconData icon}) get _stock {
    final left = listing.quantity;
    if (left != null && left <= 0) {
      return (label: 'Sold out', color: BrokaColors.textMid, icon: Icons.remove_circle_outline_rounded);
    }
    if (left != null && left <= 3) {
      return (label: 'Only $left left', color: BrokaColors.warning,
          icon: Icons.local_fire_department_outlined);
    }
    return (label: 'In stock', color: BrokaColors.success,
        icon: Icons.verified_outlined);
  }

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

    // The photo is the product's pitch: edge-to-edge, square, nothing
    // competing with it. While it loads the category's own gradient shows
    // with its emoji; when there is no photo at all the same surface says
    // so instead of leaving a dark hole.
    Widget photo() {
      final loading = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: CategoryVisuals.gradientFor(listing.category)
                .map((c) => c.withOpacity(0.35)).toList(),
          ),
        ),
        alignment: Alignment.center,
        child: Text(CategoryVisuals.emojiFor(listing.category),
            style: const TextStyle(fontSize: 44)),
      );
      if (image == null || image.isEmpty) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: CategoryVisuals.gradientFor(listing.category)
                  .map((c) => c.withOpacity(0.22)).toList(),
            ),
          ),
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(CategoryVisuals.emojiFor(listing.category),
                style: TextStyle(
                    fontSize: 44, color: Colors.white.withOpacity(0.85))),
            const SizedBox(height: 6),
            Text('No photo',
                style: TextStyle(
                    color: BrokaColors.textMid.withOpacity(0.9),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ]),
        );
      }
      return BrokaImage(image, fit: BoxFit.cover, placeholder: loading);
    }

    // A calm card: one hairline border on the card gradient, no neon
    // outline. Featured stores keep a whisper of violet so they still
    // stand out on a full rail.
    return Semantics(
      button: true,
      label: listing.name,
      child: Material(
        key: Key('store-product-${listing.id}'),
        color: Colors.transparent,
        elevation: 3,
        shadowColor: Colors.black.withOpacity(0.45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: listing.isFeatured
                ? BrokaColors.gold.withOpacity(0.55)
                : BrokaColors.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: const BoxDecoration(gradient: BrokaColors.cardGradient),
          child: InkWell(
            onTap: onTap,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  photo(),
                  Positioned(
                    top: 8,
                    left: 8,
                    right: showSave ? 44 : 8,
                    child: Wrap(spacing: 4, runSpacing: 4, children: [
                      if (_isAuction) const _Badge('Auction', color: BrokaColors.danger),
                      if (listing.isFeatured) const _Badge('Featured', color: BrokaColors.gold),
                      if (_condition != null) _Badge(_condition!, color: BrokaColors.neonBlue),
                    ]),
                  ),
                  if (showSave)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _SaveHeart(
                        listingId: listing.id,
                        listings: listings,
                      ),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    height: 18,
                    child: Text(listing.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13.5,
                            fontWeight: FontWeight.w700, height: 1.25)),
                  ),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                        PriceUnits.priceLabel(listing.priceFormatted, listing.priceUnit),
                        style: const TextStyle(color: _accent, fontSize: 16,
                            fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(height: 2),
                  _StockLine(stock: _stock),
                  const SizedBox(height: 7),
                  _isAuction ? _viewButton() : _cartControl(context),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _viewButton() => SizedBox(
        height: 34,
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
              height: 34,
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
            height: 34,
            width: double.infinity,
            child: DecoratedBox(
              // One flat brand-violet button: the gradient version glowed
              // beside every price on the rail.
              decoration: BoxDecoration(
                color: BrokaColors.gold,
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

  // Frosted pills that sit on the photo without shouting over it: a
  // dark wash, a whisper of the status colour in the ring, and the label
  // lifted toward white for contrast.
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.62),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.45)),
        ),
        child: Text(label, style: TextStyle(color: Color.lerp(color, Colors.white, 0.45),
            fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
      );
}

/// How many are left, under the price: "In stock" in green, "Only 3
/// left" in amber, "Sold out" in grey. One line, always - the grid's
/// textBlock counts on its height.
class _StockLine extends StatelessWidget {
  const _StockLine({required this.stock});
  final ({String label, Color color, IconData icon}) stock;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(stock.icon, size: 13, color: stock.color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(stock.label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: stock.color, fontSize: 11.5,
                  fontWeight: FontWeight.w700)),
        ),
      ]);
}

/// The save heart on the photo's top right: the same save the product
/// screen's heart toggles (GET/POST /listings/{id}/save, through the
/// engagement read), so a product saved here is saved everywhere.
///
/// The state is fetched once per listing and kept for the session: a
/// catalogue of twenty cards must not ask twenty times on every scroll
/// back. A visitor who isn't signed in sees the outline; tapping it
/// asks them to sign in first, the same gate as the product screen.
class _SaveHeart extends StatefulWidget {
  const _SaveHeart({required this.listingId, this.listings});
  final String listingId;
  final ListingsRepository? listings;

  /// What the session already knows, listing by listing.
  static final Map<String, bool> _known = {};

  /// Tests start from not knowing anything.
  @visibleForTesting
  static void resetCache() => _known.clear();

  @override
  State<_SaveHeart> createState() => _SaveHeartState();
}

class _SaveHeartState extends State<_SaveHeart> {
  ListingsRepository get _repo => widget.listings ?? listingsRepository;
  bool? _saved;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _saved = _SaveHeart._known[widget.listingId];
    if (_saved == null && ApiService.currentUserId != null) _load();
  }

  Future<void> _load() async {
    final result = await _repo.engagement(widget.listingId);
    if (!mounted) return;
    if (result case Success(:final data)) {
      _SaveHeart._known[widget.listingId] = data.saved;
      setState(() => _saved = data.saved);
    }
  }

  /// Saves, or takes the save back. Shown at once; put back, with a
  /// word, if the server says no - the product screen's rule.
  Future<void> _toggle() async {
    if (_busy) return;
    if (!await requireAuth(context, reason: 'to save listings')) return;
    if (!mounted) return;
    var saved = _saved;
    saved ??= _SaveHeart._known[widget.listingId];
    if (saved == null) {
      // Signed in just now: learn the state before flipping it, or the
      // first tap on an already-saved product would unsave it.
      setState(() => _busy = true);
      final result = await _repo.engagement(widget.listingId);
      if (!mounted) return;
      setState(() => _busy = false);
      if (result case Success(:final data)) {
        saved = data.saved;
      } else {
        return;
      }
    }
    final next = !saved!;
    setState(() {
      _saved = next;
      _busy = true;
    });
    _SaveHeart._known[widget.listingId] = next;
    final result = await _repo.setSaved(widget.listingId, next);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result case Failure(:final message)) {
      _SaveHeart._known[widget.listingId] = !next;
      setState(() => _saved = !next);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved ?? false;
    return Semantics(
      button: true,
      selected: saved,
      label: saved ? 'Remove from saved items' : 'Save this product',
      child: GestureDetector(
        key: Key('save-product-${widget.listingId}'),
        onTap: _toggle,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.18)),
          ),
          child: _busy && _saved == null
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: CircularProgressIndicator(strokeWidth: 2,
                      color: BrokaColors.textMid),
                )
              : Icon(
                  saved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 18,
                  color: saved ? BrokaColors.neonPink : Colors.white.withOpacity(0.9),
                ),
        ),
      ),
    );
  }
}
