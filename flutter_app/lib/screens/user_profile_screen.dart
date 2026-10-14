// BROKA - User Profile Screen
// A user's public profile, opened from a listing's seller block or a chat:
// who they are, the standing buyers are shown on their listings, their track
// record, buyers' reviews, and what they are selling.
//
// 2026-09-30, on Home's visual system - the constellation, Home's header
// language (back chevron, badge, glowing title, square controls) and cards
// with the product card's gradient edge - like the listing screen and the
// seller dashboard it links to. It had its own app bar, a boxed back button
// and plain cards.
//
// Every figure on it is now one the API returns. Most of what it showed
// wasn't:
//
//  * "Last active 3h ago" for someone active that minute. last_seen is naive
//    UTC and was parsed as local time (utils/backend_time.dart); the server's
//    own label (api/core/presence.py) is shown instead.
//  * "Reliability", "Trust Score" and "Response Rate" bars, and a radar drawn
//    from them. reliability_score and response_rate are fields the API has
//    never returned - the rate defaulted to 85% for everyone - and a trust
//    score is not public, so all three fell back to the account's rating.
//    That rating starts at 5.0, which the screen doubled to "10.0/10" for a
//    seller nobody had rated. The seller dashboard dropped the same numbers
//    for the same reasons (seller_dashboard_screen.dart, "SCALES").
//  * "Pending deals: 0" and "Avg deal time: N/A" for every seller: neither
//    field was in the response.
//  * "Kenya" when no location was set, and "0.0 km away" on your own profile.
//
// In their place, the four figures a buyer sees on the seller's listings
// (widgets/seller_standing_tiles.dart), the deal track record, and reviews -
// which never loaded: the routes they called were not mounted
// (features/reviews/). Only a buyer whose deal with this seller completed is
// offered "Write a review"; the backend refuses anyone else.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/utils/result.dart';
import '../features/reviews/data/repositories/reviews_repository.dart';
import '../features/reviews/domain/models/review.dart';
import '../features/safe_payment/payments_shown.dart';
import '../main.dart';
import '../models/listing.dart';
import '../models/seller_standing.dart';
import '../services/api_service.dart';
import '../utils/backend_time.dart';
import '../widgets/broka_image.dart';
import '../widgets/constellation_background.dart';
import '../widgets/motion_widgets.dart';
import '../widgets/seller_standing_tiles.dart';

enum _Load { loading, loaded, notFound, failed }

