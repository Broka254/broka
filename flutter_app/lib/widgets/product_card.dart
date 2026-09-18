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
import '../utils/price_format.dart';
import '../features/categories/domain/category_visual.dart';

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

  String get _priceText {
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
    final photo = _sellerPhotoBase64;
    if (photo != null && photo.isNotEmpty) {
      try {
        return CircleAvatar(radius: 10, backgroundImage: MemoryImage(base64Decode(photo)));
      } catch (_) {}
    }
    final initial = (_sellerName?.isNotEmpty ?? false) ? _sellerName![0].toUpperCase() : '?';
    return CircleAvatar(
      radius: 10,
      backgroundColor: BrokaColors.gold.withOpacity(0.3),
      child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Small-Android type scale (polish pass, 2026-09-18, brief §7/§8). A card
    // column on a 320dp phone is ~120px wide; the same 13.5px title and 17.5px
    // price that read as confident on a 430dp phone read as cramped there.
    // Screen width rather than a LayoutBuilder on purpose - ProductGridView
    // sizes its tiles from the same number, so the two stay in agreement and
    // this costs no extra layout pass per card.
    final compact = MediaQuery.sizeOf(context).width < 360;
    // Home-redesign brief round 3 (2026-08-18): "make it super attractive
    // and futuristic" - a thin gradient edge (purple -> blue, matching the
    // app's own brand gradient) instead of a flat single-color border,
    // via a 1.2px padded outer gradient container wrapping the actual
    // card body. Cheap (one extra Container, no shaders/blurs per card)
    // so it doesn't reintroduce the "blur on every card" performance risk
    // flagged in the original brief.
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(1.2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: [BrokaColors.gold.withOpacity(0.45), BrokaColors.neonBlue.withOpacity(0.35)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
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
              Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Shared-element transition into the product screen.
                  //
                  // The app had ZERO Hero widgets. Tapping a card cut to a
                  // new screen and re-decoded the same photo from scratch,
                  // so the one image the user was looking at visibly
                  // disappeared and came back. Carrying it across is the
                  // single clearest "this is a modern app" signal available,
                  // and it costs one widget at each end.
                  //
                  // Tag is the listing id, so it is unique per card even
                  // when the same product appears in two rails on one
                  // screen — Flutter asserts on duplicate tags in a single
                  // subtree, and "featured" plus "nearby" showing one
                  // listing is a real case here.
                  Hero(
                    tag: 'listing-photo-${_heroId}',
                    // The card clips to a rounded rect and the detail view
                    // does not, so without this the corners pop square for
                    // the duration of the flight.
                    flightShuttleBuilder: (_, anim, __, ___, ____) =>
                        AnimatedBuilder(
                      animation: anim,
                      builder: (_, __) => ClipRRect(
                        borderRadius: BorderRadius.circular(
                            16 * (1 - anim.value)),
                        child: _buildImage(),
                      ),
                    ),
                    child: _buildImage(),
                  ),
                  // Home-redesign brief round 3 (2026-08-18): a faint
                  // bottom-edge scrim - purely a depth/polish cue (helps
                  // the badge/favorite icons above read as "layered" over
                  // the photo rather than flat), not for text legibility
                  // since no text sits over the image in this layout.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.transparent, Color(0x33000000)],
                        stops: [0.0, 0.7, 1.0],
                      ),
                    ),
                  ),
                  // Home-redesign brief round 3 (2026-08-18): a soft
                  // bottom scrim gives the image area more depth (a flat
                  // photo edge-to-edge into the info panel read as plain)
                  // and doubles as extra legibility contrast for the
                  // condition badge above it - one static gradient, no
                  // shader/blur cost per card.
                  Positioned(
                    left: 0, right: 0, bottom: 0, height: 40,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter, end: Alignment.bottomCenter,
                          colors: [Colors.black.withOpacity(0.0), Colors.black.withOpacity(0.35)],
                        ),
                      ),
                    ),
                  ),
                  // Home-redesign brief §16: condition badge, top-left.
                  // Falls back to nothing rather than a fabricated
                  // condition when the listing genuinely has none set.
                  if (_conditionLabel.isNotEmpty)
                    Positioned(
                      top: 8, left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(_conditionLabel, style: const TextStyle(
                            color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  // Home-redesign brief round 2 (2026-08-17): only render
                  // the favorite button when a real callback is actually
                  // wired in. Grepped this whole codebase - there is no
                  // wishlist/favorites system anywhere (no model, no
                  // endpoint, no repository), and none of this card's
                  // current callers (Home's feed, search results,
                  // ProductGridView) ever passed onWishlistTap - so this
                  // heart bounced convincingly on tap and did nothing.
                  // "A fake interaction is worse than no interaction":
                  // omitting it entirely until a real wishlist exists is
                  // more honest than a disabled-looking icon that still
                  // invites a tap. The animation/State code stays as-is -
                  // whoever wires a real wishlist later just needs to pass
                  // onWishlistTap/isWishlisted and this reappears working.
                  if (onWishlistTap != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _FavoriteButton(isWishlisted: isWishlisted, onTap: onWishlistTap),
                    ),
                  // Showcase spec §18: subtle indicator, AI-generated
                  // covers only - a gallery-uploaded cover never gets
                  // this label, and this is never a "Verified" badge
                  // (listing/seller verification stays fully independent
                  // of this - see _showVerifiedBadge above, untouched).
                  // Bottom-left: both top corners are already taken by
                  // the condition badge and favorite button.
                  if (_isAiShowcase)
                    Positioned(
                      bottom: 8, left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('✨ AI Showcase', style: TextStyle(
                            color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w600)),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Trader identity row (brief §12/§18) - placed below the
                  // image rather than overlaid on it, so it never covers
                  // product photography (brief §15's explicit priority).
                  if (_sellerName != null && _sellerName!.isNotEmpty) ...[
                    Row(children: [
                      _traderAvatar(),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_sellerName!, maxLines: 1, overflow: TextOverflow.ellipsis,
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
                            style: const TextStyle(color: BrokaColors.gold, fontSize: 10, fontWeight: FontWeight.w700)),
                      ] else if (_sellerCompletedDeals == 0) ...[
                        const SizedBox(width: 4),
                        // Polish pass (2026-09-18, brief §6): secondary, not
                        // invisible. This was BrokaColors.textLow (#2E3D5A) on
                        // a #111D35 card - about 1.4:1 contrast, which is past
                        // "de-emphasised" and into "cannot be read at all".
                        // A dimmed white keeps it clearly subordinate to the
                        // seller name beside it while staying legible.
                        Text('New seller', style: TextStyle(
                            color: Colors.white.withOpacity(0.40), fontSize: 9.5,
                            height: 1.1, fontStyle: FontStyle.italic)),
                      ],
                    ]),
                    const SizedBox(height: 5),
                  ],
                  if (_storeName != null && _storeName!.isNotEmpty) ...[
                    GestureDetector(
                      onTap: (_storeId != null && _storeSlug != null && onViewStore != null)
                          ? () => onViewStore!(_storeId!, _storeSlug!)
                          : null,
                      child: Row(children: [
                        const Icon(Icons.storefront_rounded, size: 11, color: BrokaColors.gold),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(_storeName!, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: BrokaColors.gold, fontSize: 10,
                                  fontWeight: FontWeight.w700)),
                        ),
                        if (onViewStore != null) ...[
                          const SizedBox(width: 2),
                          const Icon(Icons.chevron_right, size: 12, color: BrokaColors.gold),
                        ],
                      ]),
                    ),
                    const SizedBox(height: 5),
                  ],
                  // Polish pass (2026-09-18, brief §6/§8): the product name is
                  // the strongest text on the card after the price, and it now
                  // gets two lines. One line ellipsised "Samsung Galaxy A54
                  // 128GB Dual SIM" down to "Samsung Galaxy A5…", which is the
                  // half of the title that says least. ProductGridView reserves
                  // the second line in its tile height whether a listing needs
                  // it or not, so allowing it here never costs the photo on a
                  // card whose title is short.
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
                  const SizedBox(height: 4),
                  // Home-redesign brief round 3 (2026-08-18): bumped size
                  // and added a soft glow so price reads as the clear
                  // first stop for the eye, ahead of the CTA below it -
                  // previously both price and button used the same gold
                  // color/weight and visually competed.
                  // Home collapsing-scroll pass (2026-09-18, brief §5/§14):
                  // prices are full digit-grouped amounts now ("KES 125,000",
                  // not "KES 125K"), so the string can be roughly twice as
                  // wide as before on an expensive listing. FittedBox scales
                  // it down to fit the card instead of ellipsizing it - a
                  // truncated price ("KES 1,500,0…") would be worse than a
                  // smaller one, and a wrapped one would push the CTA out of
                  // the card. Cheap prices are unaffected: scaleDown only
                  // ever shrinks, never enlarges, so KES 250 still renders at
                  // the full 16px.
                  SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _priceText,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          color: BrokaColors.gold,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                          letterSpacing: -0.2,
                          fontSize: compact ? 16 : 17.5,
                          // Softer than the previous 0.5/10 glow. At full
                          // strength the halo bled into the location row
                          // underneath and made the whole panel look hazy;
                          // the price still reads first because of size and
                          // weight, which is a steadier way to win than bloom.
                          shadows: [Shadow(color: BrokaColors.gold.withOpacity(0.32), blurRadius: 8)],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  // Metadata line: kept, but deliberately the quietest thing
                  // in the panel (brief §6/§8). Name and price are what a
                  // buyer scans a grid for; where and when are what they check
                  // once something has already caught their eye.
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
                  const SizedBox(height: 8),
                  // Home-redesign brief §13/§14: single primary CTA. No
                  // separate "Offer" action here - negotiation happens
                  // inside the deal/listing detail screen this navigates
                  // to, same destination the rest of the card already
                  // taps through to.
                  _ViewDealButton(onTap: onTap),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
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

