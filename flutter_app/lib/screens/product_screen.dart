// BROKA - Product Detail Screen
// Large photos, listing date/time, maps with ±1km disclaimer, distance,
// expanded seller section, Zeno Analysis (price compare, credibility, travel cost, fraud detection).
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../main.dart';
import '../models/listing.dart';
import '../services/api_service.dart';
import '../services/broka_tts.dart';
import '../services/last_screen_tracker.dart';
import '../utils/auth_gate.dart';

class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key});
  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  Listing? _listing;
  int _photoIndex = 0;
  Map<String, dynamic>? _sellerInfo;
  bool    _zenoExpanded  = false;
  String? _zenoComment;        // AI-generated commentary
  bool    _zenoCommentLoading = false;

  @override
  void initState() {
    super.initState();
    BrokaTts.instance.onFallback = () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Using offline voice — Zeno\'s usual voice is unavailable right now.'),
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listing == null) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Listing) {
        _listing = args;
        _loadSeller();
        _loadPriceComparison();
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
      _loadPriceComparison();
      LastScreenTracker.save('/product', {'listingId': listingId});
    } catch (_) {
      // Listing may have been deleted/sold since the app was last open.
      if (mounted) Navigator.pushReplacementNamed(context, '/home');
    }
  }

  Future<void> _loadSeller() async {
    final sid = _listing?.sellerId;
    if (sid == null) return;
    try {
      final info = await ApiService.getUserProfile(sid);
      if (mounted) setState(() => _sellerInfo = info);
    } catch (_) {}
    // Zeno's verdict is now loaded on-demand (see _toggleZenoAnalysis) to
    // avoid burning AI API calls on every listing view.
  }

  List<String> get _photos {
    final raw = _listing?.verifiedPhotos;
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  // Raw base64 of the first photo, for Zeno's image analysis. Only
  // populated when the photo is already a data URI (most uploads are,
  // per the existing _ImageBubble pattern elsewhere in the app) - remote
  // URLs are skipped here rather than fetched, to keep this single,
  // synchronous, and free of an extra network round-trip.
  String? get _zenoImageBase64 {
    if (_photos.isEmpty) return null;
    final first = _photos.first;
    if (!first.startsWith('data:')) return null;
    final commaIdx = first.indexOf(',');
    if (commaIdx < 0) return null;
    return first.substring(commaIdx + 1);
  }

  bool get _isMine => _listing?.sellerId == ApiService.currentUserId;

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

  // ── Zeno Analysis helpers ─────────────────────────────────────────────────

  // Real on-platform price comparison (replaces the old fixed-percentage
  // heuristic, which mathematically always produced ~14% for Electronics
  // regardless of actual price - it was comparing price against itself).
  Map<String, dynamic>? _priceComparison;
  bool _priceComparisonLoaded = false;

  Future<void> _loadPriceComparison() async {
    if (_listing == null || _priceComparisonLoaded) return;
    try {
      final comparison = await ApiService.getPriceComparison(_listing!.id);
      if (mounted) setState(() {
        _priceComparison = comparison;
        _priceComparisonLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _priceComparisonLoaded = true);
    }
  }

  bool get _hasPlatformPriceData =>
      (_priceComparison?['has_enough_data'] as bool?) ?? false;

  double? get _marketAvgPrice =>
      _hasPlatformPriceData ? (_priceComparison?['platform_avg_price'] as num?)?.toDouble() : null;

  // Null when there isn't enough on-platform data yet - callers should fall
  // back to general market knowledge (e.g. let Zeno reason about it from
  // training knowledge) rather than show a fabricated number.
  double? get _priceDiffPct =>
      _hasPlatformPriceData ? (_priceComparison?['diff_pct'] as num?)?.toDouble() : null;

  int get _priceComparisonSampleSize => (_priceComparison?['sample_size'] as int?) ?? 0;

  bool get _isPriceSuspicious {
    final diff = _priceDiffPct;
    if (diff == null) return false; // not enough data to judge
    return diff < -35 || diff > 60;
  }

  double get _credibilityScore {
    double score = 5.0;
    final r = (_listing?.sellerRating as num?)?.toDouble() ?? 5.0;
    score += (r > 5 ? r / 2 : r) * 0.5;
    final deals = _listing?.sellerCompletedDeals ?? 0;
    if (deals > 10) score += 1.5;
    else if (deals > 3) score += 0.8;
    final verified = _sellerInfo?['is_verified'] as bool? ?? false;
    if (verified) score += 1.5;
    return score.clamp(0.0, 10.0);
  }

  double? get _travelCostEstimate {
    final d = _distanceKm;
    if (d == null) return null;
    // Matatu fare approx KES 5-8/km + base 30
    return 30 + d * 6.5;
  }

  @override
  Widget build(BuildContext context) {
    if (_listing == null) {
      return const Scaffold(body: Center(
          child: CircularProgressIndicator(color: BrokaColors.gold)));
    }
    final l = _listing!;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: CustomScrollView(slivers: [
        _buildAppBar(l),
        SliverToBoxAdapter(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          _buildMediaSection(l),
          _buildInfoSection(l),
          _buildSellerSection(l),
          if (_hasMapData) _buildMapPreview(l),
          _buildDescSection(l),
          _buildZenoAnalysis(l),
          const SizedBox(height: 100),
        ])),
      ]),
      bottomNavigationBar: _isMine ? null : _buildCTA(l),
    );
  }

  // ── App Bar ───────────────────────────────────────────────────────────────

  Widget _buildAppBar(Listing l) => SliverAppBar(
    backgroundColor: BrokaColors.bgMid,
    expandedHeight: 0,
    pinned: true,
    leading: GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: BrokaColors.bgCard,
          border: Border.all(color: BrokaColors.border),
        ),
        child: const Icon(Icons.arrow_back_ios_new_rounded,
            color: BrokaColors.textMid, size: 16),
      ),
    ),
    title: Text(l.name, style: const TextStyle(
        color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w700),
        maxLines: 1, overflow: TextOverflow.ellipsis),
    actions: [
      Container(
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: l.listingType == 'auction'
              ? BrokaColors.danger.withOpacity(0.15)
              : BrokaColors.gold.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: l.listingType == 'auction'
              ? BrokaColors.danger.withOpacity(0.5)
              : BrokaColors.gold.withOpacity(0.5)),
        ),
        child: Text(l.listingType == 'auction' ? '⬤ LIVE AUCTION' : 'DIRECT SALE',
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800,
                color: l.listingType == 'auction'
                    ? BrokaColors.danger : BrokaColors.gold)),
      ),
    ],
  );

  // ── Media ─────────────────────────────────────────────────────────────────

  Widget _buildMediaSection(Listing l) {
    final photos = _photos;
    return Column(children: [
      if (photos.isNotEmpty)
        _buildPhotoGallery(photos)
      else
        Container(
          height: 280,
          color: BrokaColors.bgCard,
          child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(l.emoji, style: const TextStyle(fontSize: 64)),
            const SizedBox(height: 8),
            const Text('No media available',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          ])),
        ),
    ]);
  }

  Widget _buildPhotoGallery(List<String> photos) {
    return Stack(children: [
      SizedBox(
        height: 340,
        // Receiving end of the card's Hero. Only the FIRST photo carries
        // the tag: that is the one the card was showing, and two widgets
        // claiming the same tag in one subtree is an assertion failure, not
        // a nicer animation.
        child: PageView.builder(
          onPageChanged: (i) => setState(() => _photoIndex = i),
          itemCount: photos.length,
          itemBuilder: (_, i) {
            final p = photos[i];
            try {
              final bytes = base64Decode(p);
              final img = Image.memory(bytes, fit: BoxFit.cover,
                  width: double.infinity,
                  errorBuilder: (_, __, ___) => _photoFallback());
              final id = _listing?.id;
              return (i == 0 && id != null && id.isNotEmpty)
                  ? Hero(tag: 'listing-photo-$id', child: img)
                  : img;
            } catch (_) {
              return Image.network(p, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _photoFallback());
            }
          },
        ),
      ),
      // Page indicator dots
      if (photos.length > 1)
        Positioned(bottom: 48, left: 0, right: 0,
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
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
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
            child: Text(l.formattedPrice, style: const TextStyle(
                color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
          ),
        ])),
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
      Text(label, style: TextStyle(color: color,
          fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  );

  // ── Seller Section ────────────────────────────────────────────────────────

  Widget _buildSellerSection(Listing l) {
    final sellerName = l.sellerName ?? _sellerInfo?['name'] as String? ?? 'Seller';
    final sellerRating = (l.sellerRating as num?)?.toDouble()
        ?? (_sellerInfo?['rating'] as num?)?.toDouble() ?? 5.0;
    // Convert to 10-scale
    final rating10 = sellerRating <= 5.0 ? sellerRating * 2 : sellerRating;
    final deals = l.sellerCompletedDeals
        ?? (_sellerInfo?['completed_deals'] as num?)?.toInt() ?? 0;
    final verified = _sellerInfo?['is_verified'] as bool? ?? false;
    final photo = _sellerInfo?['profile_photo'] as String?;
    final location = _sellerInfo?['location_name'] as String? ?? l.locationName;
    final lastSeen = _sellerInfo?['last_seen'] as String?;
    final memberSince = _sellerInfo?['created_at'] as String?;

    String lastSeenLabel = 'Unknown';
    if (lastSeen != null) {
      try {
        final dt = DateTime.parse(lastSeen);
        final diff = DateTime.now().difference(dt);
        if (diff.inMinutes < 2) lastSeenLabel = 'Online now';
        else if (diff.inMinutes < 60) lastSeenLabel = '${diff.inMinutes}m ago';
        else if (diff.inHours < 24) lastSeenLabel = '${diff.inHours}h ago';
        else lastSeenLabel = '${diff.inDays}d ago';
      } catch (_) {}
    }

    String memberLabel = '';
    if (memberSince != null) {
      try {
        final dt = DateTime.parse(memberSince);
        final months = ['Jan','Feb','Mar','Apr','May','Jun',
                        'Jul','Aug','Sep','Oct','Nov','Dec'];
        memberLabel = 'Since ${months[dt.month - 1]} ${dt.year}';
      } catch (_) {}
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('SELLER DETAILS', style: TextStyle(
            color: BrokaColors.textLow, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 1.2)),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, '/user-profile',
              arguments: l.sellerId),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
                  begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Column(children: [
              Row(children: [
                // Avatar
                Container(
                  width: 56, height: 56,
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
                        ? Image.memory(base64Decode(photo), fit: BoxFit.cover)
                        : Center(child: Text(
                            sellerName[0].toUpperCase(),
                            style: const TextStyle(color: Colors.white,
                                fontSize: 22, fontWeight: FontWeight.w800))),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(sellerName, style: const TextStyle(
                        color: BrokaColors.textHigh, fontSize: 16,
                        fontWeight: FontWeight.w700))),
                    if (verified)
                      const Icon(Icons.verified_rounded,
                          color: BrokaColors.gold, size: 18),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.star_rounded, size: 13, color: BrokaColors.gold),
                    const SizedBox(width: 4),
                    Text('${rating10.toStringAsFixed(1)}/10  ·  $deals deals',
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                  ]),
                  const SizedBox(height: 3),
                  Row(children: [
                    Container(
                      width: 7, height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: lastSeenLabel == 'Online now'
                            ? BrokaColors.neonGreen : BrokaColors.textLow,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(lastSeenLabel, style: TextStyle(
                        color: lastSeenLabel == 'Online now'
                            ? BrokaColors.neonGreen : BrokaColors.textLow,
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
                      Text(location, style: const TextStyle(
                          color: BrokaColors.textMid, fontSize: 11)),
                    ])),
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
      ]),
    );
  }

  // ── Map Preview ───────────────────────────────────────────────────────────

  Widget _buildMapPreview(Listing l) {
    final myLat = ApiService.currentUserLat;
    final myLng = ApiService.currentUserLng;
    final dist  = _distanceKm;

    String? distanceText;
    if (dist != null) distanceText = '~${dist.toStringAsFixed(1)} km';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('LOCATION MAP', style: TextStyle(
              color: BrokaColors.textLow, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 1.2)),
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
          child: Container(
            height: 160,
            decoration: BoxDecoration(
              color: const Color(0xFF0A0820),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.border),
            ),
            clipBehavior: Clip.hardEdge,
            child: Stack(children: [
              // Map grid background
              Positioned.fill(child: CustomPaint(painter: _MapGridPainter())),
              // Seller pin
              Positioned(
                left: MediaQuery.of(context).size.width * 0.5 - 32 - 16,
                top: 55,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: BrokaColors.gold,
                      boxShadow: const [BrokaColors.glowGold],
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
                  bottom: 28,
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
                          style: const TextStyle(color: BrokaColors.textHigh,
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      const Text('Approximate location · ±1 km radius',
                          style: TextStyle(color: BrokaColors.textLow,
                              fontSize: 9)),
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
      ]),
    );
  }

  // ── Description ───────────────────────────────────────────────────────────

  Widget _buildDescSection(Listing l) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('ABOUT THIS LISTING', style: TextStyle(
          color: BrokaColors.textLow, fontSize: 10,
          fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      const SizedBox(height: 10),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.border),
        ),
        child: const Text(
          'Tap "Start Negotiation" below to contact the seller and get a detailed description. '
          'The AI broker will mediate a fair deal for both parties.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.6),
        ),
      ),
    ]),
  );


  // ── Zeno AI Commentary ─────────────────────────────────────────────────────

  void _toggleZenoAnalysis() {
    setState(() => _zenoExpanded = !_zenoExpanded);
    // Only fire the AI call the first time the panel is opened, so collapsing
    // and re-expanding doesn't re-trigger it (saves on API costs).
    if (_zenoExpanded && _zenoComment == null && !_zenoCommentLoading) {
      _loadZenoComment();
    }
  }

  Future<void> _loadZenoComment() async {
    final listing = _listing;
    if (listing == null) return;
    if (_zenoCommentLoading) return;
    setState(() => _zenoCommentLoading = true);

    try {
      await _loadPriceComparison();

      final sellerName  = listing.sellerName ?? _sellerInfo?['name'] as String? ?? 'Seller';
      final userName     = ApiService.currentUserNickname ?? ApiService.currentUserName ?? 'Buyer';
      final lang         = ApiService.currentUserLanguage;
      final price        = listing.price;
      final credScore    = _credibilityScore;
      final distKm       = _distanceKm;
      final category     = listing.category ?? 'General';

      // ── Price comparison block: real on-platform data when we have
      // enough, otherwise tell Zeno honestly so it falls back to its own
      // general market knowledge instead of presenting a fake number.
      String priceBlock;
      if (_hasPlatformPriceData) {
        final diff = _priceDiffPct!;
        final avg  = _marketAvgPrice!;
        priceBlock =
            'On-platform comparison: ${_priceComparisonSampleSize} similar active '
            'listings found, average price KES ${avg.toStringAsFixed(0)}. '
            'This listing is ${diff > 0 ? "${diff.toStringAsFixed(0)}% above" : "${diff.abs().toStringAsFixed(0)}% below"} that average.';
      } else {
        priceBlock =
            'Not enough similar listings on BROKA yet for a reliable on-platform '
            'average (only ${_priceComparisonSampleSize} found). Use your own general '
            'knowledge of typical market prices for this kind of item in Kenya '
            'instead, and be clear that this is a general estimate, not platform data.';
      }

      // ── Whether a features/pros-and-cons discussion is appropriate.
      // Zeno uses judgement here rather than a hard rule, but we steer it:
      // electronics/vehicles/branded durable goods - yes; produce, livestock,
      // generic commodities - no, since "pros and cons" doesn't make sense
      // for a sack of maize.
      final featuresLikelyRelevant = category == 'Electronics' || category == 'Vehicles';

      final prompt = '''You are Zeno, BROKA's AI assistant for East African markets.
Respond ONLY in $lang language.
Give a thorough but conversational verdict in 6-9 sentences.
Start with "$userName, judging from..."
Be balanced and fair to both the buyer and the seller — most listings and
sellers on BROKA are legitimate. Only raise trust concerns or red flags when
the data genuinely supports it. If the price is fair and the seller's
credibility is solid, say so plainly and don't manufacture caution.

Listing: ${listing.name} (category: $category) at KES ${price.toStringAsFixed(0)}
$priceBlock
Seller credibility: ${credScore.toStringAsFixed(1)}/10
Distance: ${distKm != null ? "${distKm.toStringAsFixed(1)} km away" : "unknown"}
Seller: $sellerName (${listing.sellerCompletedDeals ?? 0} deals completed)
${_zenoImageBase64 != null ? "\nA photo of the item is attached - look at it and factor in what you can actually observe (condition, apparent authenticity, anything notable)." : ""}

Cover these topics, in this order, each only as long as it deserves:
1. PRICE: whether it's fair, using the comparison data above (or your general
   knowledge if there wasn't enough on-platform data — say which one you're using).
2. SELLER CREDIBILITY: a brief honest read of the credibility score and deal history.
3. LOCATION/DISTANCE: only flag this if distance is a genuine practical concern.
4. FEATURES (pros/cons): ${featuresLikelyRelevant ? "this is a $category listing, so go ahead and discuss specific features, pros, and cons relevant to this exact item (e.g. for a phone: storage, condition, model generation; for a vehicle: mileage, year, common issues)." : "use your judgement — for a $category listing this is often NOT appropriate (e.g. there's nothing meaningful to call 'pros and cons' for raw produce or livestock by weight). Skip this topic entirely unless the specific listing genuinely has discussable features."}

Finish with a clear recommendation — buy, negotiate, or walk away — based on the actual evidence.''';

      final comment = await ApiService.zenoChat(
        message: prompt,
        history: const [],
        language: lang,
        imageBase64: _zenoImageBase64,
      );

      if (mounted) setState(() {
        _zenoComment        = comment;
        _zenoCommentLoading = false;
      });
      // Speak the Zeno verdict aloud so the user hears the analysis.
      if (comment.isNotEmpty) {
        BrokaTts.instance.speak(comment, language: lang);
      }
    } catch (_) {
      if (mounted) setState(() => _zenoCommentLoading = false);
    }
  }

  // ── Zeno Analysis Section ─────────────────────────────────────────────────

  Widget _buildZenoAnalysis(Listing l) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.gold.withOpacity(0.08),
          BrokaColors.bgCard,
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.35)),
        boxShadow: const [BrokaColors.glowGold],
      ),
      child: Column(children: [
        // Header
        GestureDetector(
          onTap: _toggleZenoAnalysis,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(
                width: 34, height: 34,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                      colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                ),
                child: const Icon(Icons.auto_awesome_rounded,
                    color: Colors.white, size: 16),
              ),
              const SizedBox(width: 12),
              const Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Zeno Analysis', style: TextStyle(
                    color: BrokaColors.textHigh, fontSize: 15,
                    fontWeight: FontWeight.w800)),
                Text('AI-powered deal intelligence',
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 11)),
              ])),
              Icon(_zenoExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
                  color: BrokaColors.textMid, size: 22),
            ]),
          ),
        ),

        if (_zenoExpanded) ...[
          Container(height: 1, color: BrokaColors.border),

          // Price Comparison
          _analysisCard(
            icon: Icons.compare_arrows_rounded,
            color: BrokaColors.neonBlue,
            title: 'Price Comparison',
            content: _buildPriceAnalysis(l),
          ),

          Container(height: 1, color: BrokaColors.border),

          // Credibility Analysis
          _analysisCard(
            icon: Icons.shield_rounded,
            color: BrokaColors.neonGreen,
            title: 'Seller Credibility',
            content: _buildCredibilityAnalysis(),
          ),

          Container(height: 1, color: BrokaColors.border),

          // Travel Cost
          _analysisCard(
            icon: Icons.directions_rounded,
            color: BrokaColors.gold,
            title: 'Estimated Travel Cost',
            content: _buildTravelAnalysis(),
          ),

          // Zeno AI Commentary
          Container(height: 1, color: BrokaColors.border),
          _analysisCard(
            icon: Icons.auto_awesome_rounded,
            color: BrokaColors.gold,
            title: 'Zeno\'s Verdict',
            content: _buildZenoCommentary(),
          ),

          if (_isPriceSuspicious) ...[
            Container(height: 1, color: BrokaColors.border),
            _analysisCard(
              icon: Icons.warning_amber_rounded,
              color: BrokaColors.danger,
              title: 'Suspicious Pricing Alert',
              content: _buildSuspiciousAlert(l),
            ),
          ],

          const SizedBox(height: 4),
        ],
      ]),
    ),
  );

  Widget _analysisCard({
    required IconData icon,
    required Color color,
    required String title,
    required Widget content,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: color, size: 15),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(color: color,
            fontSize: 12, fontWeight: FontWeight.w700,
            letterSpacing: 0.4)),
      ]),
      const SizedBox(height: 10),
      content,
    ]),
  );

  Widget _buildPriceAnalysis(Listing l) {
    final diff = _priceDiffPct;
    if (diff == null) {
      // Not enough comparable listings yet - be honest about it instead of
      // showing a fabricated percentage.
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Listing Price', style: TextStyle(
              color: BrokaColors.textLow, fontSize: 10)),
        ]),
        Text(l.formattedPrice, style: const TextStyle(
            color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: BrokaColors.textMid.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: BrokaColors.textMid.withOpacity(0.25)),
          ),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded, color: BrokaColors.textMid, size: 14),
            const SizedBox(width: 6),
            Expanded(child: Text(
              _priceComparisonSampleSize > 0
                  ? 'Only ${_priceComparisonSampleSize} similar listings on BROKA so far — not enough yet for a reliable platform average.'
                  : 'No similar listings on BROKA yet to compare against. Ask Zeno for a general market estimate.',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12))),
          ]),
        ),
      ]);
    }

    final isAbove = diff > 0;
    final diffAbs = diff.abs();
    final color = diffAbs < 10 ? BrokaColors.neonGreen
        : isAbove ? BrokaColors.warning : BrokaColors.neonBlue;
    final label = diffAbs < 10 ? 'Fair price (vs $_priceComparisonSampleSize similar listings)'
        : isAbove ? '${diffAbs.toStringAsFixed(0)}% above ${_priceComparisonSampleSize} similar listings'
        : '${diffAbs.toStringAsFixed(0)}% below ${_priceComparisonSampleSize} similar listings';
    final avgPrice = _marketAvgPrice!;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Listing Price', style: TextStyle(
              color: BrokaColors.textLow, fontSize: 10)),
          Text(l.formattedPrice, style: const TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
        ])),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('BROKA Avg (similar listings)', style: TextStyle(
              color: BrokaColors.textLow, fontSize: 10)),
          Text(_Listing_formatPrice(avgPrice), style: const TextStyle(
              color: BrokaColors.textMid, fontWeight: FontWeight.w700)),
        ])),
      ]),
      const SizedBox(height: 10),
      Stack(children: [
        Container(height: 8, decoration: BoxDecoration(
            color: BrokaColors.border, borderRadius: BorderRadius.circular(4))),
        FractionallySizedBox(
          widthFactor: ((l.price / (avgPrice * 2)).clamp(0.0, 1.0)),
          child: Container(height: 8, decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(4))),
        ),
      ]),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(children: [
          Icon(diffAbs < 10 ? Icons.check_circle_rounded
              : Icons.info_rounded, color: color, size: 14),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: TextStyle(
              color: color, fontSize: 12))),
        ]),
      ),
    ]);
  }

  String _Listing_formatPrice(double v) {
    if (v >= 1000000) return 'KES ${(v/1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return 'KES ${(v/1000).toStringAsFixed(0)}K';
    return 'KES ${v.toStringAsFixed(0)}';
  }

  Widget _buildCredibilityAnalysis() {
    final score = _credibilityScore;
    final color = score >= 7 ? BrokaColors.neonGreen
        : score >= 5 ? BrokaColors.gold : BrokaColors.danger;
    final label = score >= 7 ? 'High credibility seller'
        : score >= 5 ? 'Moderate credibility'
        : 'Low credibility - proceed with caution';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Stack(children: [
          Container(height: 8, decoration: BoxDecoration(
              color: BrokaColors.border, borderRadius: BorderRadius.circular(4))),
          FractionallySizedBox(
            widthFactor: score / 10,
            child: Container(height: 8, decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                BrokaColors.danger, BrokaColors.warning, BrokaColors.neonGreen]),
              borderRadius: BorderRadius.circular(4))),
          ),
        ])),
        const SizedBox(width: 12),
        Text('${score.toStringAsFixed(1)}/10', style: TextStyle(
            color: color, fontWeight: FontWeight.w700, fontSize: 13)),
      ]),
      const SizedBox(height: 8),
      Text(label, style: TextStyle(color: color, fontSize: 12)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 4, children: [
        if (_sellerInfo?['is_verified'] == true)
          _tagChip('✓ ID Verified', BrokaColors.neonGreen),
        if ((_listing?.sellerCompletedDeals ?? 0) > 5)
          _tagChip('${_listing?.sellerCompletedDeals} deals completed',
              BrokaColors.neonBlue),
        if (_photos.length >= 3)
          _tagChip('${_photos.length} photos', BrokaColors.gold),
      ]),
    ]);
  }

  Widget _tagChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 10,
        fontWeight: FontWeight.w600)),
  );

  Widget _buildTravelAnalysis() {
    final d = _distanceKm;
    final cost = _travelCostEstimate;
    if (d == null) {
      return const Text('Enable location to see travel cost estimate',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 12));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: _travelStat('Distance', '~${d.toStringAsFixed(1)} km',
            BrokaColors.neonBlue)),
        Expanded(child: _travelStat('Matatu Fare (est.)',
            'KES ${cost!.toStringAsFixed(0)} one-way', BrokaColors.gold)),
      ]),
      const SizedBox(height: 8),
      const Text('⚠️ Distance is approximate (±1 km). Confirm exact meeting point with seller.',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 10, height: 1.4)),
    ]);
  }

  Widget _travelStat(String label, String value, Color color) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
    const SizedBox(height: 3),
    Text(value, style: TextStyle(color: color, fontSize: 12,
        fontWeight: FontWeight.w700)),
  ]);

  Widget _buildZenoCommentary() {
    if (_zenoCommentLoading) {
      return const Row(children: [
        SizedBox(width: 16, height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: BrokaColors.gold)),
        SizedBox(width: 10),
        Text('Zeno is analysing this deal...',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      ]);
    }
    if (_zenoComment == null || _zenoComment!.isEmpty) {
      return const Text('Zeno analysis unavailable.',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 12));
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.gold.withOpacity(0.10),
          BrokaColors.neonBlue.withOpacity(0.05),
        ]),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.25)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
                colors: [BrokaColors.gold, BrokaColors.neonBlue]),
          ),
          child: const Icon(Icons.auto_awesome_rounded,
              color: Colors.white, size: 13),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(_zenoComment!,
            style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 12.5,
                height: 1.5, fontStyle: FontStyle.italic))),
      ]),
    );
  }

  Widget _buildSuspiciousAlert(Listing l) {
    // Only ever shown when _isPriceSuspicious is true, which already
    // guarantees _priceDiffPct is non-null.
    final diff = _priceDiffPct!;
    final tooLow = diff < -35;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrokaColors.danger.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: BrokaColors.danger.withOpacity(0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          tooLow
              ? '🚨 This price is ${diff.abs().toStringAsFixed(0)}% below market average. '
                'Extremely low prices may indicate a scam or stolen goods.'
              : '⚠️ This price is ${diff.toStringAsFixed(0)}% above market average. '
                'Verify why the seller is asking significantly above market value.',
          style: const TextStyle(color: BrokaColors.danger, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 8),
        const Text('Zeno recommends: Always use BROKA escrow and never pay before seeing the item.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11, height: 1.4)),
      ]),
    );
  }

  // ── CTA ───────────────────────────────────────────────────────────────────

  Widget _buildCTA(Listing l) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: BrokaColors.bgMid,
        border: Border(top: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(children: [
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, children: [
          Text(l.formattedPrice, style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 20,
              fontWeight: FontWeight.w800)),
          const Text('Escrow protected · 3% fee',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
        ])),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: () async {
            final authed = await requireAuth(context, reason: 'to start negotiating');
            if (!authed || !mounted) return;
            Navigator.pushNamed(context, '/negotiate',
                arguments: {'listing': l, 'role': 'buyer'});
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFFFF4D6D), Color(0xFFFF8C42)]),
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [BoxShadow(
                  color: Color(0x55FF4D6D), blurRadius: 14)],
            ),
            child: const Text('Start Negotiation',
                style: TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        ),
      ]),
    ),
  );

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
