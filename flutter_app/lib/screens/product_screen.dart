// BROKA - Product Detail Screen
// Large photos, listing date/time, maps with ±1km disclaimer, distance,
// the deal's terms, the seller and their standing, and Zeno.
//
// 2026-09-29, on Home's visual system: the constellation, Home's header
// language (back chevron, the category's badge and glowing name), cards with
// the product card's gradient edge, and the brand gradient on the one CTA.
// Three things moved to where a buyer looks first:
//
//  * DEAL TERMS - fixed price or negotiable, and whether the seller can
//    deliver - as two tiles of their own. They were two of ten small chips,
//    and they decide whether a buyer should start the conversation at all.
//  * The seller's standing - the seller dashboard's overall rating, deal
//    completion rate and response time, in the dashboard's own colours
//    (models/seller_standing.dart). It replaces a "credibility" score this
//    screen made up from the star rating and deal count. Since 2026-09-30
//    also how long the seller's deals take, agreement to payout
//    (widgets/seller_standing_tiles.dart, shared with their profile).
//
// Also 2026-09-30: a listing opened from a link, a notification or a chat
// can be sold out or deleted - every list a buyer browses leaves those out.
// It says which, instead of offering to negotiate for something the seller
// no longer has; and a listing of several units says how many are left.
//  * ZENO INSIGHT - opens Zeno about this listing (ZenoScreen.aboutListing),
//    where the buyer asks what they need to know and Zeno offers to find
//    another listing when this one doesn't fit. It was a panel that asked the
//    model for a one-off verdict, and a price comparison against an endpoint
//    that is never mounted (api/routers/listings.py), so it always said there
//    was nothing to compare.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../features/categories/domain/category_visual.dart';
import '../features/stores/data/store_cart.dart';
import '../features/stores/presentation/store_cart_screen.dart';
import '../features/zeno_assistant/domain/zeno_about_listing.dart';
import '../main.dart';
import '../models/listing.dart';
import '../models/seller_names.dart';
import '../models/seller_standing.dart';
import '../services/api_service.dart';
import '../services/last_screen_tracker.dart';
import '../utils/handover.dart';
import '../utils/land_size.dart';
import '../utils/price_unit.dart';
import '../utils/auth_gate.dart';
import '../utils/backend_time.dart';
import '../widgets/broka_image.dart';
import '../widgets/constellation_background.dart';
import '../widgets/motion_widgets.dart';
import '../widgets/seller_standing_tiles.dart';
import '../widgets/zeno_avatar.dart';
import 'zeno_screen.dart';

