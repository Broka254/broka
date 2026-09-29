// Home-redesign brief (2026-08-16): listing card rebuilt around the
// product image, with a trader identity row, a single "View Deal" CTA,
// and a condition/freshness badge - see the acceptance-criteria list the
// brief shipped with. Two things in the brief's own mockup were NOT
// implemented because the data doesn't exist anywhere in this codebase:
// a "🛡 99%" trust PERCENTAGE (no Deal Completion Rate has ever existed
// here - see traders/service.py's own note on this) and a "+67% vs avg"
// price comparison (no market-average computation exists). Both would be
// fabricated numbers. What ships instead, using only real fields: a
// verified checkmark (seller_verified) and a star rating
// (seller_rating), shown only when there's an actual rating to show.
//
// `item` is typed dynamic because two different listing models flow
// through this one shared card: the older lib/models/listing.dart
// `Listing` (home feed, Phase 0) and the newer `BrokaListing`
// (lib/features/listings/domain/models/listing.dart) used by every
// repository-based screen from Phase 1 onward (category zones, trending,
// traders' goods tab). They carry the same data but under different
// getter/type shapes (BrokaListing.createdAt is a raw ISO String,
// Listing.createdAt is already a DateTime; BrokaListing has `condition`,
// the older Listing does not) - so getters below are defensive per-field
// rather than assuming one shape.
//
// Photos come back from the API as comma-separated base64 strings, not
// URLs, so the image is decoded locally rather than fetched by URL.
import 'dart:convert';
import 'package:flutter/material.dart';
import '../main.dart';
import '../features/listings/domain/models/listing.dart' show BrokaListing;
import '../utils/backend_time.dart';
import '../utils/land_size.dart';
import '../utils/price_format.dart';
import '../utils/price_unit.dart';
import '../features/categories/domain/category_visual.dart';
import '../models/listing_photo.dart';
import '../theme/motion.dart';
import 'broka_image.dart';

class ProductCard extends StatelessWidget {
  final dynamic item; // Listing or BrokaListing
  final VoidCallback? onTap;
  final VoidCallback? onWishlistTap;
  final bool isWishlisted;
  // Store feature (spec §13). Only ever called for a listing that has a
  // store (see _storeName below) - callers that don't pass this simply
  // get no tap target on the store row, never a crash. Kept as a
  // caller-supplied callback rather than a hardcoded Navigator.push here,
  // matching how onTap/onWishlistTap already work - this card doesn't
  // own navigation decisions.
  final void Function(String storeId, String storeSlug)? onViewStore;

  const ProductCard({
    super.key,
    required this.item,
    this.onTap,
    this.onWishlistTap,
    this.isWishlisted = false,
    this.onViewStore,
  });

  // Category-alignment pass (2026-09-18): this five-entry map was the
  // narrowest of the app's category tables - every listing outside
  // Vehicles/Property/Electronics/Livestock showed 📦 on its card.
  // features/categories/domain/category_visual.dart resolves all sixteen.

  // Home collapsing-scroll pass (2026-09-18, brief §5): the K/M ladder that
  // used to live here is gone - see utils/price_format.dart, which is now
  // the one implementation this, BrokaListing.priceFormatted and HomeScreen's
  // filter panel all share. The extra width a full price needs is handled by
  // scaling the text down in the layout below, not by shortening the number.
  String _formatKes(num v) => formatKes(v);