class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  String? _userId;
  bool _initialized = false;

  Map<String, dynamic>? _profile;
  _Load _state = _Load.loading;

  List<Listing> _listings = [];
  bool _loadingListings = true;

  ReviewSummary? _summary;
  List<SellerReview> _reviews = [];
  bool _loadingReviews = true;

  /// The viewer's completed purchases from this seller. Null until known;
  /// only a buyer with one not yet reviewed is offered "Write a review".
  List<ReviewableDeal>? _reviewable;

  static const _listingLimit = 40;
  static const _reviewPage = 10;
  static const _gradient = [BrokaColors.gold, BrokaColors.neonBlue];

  /// The listings section, for "See N listings" to scroll to.
  final _listingsKey = GlobalKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is String) {
      _userId = args;
    } else if (args is Map) {
      _userId = args['user_id'] as String?;
    }
    if (_userId == null) {
      _state = _Load.notFound;
    } else {
      _loadAll();
    }
  }

  bool get _isSelf => _userId != null && _userId == ApiService.currentUserId;

  Future<void> _loadAll() => Future.wait([
        _loadProfile(),
        _loadListings(),
        _loadReviews(),
        _loadEligibility(),
      ]);

  Future<void> _loadProfile() async {
    try {
      final p = await ApiService.getUserProfile(_userId!);
      if (!mounted) return;
      // getUserProfile hands back whatever body came, so a 404's
      // {"detail": "User not found"} used to render as a user called
      // "Broka User".
      setState(() {
        if (p['id'] == null) {
          _state = _Load.notFound;
        } else {
          _profile = p;
          _state = _Load.loaded;
        }
      });
    } catch (_) {
      if (mounted && _profile == null) setState(() => _state = _Load.failed);
    }
  }

  Future<void> _loadListings() async {
    try {
      final list = await ApiService.getListings(sellerId: _userId, limit: _listingLimit);
      if (mounted) setState(() { _listings = list; _loadingListings = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingListings = false);
    }
  }

  Future<void> _loadReviews() async {
    final summaryCall = reviewsRepository.getSummary(_userId!);
    final reviewsCall = reviewsRepository.getSellerReviews(_userId!, limit: _reviewPage);
    final summary = await summaryCall;
    final reviews = await reviewsCall;
    if (!mounted) return;
    setState(() {
      if (summary is Success<ReviewSummary>) _summary = summary.data;
      if (reviews is Success<List<SellerReview>>) _reviews = reviews.data;
      _loadingReviews = false;
    });
  }

  Future<void> _loadEligibility() async {
    if (_isSelf || ApiService.currentUserId == null) return;
    final result = await reviewsRepository.myReviewableDeals(sellerId: _userId);
    if (!mounted) return;
    if (result is Success<List<ReviewableDeal>>) {
      setState(() => _reviewable = result.data);
    }
  }

  // ── Figures ───────────────────────────────────────────────────────────────

  String get _displayName {
    final nick = (_profile?['nickname'] as String?)?.trim();
    if (nick != null && nick.isNotEmpty) return nick;
    final name = (_profile?['name'] as String?)?.trim();
    return name == null || name.isEmpty ? 'BROKA user' : name;
  }

  String? get _officialName {
    final name = (_profile?['name'] as String?)?.trim();
    return name == null || name.isEmpty || name == _displayName ? null : name;
  }

  String? get _businessName {
    for (final k in ['business_display_name', 'business_name']) {
      final v = (_profile?[k] as String?)?.trim();
      if (v != null && v.isNotEmpty && v != _displayName) return v;
    }
    return null;
  }

  String get _initials {
    final parts = _displayName.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return parts.isEmpty ? 'B' : parts[0][0].toUpperCase();
  }

  int get _completedDeals => (_profile?['completed_deals'] as num?)?.toInt() ?? 0;
  bool get _isVerified => _profile?['is_verified'] == true;

  /// Anyone who can sell, or has: a buyer-only account has no standing to show.
  bool get _isSeller =>
      _profile?['account_type'] == 'buyer_seller' ||
      _completedDeals > 0 ||
      _profile?['seller_standing'] != null ||
      _listings.isNotEmpty;

  /// Shown only with the user's leave (location_visible) - the backend sends
  /// null otherwise. There is no "Kenya" default: no place is no place.
  String? get _location {
    final v = (_profile?['business_location'] as String?)?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  /// From the approximate point, to someone else only: your own distance
  /// from yourself was "0.0 km away".
  double? get _distanceKm =>
      _isSelf ? null : (_profile?['distance_km'] as num?)?.toDouble();

  String? get _memberSince {
    final dt = parseBackendUtc(_profile?['created_at'] as String?)?.toLocal();
    if (dt == null) return null;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[dt.month - 1]} ${dt.year}';
  }

  bool get _online => _profile?['is_online'] == true;

  /// The server's reading of last_seen, the one the chat header and inbox
  /// show ("Active 12m ago"). Null when it hasn't said.
  String? get _presence =>
      _online ? 'Online now' : _profile?['last_seen_label'] as String?;

  List<ReviewableDeal> get _toReview =>
      (_reviewable ?? const []).where((d) => !d.alreadyReviewed).toList();

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // The constellation Home and every screen reached from it sit on, with
      // the dashboard's gold washing down from the top.
      body: ConstellationBackground(
        animate: widget.animateBackground,
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
            bottom: false,
            child: Column(children: [
              _buildHeader(),
              Expanded(child: _buildBody()),
            ]),
          ),
        ),
      ),
    );
  }

  /// The header every screen reached from Home wears.
  Widget _buildHeader() {
    final narrow = MediaQuery.sizeOf(context).width < 360;
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
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [
              _gradient.first.withOpacity(0.28),
              _gradient.last.withOpacity(0.14),
            ]),
            border: Border.all(color: _gradient.first.withOpacity(0.5)),
          ),
          child: const Icon(Icons.person_rounded, size: 18, color: BrokaColors.textHigh),
        ),
        const SizedBox(width: 10),
        Expanded(
          // "Profile" on your own too: "MY PROFILE" did not fit beside the
          // Dashboard button on a 390dp phone.
          child: ZoneGlowText(
            'Profile',
            gradient: _gradient,
            fontSize: narrow ? 17 : 19,
            maxLines: 1,
            letterSpacing: narrow ? 0.8 : 1.1,
          ),
        ),
        if (_isSelf) ...[
          const SizedBox(width: 8),
          _dashboardButton(),
        ],
      ]),
    );
  }

  /// Home's square header control, with its label kept: "Dashboard" is how
  /// a seller finds their numbers from here.
  Widget _dashboardButton() => Semantics(
        button: true,
        child: GestureDetector(
          key: const Key('profile-dashboard'),
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pushNamed(context, '/seller-dashboard'),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard.withOpacity(0.86),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.insights_rounded, size: 17, color: BrokaColors.gold),
              SizedBox(width: 6),
              Text('Dashboard', style: TextStyle(
                  color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );

  Widget _buildBody() {
    switch (_state) {
      case _Load.loading:
        return _buildSkeleton();
      case _Load.notFound:
        return _message(Icons.person_off_outlined, "This profile isn't available.");
      case _Load.failed:
        return _message(Icons.cloud_off_rounded, "Couldn't load this profile.", retry: true);
      case _Load.loaded:
        break;
    }
    final sections = <Widget>[
      _buildIdentity(),
      if (_isSeller) _buildStanding(),
      if (_isSeller) _buildTrackRecord(),
      if (_isSeller) _buildReviews(),
      if (_isSeller) _buildListings(),
    ];
    return RefreshIndicator(
      onRefresh: _loadAll,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (int i = 0; i < sections.length; i++)
            FadeSlideIn(index: i, child: sections[i]),
        ]),
      ),
    );
  }

  /// In the shape of the real page, so nothing jumps when it lands.
  Widget _buildSkeleton() => const SingleChildScrollView(
        physics: NeverScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(16, 8, 16, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ShimmerBox(height: 150, radius: BorderRadius.all(Radius.circular(18))),
          SizedBox(height: 24),
          ShimmerBox(height: 176, radius: BorderRadius.all(Radius.circular(14))),
          SizedBox(height: 24),
          ShimmerBox(height: 72, radius: BorderRadius.all(Radius.circular(16))),
          SizedBox(height: 24),
          ShimmerBox(height: 120, radius: BorderRadius.all(Radius.circular(16))),
        ]),
      );

  Widget _message(IconData icon, String text, {bool retry = false}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: BrokaColors.textMid, size: 44),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 14)),
            if (retry) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setState(() => _state = _Load.loading);
                  _loadAll();
                },
                child: const Text('Try again', style: TextStyle(color: BrokaColors.gold)),
              ),
            ],
          ]),
        ),
      );

  // ── Shared pieces ─────────────────────────────────────────────────────────

  Widget _secLabel(String t) => Text(t, style: const TextStyle(
      color: BrokaColors.textMid, fontSize: 11,
      fontWeight: FontWeight.w700, letterSpacing: 1.3));

  Widget _section(String label, Widget child, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: _secLabel(label)),
            if (trailing != null) trailing,
          ]),
          const SizedBox(height: 10),
          child,
        ]),
      );

  /// Home's product card surface: the card gradient inside a thin
  /// violet-to-blue edge (the listing screen's _edgedCard).
  Widget _edgedCard({
    Key? key,
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(14),
    double radius = 16,
  }) => Container(
        key: key,
        padding: const EdgeInsets.all(1.2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            colors: [BrokaColors.gold.withOpacity(0.45), BrokaColors.neonBlue.withOpacity(0.35)],
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

  Widget _chip(IconData icon, String label, Color color, {Key? key}) => Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ]),
      );

  // ── Identity ──────────────────────────────────────────────────────────────

  Widget _buildIdentity() {
    final photo = _profile?['profile_photo'] as String?;
    final initials = Center(child: Text(_initials, style: const TextStyle(
        color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)));
    final presence = _presence;
    final location = _location;
    final distance = _distanceKm;
    final since = _memberSince;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: _edgedCard(
        radius: 18,
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              Container(
                width: 72, height: 72,
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(colors: _gradient),
                  boxShadow: [BoxShadow(
                      color: BrokaColors.gold.withOpacity(0.35), blurRadius: 16)],
                ),
                child: ClipOval(
                  child: Container(
                    color: BrokaColors.bgCard,
                    // Inline base64 or one of the user's BROKA image URLs
                    // (check_legacy_images); BrokaImage renders either. The
                    // old Image.memory(base64Decode(...)) threw on a URL.
                    child: photo != null && photo.isNotEmpty
                        ? BrokaImage(photo, width: 67, height: 67, placeholder: initials)
                        : initials,
                  ),
                ),
              ),
              if (_isVerified)
                const Positioned(
                  right: -2, bottom: -2,
                  child: CircleAvatar(
                    radius: 12,
                    backgroundColor: BrokaColors.bg,
                    child: Icon(Icons.verified_rounded, color: BrokaColors.gold, size: 20),
                  ),
                ),
            ]),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_displayName, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontSize: 20, fontWeight: FontWeight.w800, height: 1.15)),
              if (_officialName != null) ...[
                const SizedBox(height: 3),
                Row(children: [
                  const Icon(Icons.badge_outlined, size: 12, color: BrokaColors.textMid),
                  const SizedBox(width: 4),
                  Flexible(child: Text(_officialName!, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 12))),
                ]),
              ],
              if (_businessName != null) ...[
                const SizedBox(height: 3),
                Row(children: [
                  const Icon(Icons.storefront_rounded, size: 12, color: BrokaColors.textMid),
                  const SizedBox(width: 4),
                  Flexible(child: Text(_businessName!, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 12))),
                ]),
              ],
              if (presence != null) ...[
                const SizedBox(height: 6),
                Row(key: const Key('profile-presence'), children: [
                  Container(width: 7, height: 7, decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _online ? BrokaColors.neonGreen : BrokaColors.textMid)),
                  const SizedBox(width: 6),
                  Flexible(child: Text(presence, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _online ? BrokaColors.neonGreen : BrokaColors.textMid,
                          fontSize: 11.5, fontWeight: FontWeight.w600))),
                ]),
              ],
            ])),
          ]),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (_isVerified) _chip(Icons.verified_rounded, 'Verified', BrokaColors.neonGreen),
            if (location != null)
              _chip(Icons.location_on_outlined, location, BrokaColors.neonBlue),
            if (distance != null)
              _chip(Icons.near_me_outlined, '~${distance.toStringAsFixed(1)} km away',
                  BrokaColors.neonBlue, key: const Key('profile-distance')),
            if (since != null)
              _chip(Icons.calendar_month_rounded, 'Member since $since', BrokaColors.gold),
          ]),
          if (!_isSelf && _listings.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildListingsButton(),
          ],
        ]),
      ),
    );
  }

  /// The brand gradient, as on Home's and the listing screen's primary
  /// actions. It was "Start Negotiation", on whichever listing loaded
  /// first - a seller of ten things got an offer on the one the buyer never
  /// picked. One listing: open it (its screen has the price, the terms and
  /// the negotiate button). Several: take the buyer to them.
  Widget _buildListingsButton() {
    final one = _listings.length == 1;
    return Semantics(
        button: true,
        child: GestureDetector(
          key: const Key('profile-listings-button'),
          onTap: () {
            if (one) {
              Navigator.pushNamed(context, '/product', arguments: _listings.first);
              return;
            }
            final target = _listingsKey.currentContext;
            if (target != null) {
              Scrollable.ensureVisible(target,
                  duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
            }
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: _gradient),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.35), blurRadius: 14)],
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.storefront_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(one ? 'View listing' : 'See ${_listings.length} listings',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
            ]),
          ),
        ),
      );
  }

  // ── Standing ──────────────────────────────────────────────────────────────

  /// The same four figures, in the same colours, a buyer sees on each of
  /// this seller's listings.
  Widget _buildStanding() => _section(
        _isSelf ? 'YOUR STANDING, AS BUYERS SEE IT' : 'SELLER STANDING',
        SellerStandingTiles(standing: SellerStanding.fromProfile(_profile)),
      );

  // ── Track record ──────────────────────────────────────────────────────────

  Widget _buildTrackRecord() {
    final escrow = (_profile?['escrow_success_rate_pct'] as num?)?.toDouble();
    final disputes = (_profile?['dispute_rate_pct'] as num?)?.toDouble();
    final listings = _loadingListings
        ? '…'
        : (_listings.length >= _listingLimit ? '$_listingLimit+' : '${_listings.length}');
    return _section('TRACK RECORD', _edgedCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
      child: IntrinsicHeight(
        child: Row(children: [
          _fact('$_completedDeals', 'Deals done', BrokaColors.neonGreen,
              key: const Key('fact-deals')),
          _vDivider(),
          _fact(listings, 'Listings', BrokaColors.neonBlue, key: const Key('fact-listings')),
          // Null, not 0%, until a deal has been paid for: "fails every deal"
          // is not what "no deals yet" means (api/core/fraud.seller_deal_stats).
          // Hidden with payments: nobody can pay through BROKA, so it would
          // be a dash on every profile (payments_shown.dart).
          if (paymentsShown) ...[
            _vDivider(),
            _fact(escrow == null ? '—' : '${escrow.round()}%', 'Escrow success',
                BrokaColors.gold, key: const Key('fact-escrow')),
          ],
          _vDivider(),
          _fact(disputes == null ? '—' : '${disputes.round()}%', 'Disputed',
              BrokaColors.neonCyan, key: const Key('fact-disputes')),
        ]),
      ),
    ));
  }

  Widget _fact(String value, String label, Color color, {Key? key}) => Expanded(
        key: key,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, maxLines: 1, style: TextStyle(
                color: color, fontSize: 18, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(height: 3),
          Text(label, maxLines: 2, textAlign: TextAlign.center, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 9.5, fontWeight: FontWeight.w600,
              letterSpacing: 0.4)),
        ]),
      );

  Widget _vDivider() => Container(width: 1, color: BrokaColors.border,
      margin: const EdgeInsets.symmetric(vertical: 4));

  // ── Reviews ───────────────────────────────────────────────────────────────

  Future<void> _writeReview() async {
    final pending = _toReview;
    if (pending.isEmpty) return;
    HapticFeedback.selectionClick();
    // One deal to review: straight to the form. More: the review screen
    // lists this seller's, and only this seller's.
    final wrote = await Navigator.pushNamed(context, '/review', arguments: {
      'seller_id': _userId,
      'seller_name': _displayName,
      if (pending.length == 1) 'deal_id': pending.first.dealId,
      if (pending.length == 1) 'listing_name': pending.first.listingName,
    });
    if (wrote == true && mounted) {
      await Future.wait([_loadReviews(), _loadEligibility(), _loadProfile()]);
    }
  }

  Widget _buildReviews() {
    final summary = _summary;
    final canReview = !_isSelf && _toReview.isNotEmpty;
    final writeButton = canReview
        ? GestureDetector(
            key: const Key('write-review'),
            onTap: _writeReview,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: _gradient),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.rate_review_outlined, size: 13, color: Colors.white),
                SizedBox(width: 5),
                Text('Write a review', style: TextStyle(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
              ]),
            ),
          )
        : null;

    final Widget body;
    if (_loadingReviews) {
      body = const ShimmerBox(height: 110, radius: BorderRadius.all(Radius.circular(16)));
    } else if (summary == null || summary.count == 0) {
      body = _edgedCard(
        key: const Key('reviews-empty'),
        child: Column(children: [
          const Icon(Icons.star_outline_rounded, color: BrokaColors.gold, size: 30),
          const SizedBox(height: 6),
          const Text('No reviews yet', style: TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 4),
          Text(
            _isSelf
                ? 'Buyers can review you once a deal with you completes.'
                : 'Buyers can review $_displayName once a deal with them completes.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4)),
        ]),
      );
    } else {
      body = Column(children: [
        _buildReviewSummary(summary),
        const SizedBox(height: 10),
        for (final r in _reviews) _buildReviewCard(r),
      ]);
    }

    return _section('REVIEWS', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      body,
      if (_eligibilityNote() case final note?) ...[
        const SizedBox(height: 8),
        Row(key: const Key('review-eligibility'), children: [
          const Icon(Icons.info_outline_rounded, size: 13, color: BrokaColors.textMid),
          const SizedBox(width: 6),
          Expanded(child: Text(note, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 11, height: 1.35))),
        ]),
      ],
    ]), trailing: writeButton);
  }

  /// Why there is no "Write a review" button, for a buyer who might expect
  /// one. Nothing on your own profile, or before the answer is in.
  String? _eligibilityNote() {
    final deals = _reviewable;
    if (_isSelf || deals == null || _toReview.isNotEmpty) return null;
    if (deals.isNotEmpty) return "You've reviewed your deals with $_displayName.";
    return 'Only buyers who completed a deal with $_displayName can review them.';
  }

  Widget _buildReviewSummary(ReviewSummary s) {
    final avg = s.average ?? 0;
    return _edgedCard(
      key: const Key('reviews-summary'),
      child: Row(children: [
        Column(children: [
          Text(avg.toStringAsFixed(1), style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 34, fontWeight: FontWeight.w900, height: 1.0)),
          const SizedBox(height: 4),
          _stars(avg.round(), 13),
          const SizedBox(height: 3),
          Text(s.count == 1 ? '1 review' : '${s.count} reviews',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
        ]),
        const SizedBox(width: 18),
        Expanded(child: Column(children: [
          for (final star in const [5, 4, 3, 2, 1])
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(children: [
                SizedBox(width: 10, child: Text('$star', style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 10))),
                const Icon(Icons.star_rounded, color: BrokaColors.gold, size: 10),
                const SizedBox(width: 6),
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: s.count == 0 ? 0 : s.countFor(star) / s.count,
                    backgroundColor: BrokaColors.bgMid,
                    valueColor: AlwaysStoppedAnimation(
                        star >= 4 ? BrokaColors.neonGreen
                        : star == 3 ? BrokaColors.warning : BrokaColors.danger),
                    minHeight: 6,
                  ),
                )),
                const SizedBox(width: 6),
                SizedBox(width: 20, child: Text('${s.countFor(star)}',
                    textAlign: TextAlign.end,
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 10))),
              ]),
            ),
        ])),
      ]),
    );
  }

  Widget _stars(int filled, double size) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(5, (i) => Icon(
            i < filled ? Icons.star_rounded : Icons.star_outline_rounded,
            color: BrokaColors.gold, size: size)),
      );

  Widget _buildReviewCard(SellerReview r) {
    final when = r.createdAt?.toLocal();
    final name = r.reviewerName;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        gradient: BrokaColors.cardGradient,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30, height: 30,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, gradient: LinearGradient(colors: _gradient)),
            child: Center(child: Text(name.isEmpty ? 'B' : name[0].toUpperCase(),
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w800, fontSize: 12))),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh,
                    fontWeight: FontWeight.w700, fontSize: 12)),
            if (when != null)
              Text('${when.day}/${when.month}/${when.year}',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
          ])),
          _stars(r.rating, 13),
        ]),
        if (r.comment.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(r.comment, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 12, height: 1.45)),
        ],
      ]),
    );
  }

  // ── Listings ──────────────────────────────────────────────────────────────

  Widget _buildListings() {
    final Widget body;
    if (_loadingListings) {
      body = const ShimmerBox(height: 200, radius: BorderRadius.all(Radius.circular(16)));
    } else if (_listings.isEmpty) {
      body = _edgedCard(
        child: const Row(children: [
          Icon(Icons.storefront_outlined, color: BrokaColors.textMid, size: 22),
          SizedBox(width: 10),
          Text('No active listings', style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
        ]),
      );
    } else {
      body = GridView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, childAspectRatio: 0.78,
          mainAxisSpacing: 12, crossAxisSpacing: 12,
        ),
        itemCount: _listings.length,
        itemBuilder: (_, i) => _ListingCard(
          listing: _listings[i],
          onTap: () => Navigator.pushNamed(context, '/product', arguments: _listings[i]),
        ),
      );
    }
    return KeyedSubtree(
      key: _listingsKey,
      child: _section(_isSelf ? 'YOUR LISTINGS' : 'LISTINGS', body),
    );
  }
}