// Home-redesign brief §14/§24: full-width, rounded, subtle glow, scale
// feedback on press. Uses Material/InkWell for the press ripple rather
// than a custom AnimationController - standard, cheap, and already gives
// the "scale/press feedback" the brief asks for without adding another
// animation to maintain.
// Home-redesign brief §14/§24, redesigned round 3 (2026-08-18): a solid
// gradient fill (borrowing main.dart's GoldButton visual language -
// [gold, goldDim] + a glow shadow - scaled down for a compact grid card)
// instead of an outline-only button in the same gold tone as the price
// text above it. A filled CTA reads as clearly more "clickable" than a
// bordered one, and no longer visually competes with the price for the
// same color weight (Meta AI review, point 5: "price and CTA compete
// visually... make CTA stand out"). Uses Material/InkWell for the press
// ripple rather than a custom AnimationController - cheap, standard, and
// already gives press feedback without another animation to maintain.
class _ViewDealButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _ViewDealButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      // 32 -> 30 (polish pass, brief §6). Two pixels back to the photo on
      // every card; the CTA is still a comfortable target, and the entire
      // card behind it already navigates to the same place.
      height: 30,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
            boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.35), blurRadius: 10)],
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(9),
            splashColor: Colors.white.withOpacity(0.2),
            // FittedBox (collapsing-scroll pass, 2026-09-18, brief §27/§28):
            // "View Deal →" needs ~123px and a card column on a 320dp phone
            // is 119.6px wide, so this Row overflowed by 3.2px on every card
            // on a small Android screen. Scaling down is the right answer
            // rather than shortening the label or ellipsizing a 9-character
            // CTA; on every wider screen scaleDown is a no-op and the button
            // renders exactly as before.
            child: const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('View Deal', style: TextStyle(
                        color: BrokaColors.bg, fontWeight: FontWeight.w800, fontSize: 11.5)),
                    SizedBox(width: 4),
                    Icon(Icons.arrow_forward_rounded, size: 13, color: BrokaColors.bg),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Home-redesign brief §28: "premium skeleton with a subtle shimmer" -
// this previously was a flat static gradient box with no shimmer at all.
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
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(gradient: BrokaColors.cardGradient, borderRadius: BorderRadius.circular(16)),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, child) {
            // Sweeps a soft highlight band left-to-right, looping - kept
            // deliberately faint (12% peak opacity) per the brief's "the
            // shimmer should be extremely subtle."
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
              child: Container(color: BrokaColors.bgCard.withOpacity(0.4)),
            );
          },
        ),
      ),
    );
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