  String get _title {
    try {
      return (item.name as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  String get _basePriceText {
    if (item is BrokaListing) return (item as BrokaListing).priceFormatted;
    try {
      final formatted = item.formattedPrice as String?;
      if (formatted != null) return formatted;
    } catch (_) {}
    try {
      return _formatKes((item.price as num?) ?? 0);
    } catch (_) {
      return '';
    }
  }

  // "KES 3,500 / bag" when the price is per unit (2026-09-25): a per-bag
  // price shown bare read as the price of the whole lot.
  String get _priceText => PriceUnits.priceLabel(_basePriceText, _priceUnit);

  String? get _priceUnit {
    try {
      return item.priceUnit as String?;
    } catch (_) {
      return null;
    }
  }

  /// The one fact a buyer scanning the grid needs that the photo can't
  /// show: a plot's size ("⅛ acre"), or how many there are ("100 bags").
  String? get _factBadge {
    Map<String, dynamic>? attributes;
    int? quantity;
    try {
      attributes = item.attributes as Map<String, dynamic>?;
      quantity = item.quantity as int?;
    } catch (_) {}
    final land = LandSize.describe(attributes);
    if (land != null) return '📐 $land';
    if (quantity != null && quantity > 1) return PriceUnits.quantity(quantity, _priceUnit);
    return null;
  }

  // location_name is free text the seller typed when listing (e.g.
  // "Bondo,Siaya" with no space) - not something this display layer can
  // fully standardize since it's their own words, but a missing space
  // after a comma is a safe, non-destructive cosmetic normalization
  // (2026-08-18, reported inconsistent formatting between listings).
  String get _locationText {
    try {
      final raw = (item.locationName as String?) ?? 'Kenya';
      return raw.replaceAllMapped(RegExp(r',(\S)'), (m) => ', ${m.group(1)}');
    } catch (_) {
      return 'Kenya';
    }
  }

  String get _emoji {
    if (item is BrokaListing) {
      return CategoryVisuals.emojiFor((item as BrokaListing).category);
    }
    try {
      // The older Listing model has its own emoji getter, which now goes
      // through the same resolver.
      return (item.emoji as String?) ?? CategoryVisuals.fallback.emoji;
    } catch (_) {
      return CategoryVisuals.fallback.emoji;
    }
  }

  // FIX (redesign-guide audit): both models now carry a real
  // seller_verified field from the backend (see listings/service.py
  // _listing_dict) - this used to fall back to "sellerName != null" as a
  // proxy since neither model had a real verified flag at all.
  bool get _showVerifiedBadge {
    try {
      return item.sellerVerified == true;
    } catch (_) {
      return false;
    }
  }

  String? get _sellerName {
    try {
      return item.sellerName as String?;
    } catch (_) {
      return null;
    }
  }

  // Store feature (spec §13) - same defensive try/catch shape as every
  // other getter on this page, since `item` may be either Listing model.
  String? get _storeId {
    try {
      return item.storeId as String?;
    } catch (_) {
      return null;
    }
  }

  String? get _storeName {
    try {
      return item.storeName as String?;
    } catch (_) {
      return null;
    }
  }

  String? get _storeSlug {
    try {
      return item.storeSlug as String?;
    } catch (_) {
      return null;
    }
  }

  // Home-redesign brief §12: "trader selfie" - real photo only, no
  // generated/placeholder face (see listings/service.py's matching
  // addition). Null is the expected common case, not a bug.
  String? get _sellerAvatarUrl {
    try {
      return item.sellerAvatarUrl as String?;
    } catch (_) {
      return null;
    }
  }

  /// The stored cover image (Online Stores phase 1), when the backend has
  /// converted this listing's photos. Null means use the legacy base64.
  ListingPhoto? get _cover {
    try {
      return item.cover as ListingPhoto?;
    } catch (_) {
      return null;
    }
  }

  String? get _sellerPhotoBase64 {
    try {
      return item.sellerProfilePhoto as String?;
    } catch (_) {
      return null;
    }
  }

  // Real 0-5 rating, shown only when > 0 (a seller with no ratings yet
  // showing "★ 0.0" would read as a bad rating, not "no data") - this is
  // the honest substitute for the mockup's fabricated "🛡 99%", not an
  // attempt to reproduce that exact number.
  double get _sellerRating {
    try {
      return (item.sellerRating as num?)?.toDouble() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // FIX (2026-08-18, reported: "a 5.0 rating with 0 reviews/deals is
  // mathematically impossible... users will assume the app is fake/bots"):
  // User.rating defaults to 5.0 at account creation (database.py) and is
  // only ever nudged upward from there on a completed deal - so a brand
  // new seller with zero completed deals shows a perfect, untouched 5.0,
  // indistinguishable from a seller with a real track record. The rating
  // getter above still returns the raw value (never fabricated - it's a
  // real column), but display is gated on _sellerCompletedDeals > 0 below
  // so a rating only renders once there's at least one real deal behind
  // it, not the untouched signup default.
  int get _sellerCompletedDeals {
    try {
      return (item.sellerCompletedDeals as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // Only BrokaListing has this (added Phase 1) - the older Listing model
  // never gained a condition field, so this is null there, not "unknown".
  String? get _condition {
    try {
      return item.condition as String?;
    } catch (_) {
      return null;
    }
  }

  String get _conditionLabel {
    switch (_condition) {
      case 'new': return 'New';
      case 'used': return 'Used';
      case 'refurbished': return 'Refurb.';
      default: return '';
    }
  }

  // Handles both shapes: BrokaListing.createdAt is a raw ISO String,
  // the older Listing.createdAt is already a DateTime. FIX (2026-08-18):
  // both used to go through plain DateTime.tryParse - see backend_time.dart
  // for why that produced a "3h ago" reading on something posted minutes
  // ago. The older Listing model is fixed at its own parse site
  // (models/listing.dart) so by the time it reaches here it's already a
  // correct DateTime; BrokaListing's raw string is parsed correctly here.
  DateTime? get _createdAt {
    try {
      final raw = item.createdAt;
      if (raw is DateTime) return raw;
      if (raw is String) return parseBackendUtc(raw);
    } catch (_) {}
    return null;
  }

  String? get _freshnessText {
    final created = _createdAt;
    if (created == null) return null;
    final diff = DateTime.now().toUtc().difference(created.toUtc());
    if (diff.isNegative || diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }

  List<String> get _photos {
    String? raw;
    try {
      raw = item.verifiedPhotos as String?;
    } catch (_) {
      raw = null;
    }
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  // AI Showcase/Cover Image (2026-08-29). Same defensive dynamic-access
  // pattern as _photos above, since item can be either Listing model.
  String? get _showcaseImageUrl {
    try {
      final v = item.showcaseImageUrl as String?;
      return (v != null && v.isNotEmpty) ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Badge-only signal - "is the currently-displayed image the AI
  /// showcase". Checks that _showcaseImageUrl actually base64-decodes
  /// (mirroring _buildImage()'s own decode step) so a corrupted showcase
  /// value doesn't get the badge if _buildImage() would already reject
  /// it synchronously. One gap this can't close: Image.memory's
  /// errorBuilder (bytes decode fine but aren't a valid image) fires
  /// asynchronously after build, by which point this getter has already
  /// run - that specific case can still show the badge over a fallback
  /// actual photo. Rare enough (both the AI and gallery paths construct
  /// this from real image bytes) not to be worth a stateful widget just
  /// to close it.
  bool get _isAiShowcase {
    final cover = _cover;
    if (cover != null) {
      try {
        return cover.kind == 'showcase' && item.showcaseImageSource == 'ai';
      } catch (_) {
        return false;
      }
    }
    final uri = _showcaseImageUrl;
    if (uri == null) return false;
    try {
      if (item.showcaseImageSource != 'ai') return false;
    } catch (_) {
      return false;
    }
    final payload = _dataUriPayload(uri);
    if (payload == null) return false;
    try {
      base64Decode(payload);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// showcaseImageUrl is a full "data:<mime>;base64,<payload>" string
  /// (see the Listing model comment) - a different shape from
  /// verifiedPhotos's bare comma-separated base64 chunks, so it needs its
  /// own decode step: strip everything up to and including the data-URI
  /// comma before handing the rest to base64Decode.
  String? _dataUriPayload(String dataUri) {
    final idx = dataUri.indexOf(',');
    if (idx == -1 || idx == dataUri.length - 1) return null;
    return dataUri.substring(idx + 1);
  }

  /// displayImage = showcaseImage ?? firstActualImage ?? placeholder.
  /// Showcase is homescreen/discovery-only - View Deal must keep reading
  /// verifiedPhotos directly and never call this getter for its gallery.
  /// Stable id for the Hero tag. `item` is a Listing or a BrokaListing,
  /// both of which expose `.id`; falls back to identityHashCode so a
  /// malformed item degrades to a non-matching tag (no transition) rather
  /// than throwing during layout.
  String get _heroId {
    try {
      final id = (item as dynamic).id;
      if (id is String && id.isNotEmpty) return id;
    } catch (_) {}
    return 'x${identityHashCode(item)}';
  }

  Widget _buildImage() {
    final cover = _cover;
    if (cover != null) {
      return BrokaImage(cover.thumb, placeholder: _placeholder());
    }
    final showcase = _showcaseImageUrl;
    if (showcase != null) {
      final payload = _dataUriPayload(showcase);
      if (payload != null) {
        try {
          return Image.memory(
            base64Decode(payload),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildActualPhotoOrPlaceholder(),
          );
        } catch (_) {
          // Falls through to the actual photo below rather than a broken
          // tile - a bad showcase image should never make a card worse
          // than it would've been without one.
        }
      }
    }
    return _buildActualPhotoOrPlaceholder();
  }

  Widget _buildActualPhotoOrPlaceholder() {
    final photos = _photos;
    if (photos.isNotEmpty) {
      try {
        return Image.memory(
          base64Decode(photos.first),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(),
        );
      } catch (_) {
        return _placeholder();
      }
    }
    return _placeholder();
  }

  Widget _placeholder() => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1B1730), Color(0xFF11101F)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Opacity(
            opacity: 0.85,
            child: Text(_emoji, style: const TextStyle(fontSize: 40)),
          ),
        ),
      );

  // Home-redesign brief round 2 (2026-08-17): bumped from radius 9 (18px
  // diameter) to radius 12 (24px) - trader identity is part of Broka's
  // trust model, not decoration, and 18px read as nearly invisible next to
  // the name/rating it sits beside.
  Widget _traderAvatar() {
    final avatar = BrokaImage.provider(_sellerAvatarUrl);
    if (avatar != null) {
      return CircleAvatar(radius: 10, backgroundImage: avatar);
    }
    final photo = _sellerPhotoBase64;
    if (photo != null && photo.isNotEmpty) {
      try {
        return CircleAvatar(radius: 10, backgroundImage: MemoryImage(base64Decode(photo)));
      } catch (_) {}
    }
    final name = (_sellerName?.isNotEmpty ?? false) ? _sellerName : _storeName;
    final initial = (name?.isNotEmpty ?? false) ? name![0].toUpperCase() : '?';
    return CircleAvatar(
      radius: 10,
      backgroundColor: BrokaColors.gold.withOpacity(0.3),
      child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }

  /// A paid boost that is still running - the same test Home uses to pin a
  /// listing to the top of its feed (HomeScreen._fetchListingsPage), so a
  /// card is never badged without being pinned, or pinned without its badge.
  /// A seller pays for "a glowing FEATURED badge" (boost_screen.dart); until
  /// the 2026-09-29 pass no card drew one. featuredUntil is a DateTime on
  /// the older Listing model and the backend's naive-UTC string on
  /// BrokaListing.
  bool get _isFeaturedNow {
    try {
      if (item.isFeatured != true) return false;
      final raw = item.featuredUntil;
      final until = raw is DateTime ? raw : parseBackendUtc(raw as String?);
      return until != null && until.isAfter(DateTime.now().toUtc());
    } catch (_) {
      return false;
    }
  }

  Color get _conditionTone {
    switch (_condition) {
      case 'new': return BrokaColors.neonGreen;
      case 'refurbished': return BrokaColors.warning;
      default: return BrokaColors.neonCyan;
    }
  }

  // Violet lifted 30% toward white. The brand violet itself is ~3.7:1 on the
  // card and read as dim at 17px; this is ~6:1 and still unmistakably Broka.
  static const Color _priceTint = Color(0xFFAE8DF8);

  // Visual upgrade (2026-09-29). The layout, top to bottom, and why:
  //  * The photo gets the height the full-width "View Deal" bar used to
  //    take. That bar, repeated on every card, was the loudest thing in the
  //    grid - louder than the photos - and the whole card already opens the
  //    deal. The CTA stays, as a round arrow beside the price.
  //  * Then name, price, where and when; who is selling moves to a footer
  //    under a hairline. The seller row used to sit above the product's own
  //    name, so it was the first line a buyer read.
  //  * A live boost gets its FEATURED badge and a brighter brand edge.
  //  * The card sinks a little under a finger (_PressScale), so a tap is felt
  //    before the next screen arrives.
  // ProductGridView's _cardTextBlock is measured against this panel; change
  // one, re-measure the other.
  @override
  Widget build(BuildContext context) {
    // Small-Android type scale (polish pass, 2026-09-18, brief §7/§8). A card
    // column on a 320dp phone is ~120px wide; the same 13.5px title and 17.5px
    // price that read as confident on a 430dp phone read as cramped there.
    // Screen width rather than a LayoutBuilder on purpose - ProductGridView
    // sizes its tiles from the same number, so the two stay in agreement and
    // this costs no extra layout pass per card.
    final compact = MediaQuery.sizeOf(context).width < 360;
    final featured = _isFeaturedNow;
    // Home-redesign brief round 3 (2026-08-18): a thin gradient edge instead
    // of a flat border, via a 1.2px padded outer gradient container. Cheap
    // (one extra Container, no shaders or blurs per card). The one shadow is
    // on featured cards only - a few per page, not every card.
    return _PressScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(1.2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: featured
                ? BrokaColors.brandGradient
                : [BrokaColors.gold.withOpacity(0.45), BrokaColors.neonBlue.withOpacity(0.35)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          boxShadow: featured
              ? [BoxShadow(color: BrokaColors.gold.withOpacity(0.30), blurRadius: 14)]
              : null,
        ),
        child: Container(
          decoration: BoxDecoration(
            gradient: BrokaColors.cardGradient,
            borderRadius: BorderRadius.circular(17),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildPhoto(featured)),
              _buildInfo(compact),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhoto(bool featured) {
    final fact = onWishlistTap == null ? _factBadge : null;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Shared-element transition into the product screen.
        //
        // The app had ZERO Hero widgets. Tapping a card cut to a new screen
        // and re-decoded the same photo from scratch, so the one image the
        // user was looking at visibly disappeared and came back. Carrying it
        // across is the single clearest "this is a modern app" signal
        // available, and it costs one widget at each end.
        //
        // Tag is the listing id, so it is unique per card even when the same
        // product appears in two rails on one screen — Flutter asserts on
        // duplicate tags in a single subtree, and "featured" plus "nearby"
        // showing one listing is a real case here.
        Hero(
          tag: 'listing-photo-$_heroId',
          // The card clips to a rounded rect and the detail view does not,
          // so without this the corners pop square for the duration of the
          // flight.
          flightShuttleBuilder: (_, anim, __, ___, ____) => AnimatedBuilder(
            animation: anim,
            builder: (_, __) => ClipRRect(
              borderRadius: BorderRadius.circular(16 * (1 - anim.value)),
              child: _buildImage(),
            ),
          ),
          child: _buildImage(),
        ),
        // One scrim over the lower half: depth where the photo meets the
        // panel, and contrast for the chip that can sit there. (There were
        // two stacked scrims doing the same job.) One static gradient, no
        // shader or blur per card.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0x00000000), Color(0x66000000)],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
        // Listing facts, top-left and stacked: the FEATURED badge, the
        // condition (Home-redesign brief §16 - nothing when the listing has
        // none, never a guessed one), and on a featured listing the plot
        // size or quantity too. Side by side, FEATURED and a fact badge
        // don't both fit a 320dp card, and one of them would be cut.
        Positioned(
          top: 8, left: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final chip in [
                if (featured) const _FeaturedBadge(),
                if (_conditionLabel.isNotEmpty)
                  _PhotoChip(label: _conditionLabel, dot: _conditionTone),
                if (featured && fact != null) _factChip(fact),
              ])
                Padding(padding: const EdgeInsets.only(bottom: 4), child: chip),
            ],
          ),
        ),
        // Plot size / quantity, top-right - the corner the favourite button
        // would use, which no caller wires yet (see below); it gives way if
        // one ever does.
        if (!featured && fact != null)
          Positioned(top: 8, right: 8, child: _factChip(fact)),
        // Home-redesign brief round 2 (2026-08-17): only render the favorite
        // button when a real callback is actually wired in. There is no
        // wishlist/favorites system anywhere (no model, no endpoint, no
        // repository), and none of this card's callers pass onWishlistTap -
        // so this heart used to bounce convincingly on tap and do nothing.
        // Whoever wires a real wishlist later just needs to pass
        // onWishlistTap/isWishlisted and this reappears working.
        if (onWishlistTap != null)
          Positioned(
            top: 8,
            right: 8,
            child: _FavoriteButton(isWishlisted: isWishlisted, onTap: onWishlistTap),
          ),
        // Showcase spec §18: subtle indicator, AI-generated covers only - a
        // gallery-uploaded cover never gets this label, and this is never a
        // "Verified" badge (listing/seller verification stays fully
        // independent of this - see _showVerifiedBadge above).
        if (_isAiShowcase)
          const Positioned(
            bottom: 8, left: 8,
            child: _PhotoChip(label: '✨ AI Showcase'),
          ),
      ],
    );
  }

  Widget _factChip(String fact) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: _PhotoChip(label: fact, edge: BrokaColors.gold),
      );

  Widget _buildInfo(bool compact) {
    final hasSeller = _sellerName != null && _sellerName!.isNotEmpty;
    final hasStore = _storeName != null && _storeName!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Polish pass (2026-09-18, brief §6/§8): the product name gets two
          // lines. One line ellipsised "Samsung Galaxy A54 128GB Dual SIM"
          // down to "Samsung Galaxy A5…", the half of the title that says
          // least. ProductGridView reserves the second line whether a listing
          // needs it or not; a short title gives the difference to the photo.
          Text(
            _title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                height: 1.22,
                letterSpacing: -0.1,
                fontSize: compact ? 12.5 : 13.5),
          ),
          const SizedBox(height: 5),
          Row(children: [
            // Collapsing-scroll pass (2026-09-18, brief §5/§14): prices are
            // full digit-grouped amounts ("KES 1,450,000", never "1.45M"), so
            // FittedBox scales a long one down instead of ellipsizing it - a
            // truncated price would be worse than a smaller one. scaleDown
            // never enlarges, so a short price renders at full size.
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _priceLabel(compact),
              ),
            ),
            const SizedBox(width: 6),
            // Home-redesign brief §13/§14: one primary CTA. No separate
            // "Offer" action - negotiation happens inside the deal screen
            // this opens, the same place the rest of the card taps through to.
            _ViewDealButton(onTap: onTap, size: compact ? 26 : 28),
          ]),
          const SizedBox(height: 4),
          // Metadata line: deliberately the quietest thing in the panel
          // (brief §6/§8). Name and price are what a buyer scans a grid for;
          // where and when are what they check once something has caught
          // their eye.
          Row(children: [
            Icon(Icons.location_on_outlined,
                size: 11, color: Colors.white.withOpacity(0.42)),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                _locationText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.48),
                    height: 1.15,
                    fontSize: compact ? 10 : 10.5),
              ),
            ),
            if (_freshnessText != null) ...[
              const SizedBox(width: 5),
              Text(_freshnessText!,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.34),
                      height: 1.15,
                      fontSize: compact ? 9.5 : 10)),
            ],
          ]),
          if (hasSeller || hasStore) ...[
            const SizedBox(height: 8),
            Container(height: 1, color: Colors.white.withOpacity(0.06)),
            const SizedBox(height: 7),
            _identityRow(hasStore),
          ],
        ],
      ),
    );
  }

  /// "KES 38,500" with the currency set small and the amount large, and a
  /// per-unit price's " / bag" set small and quiet after it. One Text.rich,
  /// so its plain text is still exactly _priceText.
  Widget _priceLabel(bool compact) {
    final size = compact ? 16.0 : 17.5;
    final base = _basePriceText;
    final full = _priceText;
    final amount = TextStyle(
      color: _priceTint,
      fontWeight: FontWeight.w800,
      height: 1.1,
      letterSpacing: -0.2,
      fontSize: size,
      // Soft on purpose: at 0.5/10 the halo bled into the location row
      // underneath. Size and weight are what make the price read first.
      shadows: [Shadow(color: BrokaColors.gold.withOpacity(0.32), blurRadius: 8)],
    );
    if (!base.startsWith('KES ')) {
      return Text(full, maxLines: 1, softWrap: false, style: amount);
    }
    final small = TextStyle(fontSize: size * 0.62, letterSpacing: 0.3);
    return Text.rich(
      TextSpan(style: amount, children: [
        TextSpan(
            text: 'KES ',
            style: small.copyWith(
                color: _priceTint.withOpacity(0.72), fontWeight: FontWeight.w700)),
        TextSpan(text: base.substring(4)),
        // "KES 3,500 / bag" (2026-09-25): a per-bag price shown bare read
        // as the price of the whole lot.
        if (full.length > base.length)
          TextSpan(
              text: full.substring(base.length),
              style: small.copyWith(
                  color: Colors.white.withOpacity(0.55),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0)),
      ]),
      maxLines: 1,
      softWrap: false,
    );
  }

  // Trader identity (brief §12/§18) - below the image rather than over it,
  // so it never covers product photography (brief §15's explicit priority).
  // One row whether or not the listing is in a store: a store listing names
  // the store where the seller's name would be, beside the seller's own face
  // and record. As a second row it made a store listing's photo shorter than
  // the one next to it, so the photos in a grid row stopped lining up.
  Widget _identityRow(bool hasStore) => Row(children: [
        _traderAvatar(),
        const SizedBox(width: 6),
        Expanded(
          child: hasStore
              ? _storeLink()
              : Text(_sellerName!, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11,
                      height: 1.1, fontWeight: FontWeight.w600)),
        ),
        if (_showVerifiedBadge) ...[
          const SizedBox(width: 3),
          const Icon(Icons.verified, size: 11, color: Color(0xFF4DD6A5)),
        ],
        if (_sellerRating > 0 && _sellerCompletedDeals > 0) ...[
          const SizedBox(width: 3),
          const Icon(Icons.star_rounded, size: 11, color: BrokaColors.gold),
          Text(_sellerRating.toStringAsFixed(1),
              style: const TextStyle(color: _priceTint, fontSize: 10, fontWeight: FontWeight.w700)),
        ] else if (_sellerCompletedDeals == 0 && !hasStore) ...[
          // Not on a store's row: beside the store's name it cut the name to
          // "Kicks K…", and the name is what a buyer can act on. Store
          // details show the owner's record (0 deals, rating "New").
          const SizedBox(width: 4),
          // Polish pass (2026-09-18, brief §6): secondary, not invisible.
          // BrokaColors.textLow on the card was ~1.4:1, past "de-emphasised"
          // and into "cannot be read at all".
          Text('New seller', style: TextStyle(
              color: Colors.white.withOpacity(0.40), fontSize: 9.5,
              height: 1.1, fontStyle: FontStyle.italic)),
        ],
      ]);

  // Store feature (spec §13): a tap target only when the caller can open
  // the store.
  Widget _storeLink() {
    final canOpen = _storeId != null && _storeSlug != null && onViewStore != null;
    return GestureDetector(
      onTap: canOpen ? () => onViewStore!(_storeId!, _storeSlug!) : null,
      behavior: HitTestBehavior.opaque,
      child: Row(children: [
        const Icon(Icons.storefront_rounded, size: 11, color: _priceTint),
        const SizedBox(width: 3),
        Flexible(
          child: Text(_storeName!, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _priceTint, fontSize: 10.5,
                  height: 1.1, fontWeight: FontWeight.w700)),
        ),
        if (canOpen) const Icon(Icons.chevron_right, size: 12, color: _priceTint),
      ]),
    );
  }
}