class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  Listing? _listing;
  int _photoIndex = 0;
  Map<String, dynamic>? _sellerInfo;

  /// The seller's profile has answered, with or without a standing. Until
  /// then the standing tiles are placeholders, not "not measured yet".
  bool _sellerLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listing == null) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Listing) {
        _listing = args;
        _loadSeller();
        LastScreenTracker.save('/product', {'listingId': args.id});
      } else if (args is Map && args['listingId'] is String) {
        // Restored from a relaunch - we only persisted the ID, fetch fresh.
        _loadListingById(args['listingId'] as String);
      }
    }
  }

  Future<void> _loadListingById(String listingId) async {
    try {
      final listing = await ApiService.getListing(listingId);
      if (!mounted) return;
      setState(() => _listing = listing);
      _loadSeller();
      LastScreenTracker.save('/product', {'listingId': listingId});
    } catch (_) {
      // Listing may have been deleted/sold since the app was last open.
      if (mounted) Navigator.pushReplacementNamed(context, '/home');
    }
  }

  Future<void> _loadSeller() async {
    final sid = _listing?.sellerId;
    if (sid == null) {
      // Called just as the listing arrives; the build that shows it is
      // already on its way.
      _sellerLoaded = true;
      return;
    }
    try {
      final info = await ApiService.getUserProfile(sid);
      if (mounted) setState(() => _sellerInfo = info);
    } catch (_) {}
    if (mounted) setState(() => _sellerLoaded = true);
  }

  /// The seller dashboard's rating, completion rate and response time, and
  /// the seller's deal time, as buyers are shown them. Prefer the authenticated
  /// profile when it has standing data, but fall back to the public listing
  /// snapshot so the product screen does not render empty tiles while the
  /// profile request is unavailable or delayed.
  SellerStanding get _standing {
    if (_sellerInfo?['seller_standing'] != null) {
      return SellerStanding.fromProfile(_sellerInfo);
    }
    final l = _listing;
    if (l == null) return const SellerStanding();
    return SellerStanding.fromListing({
      'seller_standing': l.sellerStanding,
      'seller_completed_deals': l.sellerCompletedDeals,
      'seller_dcr': l.sellerDcr,
      'seller_dcr_provisional': l.sellerDcrProvisional,
      'seller_response_minutes': l.sellerResponseMinutes,
      'seller_avg_deal_time_minutes': l.sellerAvgDealTimeMinutes,
      'seller_timed_deals': l.sellerTimedDeals,
    });
  }

  /// Gallery sources, first photo first: the stored images' large size
  /// when the listing has them, else the legacy base64 photos. BrokaImage
  /// renders either.
  List<String> get _photos {
    final stored = _listing?.photos ?? const [];
    if (stored.isNotEmpty) return stored.map((p) => p.large).toList();
    final raw = _listing?.verifiedPhotos;
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  bool get _isMine => _listing?.sellerId == ApiService.currentUserId;
  bool get _isAuction => _listing?.listingType == 'auction';

  /// Deleted by its seller (the backend's "cancelled").
  bool get _removed => _listing?.status == 'cancelled';

  /// Nothing left to buy: deleted, or every unit sold or in a deal.
  bool get _unavailable => _removed || (_listing?.soldOut ?? false);

  double? get _distanceKm {
    final myLat = ApiService.currentUserLat;
    final myLng = ApiService.currentUserLng;
    final sLat  = _listing?.sellerLat ?? (_sellerInfo?['lat'] as num?)?.toDouble();
    final sLng  = _listing?.sellerLng ?? (_sellerInfo?['lng'] as num?)?.toDouble();
    if (myLat == null || myLng == null || sLat == null || sLng == null) return null;
    // Reject "null island" — (0,0) means the GPS was never acquired.
    if (myLat.abs() < 0.05 && myLng.abs() < 0.05) return null;
    if (sLat.abs()  < 0.05 && sLng.abs()  < 0.05) return null;
    return _haversineKm(myLat, myLng, sLat, sLng);
  }

  bool get _hasMapData =>
      (_listing?.sellerLat != null && _listing?.sellerLng != null);

  String get _listingDateLabel {
    final dt = _listing?.createdAt;
    final months = ['Jan','Feb','Mar','Apr','May','Jun',
                    'Jul','Aug','Sep','Oct','Nov','Dec'];
    if (dt != null) return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    // Fallback: today (createdAt not returned by backend yet)
    final now = DateTime.now();
    return '${months[now.month - 1]} ${now.day}, ${now.year}';
  }

  double? get _travelCostEstimate {
    final d = _distanceKm;
    if (d == null) return null;
    // Matatu fare approx KES 5-8/km + base 30
    return 30 + d * 6.5;
  }

  // ── Zeno ──────────────────────────────────────────────────────────────────

  /// Opens Zeno about this listing, optionally with a question already
  /// asked. Zeno's answers are model calls made on the user's account, so a
  /// guest is asked to sign in first - the same sheet as every other
  /// account-gated action.
  Future<void> _openZeno([String? question]) async {
    final l = _listing;
    if (l == null) return;
    if (!await requireAuth(context, reason: 'to ask Zeno about this listing')) return;
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ZenoScreen(
        aboutListing: ZenoAboutListing.fromListing(l),
        initialQuery: question,
      ),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l = _listing;
    if (l == null) {
      return Scaffold(
        backgroundColor: BrokaColors.bg,
        body: ConstellationBackground(
          animate: widget.animateBackground,
          child: const Center(child: CircularProgressIndicator(color: BrokaColors.gold)),
        ),
      );
    }
    final tint = CategoryVisuals.gradientFor(l.category).first;
    final sections = <Widget>[
      _buildMediaSection(l),
      _buildInfoSection(l),
      _buildDealTerms(l),
      _buildSellerSection(l),
      if (_hasMapData) _buildMapPreview(l),
      _buildDescSection(l),
      _buildZenoInsight(l),
    ];
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // The constellation Home and every screen reached from it sit on, with
      // the listing's category colour washing down from the top the way it
      // does in the category's Zone.
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.2,
              colors: [tint.withOpacity(0.13), Colors.transparent],
              stops: const [0.0, 0.55],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(children: [
              _buildHeader(l),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (int i = 0; i < sections.length; i++)
                        FadeSlideIn(index: i, child: sections[i]),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
      bottomNavigationBar: _isMine ? null : (_unavailable ? _buildUnavailableBar() : _buildCTA(l)),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  /// The header every screen reached from Home wears: a bare back chevron,
  /// the category's badge and glowing name, and what kind of sale this is.
  Widget _buildHeader(Listing l) {
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final gradient = CategoryVisuals.gradientFor(l.category);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
      child: Row(children: [
        IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textHigh, size: 19),
        ),
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [
              gradient.first.withOpacity(0.28),
              gradient.last.withOpacity(0.14),
            ]),
            border: Border.all(color: gradient.first.withOpacity(0.5)),
          ),
          child: Text(l.emoji, style: const TextStyle(fontSize: 16)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ZoneGlowText(
            l.category,
            gradient: gradient,
            fontSize: narrow ? 17 : 19,
            maxLines: 1,
            letterSpacing: narrow ? 0.8 : 1.1,
          ),
        ),
        const SizedBox(width: 8),
        _saleTypeBadge(l),
      ]),
    );
  }

  Widget _saleTypeBadge(Listing l) {
    final color = _isAuction ? BrokaColors.danger : BrokaColors.gold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(_isAuction ? '⬤ LIVE AUCTION' : 'DIRECT SALE',
          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800,
              letterSpacing: 0.6, color: color)),
    );
  }

  // ── Shared pieces ─────────────────────────────────────────────────────────

  Widget _secLabel(String t) => Text(t, style: const TextStyle(
      color: BrokaColors.textMid, fontSize: 11,
      fontWeight: FontWeight.w700, letterSpacing: 1.3));

  /// Home's product card surface: the card gradient inside a thin
  /// violet-to-blue edge.
  Widget _edgedCard({
    required Widget child,
    List<Color>? edge,
    EdgeInsets padding = const EdgeInsets.all(14),
    double radius = 16,
  }) => Container(
    padding: const EdgeInsets.all(1.2),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        colors: edge ?? [BrokaColors.gold.withOpacity(0.45), BrokaColors.neonBlue.withOpacity(0.35)],
        begin: Alignment.topLeft, end: Alignment.bottomRight,
      ),
    ),
    child: Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        gradient: BrokaColors.cardGradient,
        borderRadius: BorderRadius.circular(radius - 1),
      ),
      child: child,
    ),
  );

  // ── Media ─────────────────────────────────────────────────────────────────

  Widget _buildMediaSection(Listing l) {
    final photos = _photos;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: _edgedCard(
        padding: EdgeInsets.zero,
        radius: 18,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: photos.isNotEmpty
              ? _buildPhotoGallery(photos)
              : SizedBox(
                  height: 260,
                  child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(l.emoji, style: const TextStyle(fontSize: 64)),
                    const SizedBox(height: 8),
                    const Text('No media available',
                        style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                  ])),
                ),
        ),
      ),
    );
  }

  Widget _buildPhotoGallery(List<String> photos) {
    return Stack(children: [
      SizedBox(
        height: 320,
        // Receiving end of the card's Hero. Only the FIRST photo carries
        // the tag: that is the one the card was showing, and two widgets
        // claiming the same tag in one subtree is an assertion failure, not
        // a nicer animation.
        child: PageView.builder(
          onPageChanged: (i) => setState(() => _photoIndex = i),
          itemCount: photos.length,
          itemBuilder: (_, i) {
            final img = BrokaImage(photos[i],
                width: double.infinity, placeholder: _photoFallback());
            final id = _listing?.id;
            return (i == 0 && id != null && id.isNotEmpty)
                ? Hero(tag: 'listing-photo-$id', child: img)
                : img;
          },
        ),
      ),
      // Page indicator dots
      if (photos.length > 1)
        Positioned(bottom: 44, left: 0, right: 0,
          child: Row(mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(photos.length, (i) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: _photoIndex == i ? 14 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: _photoIndex == i
                    ? BrokaColors.gold : Colors.white38,
                borderRadius: BorderRadius.circular(3),
              ),
            )),
          )),
      // Photo counter
      Positioned(top: 12, right: 12,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black54, borderRadius: BorderRadius.circular(20)),
          child: Text('${_photoIndex + 1}/${photos.length}',
              style: const TextStyle(color: Colors.white, fontSize: 11,
                  fontWeight: FontWeight.w700)),
        )),
      // Date badge
      Positioned(bottom: 12, left: 12, child: _dateBadge()),
    ]);
  }

  Widget _photoFallback() => Container(
    color: BrokaColors.bgCard,
    child: Center(child: Text(_listing!.emoji,
        style: const TextStyle(fontSize: 64, color: Colors.white))),
  );

  Widget _dateBadge() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.black54, borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.calendar_today_rounded, size: 10, color: Colors.white70),
      const SizedBox(width: 5),
      Text('Listed $_listingDateLabel',
          style: const TextStyle(color: Colors.white, fontSize: 10,
              fontWeight: FontWeight.w600)),
    ]),
  );

  // ── Info ──────────────────────────────────────────────────────────────────

  Widget _buildInfoSection(Listing l) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.name, style: const TextStyle(color: BrokaColors.textHigh,
              fontSize: 22, fontWeight: FontWeight.w800, height: 1.2)),
          const SizedBox(height: 8),
          ShaderMask(
            shaderCallback: (b) => const LinearGradient(
                colors: [BrokaColors.gold, BrokaColors.neonBlue])
                .createShader(b),
            child: Text(PriceUnits.priceLabel(l.formattedPrice, l.priceUnit), style: const TextStyle(
                color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
          ),
        ])),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: BrokaColors.neonGreen.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.remove_red_eye_rounded,
                size: 13, color: BrokaColors.neonGreen),
            const SizedBox(width: 5),
            Text('${l.views} views', style: const TextStyle(
                color: BrokaColors.neonGreen, fontSize: 11,
                fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _chip(l.category, Icons.category_rounded, BrokaColors.neonBlue),
        if (LandSize.describe(l.attributes) != null)
          _chip(LandSize.describe(l.attributes)!, Icons.straighten_rounded, BrokaColors.neonGreen),
        if (_unitsLabel(l) case final units?)
          KeyedSubtree(
            key: const Key('units-left'),
            child: _chip(units, Icons.inventory_2_outlined, BrokaColors.neonCyan),
          ),
        if (l.locationName != null)
          _chip(l.locationName!, Icons.location_on_rounded, BrokaColors.gold),
        if (_distanceKm != null)
          _chip('~${_distanceKm!.toStringAsFixed(1)} km from you (±1km)',
              Icons.near_me_rounded, BrokaColors.gold),
      ]),
    ]),
  );

  Widget _chip(String label, IconData icon, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 11, color: color),
      const SizedBox(width: 5),
      Flexible(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      ),
    ]),
  );

  // ── Deal terms ────────────────────────────────────────────────────────────

  /// Fixed price or negotiable, and whether the seller delivers: the two
  /// answers that decide whether this is worth starting a conversation
  /// about, as the seller gave them in the sell wizard.
  Widget _buildDealTerms(Listing l) {
    final (priceTitle, priceBody, priceIcon, priceColor) = _isAuction
        ? ('Auction', 'Bids decide the price', Icons.gavel_rounded, BrokaColors.danger)
        : l.priceNegotiable
            ? ('Negotiable', 'Make an offer - Zeno negotiates it for you',
                Icons.handshake_outlined, BrokaColors.neonGreen)
            : ('Fixed price', 'The seller takes the asking price, no offers',
                Icons.lock_outline_rounded, BrokaColors.neonPink);
    final note = (l.deliveryNote ?? '').trim();
    final (deliveryTitle, deliveryBody, deliveryIcon, deliveryColor) =
        !isDeliverableCategory(l.category)
            ? (inPlaceTitle, inPlaceBody, Icons.place_outlined, BrokaColors.neonBlue)
            : switch (l.deliveryAvailable) {
      true =>('Seller delivers', note.isEmpty ? 'The seller can arrange delivery' : note,
          Icons.local_shipping_outlined, BrokaColors.neonBlue),
      false => ('Pickup only', 'You collect it from the seller',
          Icons.storefront_outlined, BrokaColors.warning),
      null => ('Delivery not stated', 'Ask the seller before you pay',
          Icons.help_outline_rounded, BrokaColors.textMid),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _secLabel('DEAL TERMS'),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _termTile(
              key: const Key('deal-term-price'),
              label: 'PRICE', title: priceTitle, body: priceBody,
              icon: priceIcon, color: priceColor,
            )),
            const SizedBox(width: 10),
            Expanded(child: _termTile(
              key: const Key('deal-term-delivery'),
              label: 'DELIVERY', title: deliveryTitle, body: deliveryBody,
              icon: deliveryIcon, color: deliveryColor,
            )),
          ]),
        ),
      ]),
    );
  }

  /// A listing of several units: "100 bags available", or "12 of 100 bags
  /// left" once some are sold or in deals. The count left comes from the
  /// single-listing read; a listing opened from a list shows the total.
  /// Nothing for a single item, or when there is nothing left to buy.
  String? _unitsLabel(Listing l) {
    final total = l.quantity ?? 1;
    if (total <= 1 || _unavailable) return null;
    final left = l.unitsLeft;
    if (left == null || left >= total) return '${PriceUnits.quantity(total, l.priceUnit)} available';
    return '$left of ${PriceUnits.quantity(total, l.priceUnit)} left';
  }

  Widget _termTile({
    required Key key,
    required String label,
    required String title,
    required String body,
    required IconData icon,
    required Color color,
  }) => Semantics(
    key: key,
    container: true,
    label: '$label: $title. $body',
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.all(1.2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [color.withOpacity(0.75), color.withOpacity(0.2)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        boxShadow: [BoxShadow(color: color.withOpacity(0.14), blurRadius: 14)],
      ),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            Color.alphaBlend(color.withOpacity(0.14), BrokaColors.bgCard),
            BrokaColors.cardGradColors.last,
          ], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withOpacity(0.18),
                border: Border.all(color: color.withOpacity(0.6)),
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 9.5,
                      fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            ),
          ]),
          const SizedBox(height: 10),
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color == BrokaColors.textMid ? BrokaColors.textHigh : color,
                  fontSize: 15, fontWeight: FontWeight.w800, height: 1.2)),
          const SizedBox(height: 4),
          Text(body, maxLines: 3, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11, height: 1.35)),
        ]),
      ),
    ),
  );

  // ── Seller ────────────────────────────────────────────────────────────────

  Widget _buildSellerSection(Listing l) {
    final names = SellerNames.of(listingName: l.sellerName, profile: _sellerInfo);
    final sellerName = names.headline;
    final deals = l.sellerCompletedDeals
        ?? (_sellerInfo?['completed_deals'] as num?)?.toInt() ?? 0;
    final verified = _sellerInfo?['is_verified'] as bool? ?? l.sellerVerified;
    // The selfie, else the stored avatar the listing carries. An empty
    // string is no photo, so it must not stop the fallback.
    final photo = [
      _sellerInfo?['profile_photo'] as String?,
      l.sellerProfilePhoto,
      l.sellerAvatarUrl,
    ].firstWhere((p) => p != null && p.trim().isNotEmpty, orElse: () => null);
    final location = _sellerInfo?['location_name'] as String? ?? l.locationName;
    final memberSince = _sellerInfo?['created_at'] as String?;

    // The server's own reading of last_seen (api/core/presence.py), the one
    // the chat header and inbox show. This screen parsed last_seen itself,
    // as local time - it is naive UTC - so in Kenya every seller was "3h
    // ago" at best (utils/backend_time.dart).
    final online = _sellerInfo?['is_online'] == true;
    final lastSeenLabel = online
        ? 'Online now'
        : (_sellerInfo?['last_seen_label'] as String? ?? 'Unknown');

    String memberLabel = '';
    final joined = parseBackendUtc(memberSince)?.toLocal();
    if (joined != null) {
      const months = ['Jan','Feb','Mar','Apr','May','Jun',
                      'Jul','Aug','Sep','Oct','Nov','Dec'];
      memberLabel = 'Since ${months[joined.month - 1]} ${joined.year}';
    }

    final initial = Center(child: Text(
        sellerName.isEmpty ? '?' : sellerName[0].toUpperCase(),
        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _secLabel('SELLER'),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, '/user-profile',
              arguments: l.sellerId),
          child: _edgedCard(
            child: Column(children: [
              Row(children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                        colors: [BrokaColors.gold, BrokaColors.goldDim]),
                    border: Border.all(
                      color: verified ? BrokaColors.gold
                          : BrokaColors.gold.withOpacity(0.4), width: 2),
                  ),
                  child: ClipOval(
                    child: photo != null && photo.isNotEmpty
                        ? BrokaImage(photo, width: 52, height: 52, placeholder: initial)
                        : initial,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (names.officialName != null) ...[
                      const Icon(Icons.storefront_rounded, color: BrokaColors.gold, size: 16),
                      const SizedBox(width: 5),
                    ],
                    Flexible(child: Text(sellerName, maxLines: 1, overflow: TextOverflow.ellipsis,
                        key: const Key('seller-card-name'),
                        style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                            fontWeight: FontWeight.w700))),
                    if (verified) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.verified_rounded, color: BrokaColors.gold, size: 18),
                    ],
                  ]),
                  // A business is shown under its own name; the person
                  // behind it is named too, so a buyer knows who they're
                  // dealing with as well as which shop.
                  if (names.officialName != null) ...[
                    const SizedBox(height: 3),
                    Row(children: [
                      const Icon(Icons.person_outline_rounded,
                          color: BrokaColors.textMid, size: 14),
                      const SizedBox(width: 5),
                      Flexible(child: Text(names.officialName!,
                          key: const Key('seller-card-official-name'),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: BrokaColors.textHigh,
                              fontSize: 13, fontWeight: FontWeight.w500))),
                    ]),
                  ],
                  const SizedBox(height: 4),
                  Text(deals == 1 ? '1 deal completed' : '$deals deals completed',
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                  const SizedBox(height: 3),
                  Row(children: [
                    Container(
                      width: 7, height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: online ? BrokaColors.neonGreen : BrokaColors.textMid,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(lastSeenLabel, style: TextStyle(
                        color: online ? BrokaColors.neonGreen : BrokaColors.textMid,
                        fontSize: 11)),
                  ]),
                ])),
                const Icon(Icons.chevron_right_rounded,
                    color: BrokaColors.textMid, size: 20),
              ]),
              if (location != null || memberLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(children: [
                    if (location != null) Expanded(child: Row(children: [
                      const Icon(Icons.location_on_outlined,
                          size: 12, color: BrokaColors.neonBlue),
                      const SizedBox(width: 4),
                      Flexible(child: Text(location, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: BrokaColors.textMid, fontSize: 11))),
                    ])) else const Spacer(),
                    if (memberLabel.isNotEmpty) Row(children: [
                      const Icon(Icons.calendar_month_rounded,
                          size: 12, color: BrokaColors.gold),
                      const SizedBox(width: 4),
                      Text(memberLabel, style: const TextStyle(
                          color: BrokaColors.textMid, fontSize: 11)),
                    ]),
                  ]),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        _buildStanding(),
      ]),
    );
  }

  /// The seller's standing, in the dashboard's colours: green where the
  /// dashboard shades green.
  Widget _buildStanding() {
    if (!_sellerLoaded) {
      return const ShimmerBox(height: 176, radius: BorderRadius.all(Radius.circular(14)));
    }
    return SellerStandingTiles(standing: _standing);
  }

  // ── Map Preview ───────────────────────────────────────────────────────────

  Widget _buildMapPreview(Listing l) {
    final myLat = ApiService.currentUserLat;
    final dist  = _distanceKm;
    final fare  = _travelCostEstimate;

    String? distanceText;
    if (dist != null) distanceText = '~${dist.toStringAsFixed(1)} km';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _secLabel('LOCATION'),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: BrokaColors.warning.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: BrokaColors.warning.withOpacity(0.3)),
            ),
            child: const Text('±1 km accuracy', style: TextStyle(
                color: BrokaColors.warning, fontSize: 9,
                fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, '/listing-map', arguments: l),
          child: _edgedCard(
            padding: EdgeInsets.zero,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: SizedBox(
                height: 168,
                child: Stack(children: [
                  // Map grid background
                  Positioned.fill(child: Container(color: const Color(0xFF0A0820))),
                  Positioned.fill(child: CustomPaint(painter: _MapGridPainter())),
                  // Seller pin
                  Positioned(
                    left: MediaQuery.of(context).size.width * 0.5 - 32 - 16,
                    top: 50,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 32, height: 32,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: BrokaColors.gold,
                          boxShadow: [BrokaColors.glowGold],
                        ),
                        child: const Icon(Icons.store_rounded,
                            color: Colors.white, size: 16),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: BrokaColors.gold,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('Seller', style: TextStyle(
                            color: Colors.white, fontSize: 8,
                            fontWeight: FontWeight.w700)),
                      ),
                    ]),
                  ),
                  // Buyer pin
                  if (myLat != null)
                    Positioned(
                      left: 36,
                      bottom: 34,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 26, height: 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: BrokaColors.neonBlue,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: const Icon(Icons.person_rounded,
                              color: Colors.white, size: 14),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: BrokaColors.neonBlue,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('You', style: TextStyle(
                              color: Colors.white, fontSize: 8,
                              fontWeight: FontWeight.w700)),
                        ),
                      ]),
                    ),
                  // Dashed line
                  if (myLat != null)
                    Positioned.fill(child: CustomPaint(
                        painter: _DashedLinePainter())),
                  // Bottom info row
                  Positioned(left: 0, right: 0, bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: BrokaColors.bgMid.withOpacity(0.95),
                        border: const Border(top: BorderSide(
                            color: BrokaColors.border)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.location_on_rounded,
                            color: BrokaColors.gold, size: 14),
                        const SizedBox(width: 6),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l.locationName != null
                              ? 'Seller in ${l.locationName}'
                              : 'Seller location available',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: BrokaColors.textHigh,
                                  fontSize: 12, fontWeight: FontWeight.w600)),
                          // The matatu estimate lived in the old analysis
                          // panel, behind a tap; it belongs with the place.
                          Text(fare == null
                              ? 'Approximate location · ±1 km radius'
                              : '±1 km · ~KES ${fare.toStringAsFixed(0)} by matatu, one way',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: BrokaColors.textMid,
                                  fontSize: 9.5)),
                        ])),
                        if (distanceText != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: BrokaColors.neonBlue.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.35)),
                            ),
                            child: Text(distanceText, style: const TextStyle(
                                color: BrokaColors.neonBlue, fontSize: 11,
                                fontWeight: FontWeight.w700)),
                          ),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right_rounded,
                            color: BrokaColors.textMid, size: 16),
                      ]),
                    )),
                  // Tap to explore badge
                  Positioned(right: 10, top: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: BrokaColors.neonBlue,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [BrokaColors.glowBlue],
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.map_outlined, color: Colors.white, size: 10),
                        SizedBox(width: 4),
                        Text('View Route', style: TextStyle(
                            color: Colors.white, fontSize: 9,
                            fontWeight: FontWeight.w800)),
                      ]),
                    )),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // ── Description ───────────────────────────────────────────────────────────

  Widget _buildDescSection(Listing l) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _secLabel('ABOUT THIS LISTING'),
      const SizedBox(height: 10),
      _edgedCard(
        // The seller's own words. This used to be a fixed placeholder - the
        // description came back from the API and was never shown.
        child: Text(
          (l.description ?? '').trim().isNotEmpty
              ? l.description!.trim()
              : 'The seller hasn\'t written a description. Ask Zeno below what to check, '
                'or ask the seller when you start the conversation.',
          style: TextStyle(
              color: (l.description ?? '').trim().isNotEmpty ? BrokaColors.textHigh : BrokaColors.textMid,
              fontSize: 13, height: 1.6),
        ),
      ),
    ]),
  );

  // ── Zeno Insight ──────────────────────────────────────────────────────────

  /// Opens Zeno about this listing - the whole card, or one of its
  /// questions, already asked.
  Widget _buildZenoInsight(Listing l) {
    final questions = _isMine
        ? const ['How can I sell this faster?', 'Is my price right?']
        : const ['Is this a fair price?', 'Is this seller reliable?', 'Find me something similar'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _secLabel('ZENO INSIGHT'),
        const SizedBox(height: 10),
        Semantics(
          button: true,
          label: 'Ask Zeno about this listing',
          child: GestureDetector(
            key: const Key('ask-zeno'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _openZeno(),
            child: Container(
              padding: const EdgeInsets.all(1.4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: const LinearGradient(
                  colors: BrokaColors.brandGradient,
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.28), blurRadius: 18)],
              ),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Color.alphaBlend(BrokaColors.neonPurple.withOpacity(0.16), BrokaColors.bgCard),
                    BrokaColors.cardGradColors.last,
                  ], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(16.6),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const ZenoAvatar(size: 40, glow: true),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_isMine ? 'Ask Zeno about your listing' : 'Ask Zeno about this listing',
                          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15.5,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(
                        _isMine
                            ? 'How it compares, what buyers will ask, and how to sell it faster.'
                            : "The price, the seller, delivery, what to check - and if it isn't "
                              'right for you, Zeno finds you one that is.',
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4),
                      ),
                    ])),
                    const SizedBox(width: 6),
                    const Icon(Icons.chevron_right_rounded, color: BrokaColors.textHigh, size: 22),
                  ]),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final q in questions)
                      Material(
                        color: BrokaColors.bgCard.withOpacity(0.9),
                        shape: StadiumBorder(side: BorderSide(color: BrokaColors.neonPurple.withOpacity(0.45))),
                        child: InkWell(
                          customBorder: const StadiumBorder(),
                          onTap: () => _openZeno(q),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            child: Text(q, style: const TextStyle(
                                color: BrokaColors.textHigh, fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // ── CTA ───────────────────────────────────────────────────────────────────

  /// In place of the buy button when there is nothing left to buy.
  Widget _buildUnavailableBar() => SafeArea(
    top: false,
    child: Container(
      key: const Key('product-unavailable'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: const BoxDecoration(
        color: BrokaColors.bgMid,
        border: Border(top: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(children: [
        Icon(_removed ? Icons.remove_shopping_cart_outlined : Icons.inventory_2_outlined,
            color: BrokaColors.warning, size: 22),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, children: [
          Text(_removed ? 'Removed by the seller' : 'Sold out',
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(
            _removed
                ? 'This listing is no longer on BROKA.'
                : "Every unit is sold or in a deal. It comes back if one falls through.",
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.35)),
        ])),
      ]),
    ),
  );

  Widget _buildCTA(Listing l) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid.withOpacity(0.97),
        border: const Border(top: BorderSide(color: BrokaColors.border)),
      ),
      // A store product is bought like one in a shop: Add to cart beside
      // the main action, the price above both. Everything else keeps the
      // one-row bar.
      child: _sellsFromStore(l)
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              _ctaPrice(l),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _addToCartButton(l)),
                const SizedBox(width: 10),
                Expanded(child: _ctaButton(l)),
              ]),
            ])
          : Row(children: [
              Expanded(child: _ctaPrice(l)),
              const SizedBox(width: 12),
              _ctaButton(l),
            ]),
    ),
  );

  /// Direct sales from a store go in its cart; auctions have their own way.
  bool _sellsFromStore(Listing l) => l.storeId != null && !_isAuction;

  Widget _ctaPrice(Listing l) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min, children: [
    FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(l.formattedPrice, style: const TextStyle(
          color: BrokaColors.textHigh, fontSize: 20,
          fontWeight: FontWeight.w800)),
    ),
    Text(
      _isAuction
          ? 'Escrow protected · 3% fee'
          : '${l.priceNegotiable ? 'Negotiable' : 'Fixed price'} · Escrow protected',
      maxLines: 1, overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
  ]);

  // The brand gradient, as on Home's primary actions. The label says what
  // happens: a fixed price is not negotiated, it is agreed with the seller -
  // through the same room, which knows it is fixed.
  Widget _ctaButton(Listing l) => Semantics(
    button: true,
    child: GestureDetector(
      key: const Key('product-cta'),
      onTap: () async {
        final authed = await requireAuth(context, reason: 'to start negotiating');
        if (!authed || !mounted) return;
        Navigator.pushNamed(context, '/negotiate',
            arguments: {'listing': l, 'role': 'buyer'});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
        alignment: _sellsFromStore(l) ? Alignment.center : null,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.neonBlue]),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(
              color: BrokaColors.gold.withOpacity(0.4), blurRadius: 14)],
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
              _isAuction || l.priceNegotiable ? 'Start Negotiation' : 'Contact Seller',
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w800, fontSize: 15)),
        ),
      ),
    ),
  );

  /// Add to cart, or - once it's in - how many and the way to the cart.
  Widget _addToCartButton(Listing l) {
    final cart = StoreCart.of(l.storeId!);
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) {
        final inCart = cart.quantityOf(l.id);
        void openCart() => openStoreCart(context,
            storeId: l.storeId!, storeName: l.storeName ?? 'Store',
            animateBackground: widget.animateBackground);
        return OutlinedButton.icon(
          key: const Key('product-add-to-cart'),
          onPressed: () {
            if (inCart > 0) return openCart();
            cart.add(CartItem.fromFields(
              id: l.id,
              name: l.name,
              price: l.price,
              category: l.category,
              priceUnit: l.priceUnit,
              quantity: l.quantity,
              unitsLeft: l.unitsLeft,
              cover: l.cover,
              photos: l.photos,
            ));
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(
                content: const Text('Added to your cart'),
                action: SnackBarAction(label: 'View cart', onPressed: openCart),
              ));
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: BrokaColors.textHigh,
            minimumSize: const Size.fromHeight(50),
            side: const BorderSide(color: BrokaColors.gold, width: 1.4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: Icon(inCart > 0 ? Icons.shopping_cart_checkout_rounded
              : Icons.add_shopping_cart_rounded, size: 19),
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(inCart > 0 ? 'In cart ($inCart)' : 'Add to cart',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
          ),
        );
      },
    );
  }

  // ── Haversine ─────────────────────────────────────────────────────────────

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * math.pi / 180) *
        math.cos(lat2 * math.pi / 180) *
        math.pow(math.sin(dLng / 2), 2);
    return r * 2 * math.asin(math.sqrt(a.toDouble()));
  }
}