// ── Listing card ──────────────────────────────────────────────────────────────

/// Home's product card surface: the card gradient inside a thin gradient edge.
class _ListingCard extends StatelessWidget {
  final Listing listing;
  final VoidCallback onTap;
  const _ListingCard({required this.listing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(1.2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [BrokaColors.gold.withOpacity(0.45), BrokaColors.neonBlue.withOpacity(0.35)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            gradient: BrokaColors.cardGradient,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
              child: SizedBox(width: double.infinity, child: _thumb()),
            )),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(listing.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textHigh,
                        fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(listing.formattedPrice, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.gold, fontSize: 12,
                        fontWeight: FontWeight.w800)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  /// The stored cover, else the first legacy photo - BrokaImage renders a
  /// URL or base64 alike.
  Widget _thumb() {
    final placeholder = Container(
      color: BrokaColors.bgCard,
      alignment: Alignment.center,
      child: Text(listing.emoji, style: const TextStyle(fontSize: 34)),
    );
    final cover = listing.cover;
    if (cover != null) return BrokaImage(cover.thumb, placeholder: placeholder);
    final first = listing.verifiedPhotos?.split(',').first.trim();
    if (first != null && first.isNotEmpty) return BrokaImage(first, placeholder: placeholder);
    return placeholder;
  }
}