/// Sinks the card to 97% while a finger is on it. A tap that is recognised
/// only when the next screen appears feels dropped; this answers at once.
/// Nothing moves under reduced motion. Taps that land on something inside
/// the card with its own handler (the store row, the arrow) are theirs: the
/// innermost recogniser wins the arena, and this one just springs back.
class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _PressScale({required this.child, this.onTap});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: tappable ? (_) => _press(true) : null,
      onTapUp: tappable ? (_) => _press(false) : null,
      onTapCancel: tappable ? () => _press(false) : null,
      child: AnimatedScale(
        scale: _down && !BrokaMotion.reduced(context) ? 0.97 : 1.0,
        duration: BrokaMotion.instant,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// A small dark chip over the photo. [dot] is a coloured status light
/// before the label; [edge] a coloured hairline around it.
class _PhotoChip extends StatelessWidget {
  final String label;
  final Color? dot;
  final Color? edge;
  const _PhotoChip({required this.label, this.dot, this.edge});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.58),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            width: 0.8,
            color: edge?.withOpacity(0.6) ?? Colors.white.withOpacity(0.12)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot != null) ...[
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontSize: 10, height: 1.1,
                  fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

/// The badge a boost buys: the same gradient, rocket and lettering as the
/// one boost_screen.dart shows the seller when they pay for it.
class _FeaturedBadge extends StatelessWidget {
  const _FeaturedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 7, 3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.55), blurRadius: 8)],
      ),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.rocket_launch_rounded, size: 10, color: Colors.white),
        SizedBox(width: 3),
        Text('FEATURED',
            style: TextStyle(
                color: Colors.white, fontSize: 9, height: 1.1,
                fontWeight: FontWeight.w900, letterSpacing: 0.6)),
      ]),
    );
  }
}