// ─── Map Painters ────────────────────────────────────────────────────────────
class _MapGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1E2D47)
      ..strokeWidth = 0.8;
    const step = 28.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    final roadPaint = Paint()
      ..color = const Color(0xFF2A1F5A)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(size.width * 0.1, size.height * 0.55),
        Offset(size.width * 0.9, size.height * 0.35), roadPaint);
    canvas.drawLine(Offset(size.width * 0.5, 0),
        Offset(size.width * 0.5, size.height), roadPaint);
  }
  @override
  bool shouldRepaint(_MapGridPainter old) => false;
}

class _DashedLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x9038BDF8)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final start = Offset(size.width * 0.22, size.height * 0.72);
    final end   = Offset(size.width * 0.5,  size.height * 0.35);
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    const dashLen = 7.0, dashGap = 5.0;
    double drawn = 0;
    while (drawn < len) {
      final t0 = drawn / len;
      final t1 = ((drawn + dashLen) / len).clamp(0.0, 1.0);
      canvas.drawLine(
        Offset(start.dx + dx * t0, start.dy + dy * t0),
        Offset(start.dx + dx * t1, start.dy + dy * t1),
        paint);
      drawn += dashLen + dashGap;
    }
  }
  @override
  bool shouldRepaint(_DashedLinePainter old) => false;
}