// Home-redesign brief §23: scale 1 -> 1.25 -> 1 with a small glow burst,
// 200-300ms, on tap - kept as its own small StatefulWidget so the rest of
// ProductCard can stay a plain StatelessWidget.
class _FavoriteButton extends StatefulWidget {
  final bool isWishlisted;
  final VoidCallback? onTap;
  const _FavoriteButton({required this.isWishlisted, this.onTap});

  @override
  State<_FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<_FavoriteButton> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260));
  late final Animation<double> _scale = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.25), weight: 50),
    TweenSequenceItem(tween: Tween(begin: 1.25, end: 1.0), weight: 50),
  ]).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        _ctrl.forward(from: 0);
        widget.onTap?.call();
      },
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.45),
            shape: BoxShape.circle,
            boxShadow: widget.isWishlisted
                ? [const BoxShadow(color: Color(0x55FF4D6D), blurRadius: 8)]
                : null,
          ),
          child: Icon(
            widget.isWishlisted ? Icons.favorite : Icons.favorite_border,
            size: 16,
            color: widget.isWishlisted ? const Color(0xFFFF4D6D) : Colors.white,
          ),
        ),
      ),
    );
  }
}

// Home-redesign brief §14/§24: the card's one CTA. A filled violet gradient
// with a glow (main.dart's GoldButton language), so it reads as the thing to
// press - round beside the price since 2026-09-29, where it used to be a
// full-width bar under everything (see ProductCard.build). Material/InkWell
// for the press ripple rather than another AnimationController.
class _ViewDealButton extends StatelessWidget {
  final VoidCallback? onTap;
  final double size;
  const _ViewDealButton({this.onTap, required this.size});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'View deal',
      child: SizedBox.square(
        dimension: size,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: Ink(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [BrokaColors.gold, BrokaColors.goldDim],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.40), blurRadius: 10)],
            ),
            child: InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              splashColor: Colors.white.withOpacity(0.2),
              child: Icon(Icons.arrow_forward_rounded,
                  size: size * 0.55, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

// Home-redesign brief §28: "premium skeleton with a subtle shimmer". Since
// 2026-09-29 it is the card's own outline - photo, two title lines, price
// and arrow, where/when, seller - so the feed arriving swaps each shape for
// its content instead of swapping a blank tile for a card.
class ProductCardSkeleton extends StatefulWidget {
  const ProductCardSkeleton({super.key});

  @override
  State<ProductCardSkeleton> createState() => _ProductCardSkeletonState();
}

class _ProductCardSkeletonState extends State<ProductCardSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: BrokaColors.cardGradient),
        child: AnimatedBuilder(
          animation: _ctrl,
          // Built once; only the shimmer's shader changes per frame.
          child: const _SkeletonOutline(),
          builder: (context, child) {
            // Sweeps a soft highlight band left-to-right, looping - kept
            // deliberately faint (12% peak opacity) per the brief's "the
            // shimmer should be extremely subtle." srcATop lights only the
            // placeholder shapes, not the gaps between them.
            return ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.white.withOpacity(0.0),
                  Colors.white.withOpacity(0.12),
                  Colors.white.withOpacity(0.0),
                ],
                stops: const [0.35, 0.5, 0.65],
                transform: _SlideGradient(_ctrl.value),
              ).createShader(bounds),
              child: child,
            );
          },
        ),
      ),
    );
  }
}

class _SkeletonOutline extends StatelessWidget {
  const _SkeletonOutline();

  static Widget _bar(double widthFactor, double height) => FractionallySizedBox(
        widthFactor: widthFactor,
        alignment: Alignment.centerLeft,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.07),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      );

  static Widget _dot(double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.07), shape: BoxShape.circle),
      );

  @override
  Widget build(BuildContext context) {
    // The panel below adds up to the card's own (ProductGridView's
    // _cardTextBlock), so the photo block lines up with the photo.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Container(color: Colors.white.withOpacity(0.045))),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 11, 10, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _bar(0.92, 10),
          const SizedBox(height: 6),
          _bar(0.6, 10),
          const SizedBox(height: 9),
          Row(children: [
            Expanded(child: _bar(0.62, 15)),
            const SizedBox(width: 6),
            _dot(28),
          ]),
          const SizedBox(height: 7),
          _bar(0.72, 8),
          const SizedBox(height: 10),
          Container(height: 1, color: Colors.white.withOpacity(0.05)),
          const SizedBox(height: 8),
          Row(children: [
            _dot(20),
            const SizedBox(width: 6),
            Expanded(child: _bar(0.55, 8)),
          ]),
        ]),
      ),
    ]);
  }
}

class _SlideGradient extends GradientTransform {
  final double t; // 0..1
  const _SlideGradient(this.t);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (t * 2.4 - 1.2), 0, 0);
  }
}
