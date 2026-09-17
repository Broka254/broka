// BROKA - User Profile Screen
// Public seller profile with radar graph, 10-scale ratings, verification badge,
// account age, last active, pending deals, avg deal time.
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../main.dart';
import '../models/listing.dart';
import '../services/api_service.dart';

class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key});
  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  String?                  _userId;
  Map<String, dynamic>?    _profile;
  List<Listing>                  _listings = [];
  List<Map<String, dynamic>>     _reviews  = [];
  Map<String, dynamic>?          _reviewSummary;
  bool                           _loadingProfile  = true;
  bool                           _loadingListings = true;
  bool                           _loadingReviews  = true;
  bool                           _initialized     = false;

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
    if (_userId != null) {
      _loadProfile();
      _loadListings();
      _loadReviews();
    }
  }

  Future<void> _loadProfile() async {
    setState(() => _loadingProfile = true);
    try {
      final p = await ApiService.getUserProfile(_userId!);
      if (mounted) setState(() { _profile = p; _loadingProfile = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingProfile = false);
    }
  }

  Future<void> _loadListings() async {
    setState(() => _loadingListings = true);
    try {
      final list = await ApiService.getListings(sellerId: _userId);
      if (mounted) setState(() { _listings = list; _loadingListings = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingListings = false);
    }
  }

  Future<void> _loadReviews() async {
    setState(() => _loadingReviews = true);
    try {
      final summary = await ApiService.getReviewSummary(_userId!);
      final reviews = await ApiService.getSellerReviews(_userId!, limit: 10);
      if (mounted) setState(() {
        _reviewSummary = summary;
        _reviews       = reviews;
        _loadingReviews = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingReviews = false);
    }
  }

  String get _displayName =>
      (_profile?['nickname'] as String?)?.isNotEmpty == true
          ? _profile!['nickname'] as String
          : _profile?['name'] as String? ?? 'Broka User';

  String get _officialName => _profile?['name'] as String? ?? _displayName;

  String get _initials {
    final name = _profile?['name'] as String? ?? 'B';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : 'B';
  }

  // ── Score helpers (normalise to 10-scale) ─────────────────────────────────

  double get _reliabilityScore {
    final raw = (_profile?['reliability_score'] as num?)?.toDouble()
        ?? (_profile?['rating'] as num?)?.toDouble() ?? 5.0;
    return (raw <= 5.0 ? raw * 2 : raw).clamp(0.0, 10.0);
  }

  double get _trustScore {
    final raw = (_profile?['trust_score'] as num?)?.toDouble()
        ?? (_profile?['rating'] as num?)?.toDouble() ?? 5.0;
    return (raw <= 5.0 ? raw * 2 : raw).clamp(0.0, 10.0);
  }

  double get _avgRating {
    final raw = (_profile?['rating'] as num?)?.toDouble() ?? 5.0;
    return (raw <= 5.0 ? raw * 2 : raw).clamp(0.0, 10.0);
  }

  double get _responseRate =>
      (_profile?['response_rate'] as num?)?.toDouble() ?? 85.0;

  int get _completedDeals => (_profile?['completed_deals'] as num?)?.toInt() ?? 0;
  int get _pendingDeals   => (_profile?['pending_deals']   as num?)?.toInt() ?? 0;
  bool get _isVerified    => _profile?['is_verified'] as bool? ?? false;
  String? get _location   => _profile?['location_name'] as String?;

  String get _memberSince {
    final raw = _profile?['created_at'] as String?;
    if (raw == null) return 'Unknown';
    try {
      final dt = DateTime.parse(raw);
      final months = ['Jan','Feb','Mar','Apr','May','Jun',
                      'Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[dt.month - 1]} ${dt.year}';
    } catch (_) { return 'Unknown'; }
  }

  String get _lastActive {
    final raw = _profile?['last_seen'] as String?;
    if (raw == null) return 'Unknown';
    try {
      final dt = DateTime.parse(raw);
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 2)  return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24)   return '${diff.inHours}h ago';
      if (diff.inDays < 7)     return '${diff.inDays}d ago';
      return '${(diff.inDays / 7).floor()}w ago';
    } catch (_) { return 'Unknown'; }
  }

  String get _avgDealTime {
    final mins = (_profile?['avg_deal_time_minutes'] as num?)?.toInt();
    if (mins == null) return 'N/A';
    if (mins < 60)  return '${mins}m';
    if (mins < 1440) return '${(mins / 60).round()}h';
    return '${(mins / 1440).round()}d';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: CustomScrollView(slivers: [
        _buildAppBar(),
        SliverToBoxAdapter(child: _buildBody()),
      ]),
    );
  }

  Widget _buildAppBar() => SliverAppBar(
    backgroundColor: BrokaColors.bgMid,
    pinned: true,
    expandedHeight: 0,
    leading: GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.border),
        ),
        child: const Icon(Icons.arrow_back_ios_new_rounded,
            color: BrokaColors.textMid, size: 16),
      ),
    ),
    title: Text(_loadingProfile ? 'Profile' : _displayName,
        style: const TextStyle(color: BrokaColors.textHigh,
            fontSize: 16, fontWeight: FontWeight.w800)),
    actions: [
      if (_userId == ApiService.currentUserId)
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, '/seller-dashboard'),
          child: Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.goldDim]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text('Dashboard', style: TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ),
    ],
  );

  Widget _buildBody() {
    if (_loadingProfile) {
      return const SizedBox(height: 300,
          child: Center(child: CircularProgressIndicator(color: BrokaColors.gold)));
    }
    if (_profile == null) {
      return const SizedBox(height: 300,
          child: Center(child: Text('User not found.',
              style: TextStyle(color: BrokaColors.textMid))));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildHeroSection(),
      _buildInfoGrid(),
      _buildScoresSection(),
      _buildRadarSection(),
      _buildStatsRow(),
      const SizedBox(height: 20),
      _buildReviewsSection(),
      const SizedBox(height: 20),
      _buildSectionLabel('LISTINGS'),
      _buildListingsGrid(),
      const SizedBox(height: 40),
    ]);
  }

  // ── Hero ──────────────────────────────────────────────────────────────────

  Widget _buildHeroSection() {
    final photo    = _profile?['profile_photo'] as String?;
    final distKm   = _profile?['distance_km'];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF070B16), BrokaColors.bg],
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
        ),
      ),
      child: Column(children: [
        // Avatar with verification ring
        Stack(alignment: Alignment.bottomRight, children: [
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.goldDim]),
              boxShadow: const [BrokaColors.glowGold],
              border: Border.all(
                color: _isVerified
                    ? BrokaColors.gold : BrokaColors.gold.withOpacity(0.5),
                width: _isVerified ? 3 : 2),
            ),
            child: ClipOval(
              child: photo != null && photo.isNotEmpty
                  ? Image.memory(base64Decode(photo), fit: BoxFit.cover)
                  : Center(child: Text(_initials,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 34, fontWeight: FontWeight.w800))),
            ),
          ),
          if (_isVerified)
            Container(
              width: 28, height: 28,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: BrokaColors.bgMid),
              child: const Icon(Icons.verified_rounded,
                  color: BrokaColors.gold, size: 22),
            ),
        ]),
        const SizedBox(height: 14),

        // Display name
        Text(_displayName,
            style: const TextStyle(color: BrokaColors.textHigh,
                fontSize: 22, fontWeight: FontWeight.w800)),

        // Official name if different
        if (_officialName != _displayName) ...[
          const SizedBox(height: 3),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.badge_outlined, size: 12, color: BrokaColors.textMid),
            const SizedBox(width: 4),
            Text(_officialName, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 13)),
          ]),
        ],

        const SizedBox(height: 8),

        // Location + distance
        if (_location != null || distKm != null)
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.location_on_rounded,
                size: 13, color: BrokaColors.neonBlue),
            const SizedBox(width: 4),
            Text(_location ?? 'Kenya',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
            if (distKm != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: BrokaColors.neonBlue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.3)),
                ),
                child: Text('$distKm km away',
                    style: const TextStyle(color: BrokaColors.neonBlue,
                        fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ],
          ]),

        const SizedBox(height: 10),

        // Badges row
        Wrap(spacing: 8, runSpacing: 6, alignment: WrapAlignment.center, children: [
          if (_isVerified) _badge('✓ Verified', BrokaColors.gold),
          _badge('⭐ ${_avgRating.toStringAsFixed(1)}/10', BrokaColors.gold),
          _badge('${_completedDeals} deals', BrokaColors.gold),
          _badge('Member since $_memberSince', BrokaColors.neonBlue),
        ]),

        const SizedBox(height: 16),

        // Action buttons
        if (_userId != ApiService.currentUserId)
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  if (_listings.isNotEmpty) {
                    Navigator.pushNamed(context, '/negotiate',
                        arguments: {'listing': _listings.first, 'role': 'buyer'});
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('This user has no active listings.')));
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [BrokaColors.gold, BrokaColors.goldDim]),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [BrokaColors.glowGold],
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.handshake_outlined, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text('Start Negotiation', style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                  ]),
                ),
              ),
            ),
          ]),
      ]),
    );
  }

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Text(label, style: TextStyle(
        color: color, fontSize: 11, fontWeight: FontWeight.w700)),
  );

  // ── Info Grid (meta fields) ───────────────────────────────────────────────

  Widget _buildInfoGrid() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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
          Expanded(child: _infoItem(Icons.access_time_rounded, 'Last Active', _lastActive, BrokaColors.neonGreen)),
          const SizedBox(width: 16),
          Expanded(child: _infoItem(Icons.schedule_rounded, 'Avg Deal Time', _avgDealTime, BrokaColors.neonBlue)),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _infoItem(Icons.pending_actions_rounded, 'Pending Deals', '$_pendingDeals', BrokaColors.warning)),
          const SizedBox(width: 16),
          Expanded(child: _infoItem(Icons.calendar_month_rounded, 'Member Since', _memberSince, BrokaColors.gold)),
        ]),
      ]),
    ),
  );

  Widget _infoItem(IconData icon, String label, String value, Color color) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 15),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(color: BrokaColors.textHigh,
              fontSize: 13, fontWeight: FontWeight.w700)),
        ])),
      ]);

  // ── Score Bars ────────────────────────────────────────────────────────────

  Widget _buildScoresSection() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('PERFORMANCE SCORES (out of 10)', style: TextStyle(
            color: BrokaColors.textLow, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 1.0)),
        const SizedBox(height: 14),
        _scoreBar('Reliability', _reliabilityScore, BrokaColors.gold),
        const SizedBox(height: 10),
        _scoreBar('Trust Score', _trustScore, BrokaColors.neonBlue),
        const SizedBox(height: 10),
        _scoreBar('Average Rating', _avgRating, BrokaColors.gold),
        const SizedBox(height: 10),
        _scoreBar('Response Rate', _responseRate / 10, BrokaColors.neonGreen),
      ]),
    ),
  );

  Widget _scoreBar(String label, double value, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      Expanded(child: Text(label, style: const TextStyle(
          color: BrokaColors.textMid, fontSize: 12))),
      Text('${value.toStringAsFixed(1)}/10', style: TextStyle(
          color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    ]),
    const SizedBox(height: 5),
    Stack(children: [
      Container(height: 6, decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(3))),
      FractionallySizedBox(
        widthFactor: (value / 10).clamp(0.0, 1.0),
        child: Container(height: 6, decoration: BoxDecoration(
          color: color, borderRadius: BorderRadius.circular(3),
          boxShadow: [BoxShadow(color: color.withOpacity(0.4), blurRadius: 4)],
        )),
      ),
    ]),
  ]);

  // ── Radar Chart ───────────────────────────────────────────────────────────

  Widget _buildRadarSection() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
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
          const Icon(Icons.radar_rounded, color: BrokaColors.gold, size: 16),
          const SizedBox(width: 8),
          const Text('TRADER PROFILE RADAR', style: TextStyle(
              color: BrokaColors.textLow, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 1.0)),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: CustomPaint(
            painter: _RadarPainter(
              values: [
                _reliabilityScore / 10,
                _trustScore / 10,
                _avgRating / 10,
                _responseRate / 100,
                (_completedDeals / math.max(_completedDeals + 3, 10)).clamp(0.0, 1.0),
              ],
              labels: ['Reliability', 'Trust', 'Rating', 'Response', 'Deals'],
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ]),
    ),
  );

  // ── Stats Row ─────────────────────────────────────────────────────────────

  Widget _buildStatsRow() => Container(
    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    padding: const EdgeInsets.symmetric(vertical: 16),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
          begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      _stat('${_listings.length}', 'Active'),
      _divider(),
      _stat('$_completedDeals', 'Completed'),
      _divider(),
      _stat('$_pendingDeals', 'Pending'),
      _divider(),
      _stat('${_avgRating.toStringAsFixed(1)}★', 'Rating'),
    ]),
  );

  Widget _stat(String value, String label) => Column(children: [
    Text(value, style: const TextStyle(color: BrokaColors.textHigh,
        fontSize: 17, fontWeight: FontWeight.w800)),
    const SizedBox(height: 2),
    Text(label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
  ]);

  Widget _divider() =>
      Container(width: 1, height: 30, color: BrokaColors.border);

  // ── Listings Grid ─────────────────────────────────────────────────────────

  // ── Reviews Section ───────────────────────────────────────────────────────

  Widget _buildReviewsSection() {
    final avg   = (_reviewSummary?['avg']   as num?)?.toDouble() ?? 0.0;
    final count = (_reviewSummary?['count'] as num?)?.toInt()    ?? 0;
    final dist  = _reviewSummary?['distribution'] as Map? ?? {};
    final isSelf = _userId == ApiService.currentUserId;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header row
        Row(children: [
          const Text('REVIEWS',
              style: TextStyle(color: BrokaColors.textLow,
                  fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          const Spacer(),
          // "Write a Review" - visible only to other users (not self)
          if (!isSelf && ApiService.currentUserId != null)
            GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/review', arguments: {
                'deal_id':      '',     // user will pick from their deals on that screen
                'seller_id':    _userId ?? '',
                'seller_name':  _displayName,
                'listing_name': '',
              }).then((wrote) {
                if (wrote == true) _loadReviews();
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [BrokaColors.gold, Color(0xFFF59E0B)]),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.star_rounded, size: 11, color: Colors.black87),
                  SizedBox(width: 4),
                  Text('Write a Review',
                      style: TextStyle(color: Colors.black87,
                          fontSize: 10, fontWeight: FontWeight.w800)),
                ]),
              ),
            ),
        ]),
        const SizedBox(height: 12),

        if (_loadingReviews)
          const Center(child: Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(color: BrokaColors.gold),
          ))
        else if (count == 0)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Column(children: [
              Text('⭐', style: TextStyle(fontSize: 32)),
              SizedBox(height: 8),
              Text('No reviews yet',
                  style: TextStyle(color: BrokaColors.textMid,
                      fontWeight: FontWeight.w700)),
              SizedBox(height: 4),
              Text('Complete a deal to leave the first review.',
                  style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
            ]),
          )
        else ...[
          // Summary card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Row(children: [
              // Big average number
              Column(children: [
                Text(avg.toStringAsFixed(1),
                    style: const TextStyle(color: BrokaColors.textHigh,
                        fontSize: 36, fontWeight: FontWeight.w900)),
                Row(children: List.generate(5, (i) => Icon(
                  i < avg.round()
                      ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: BrokaColors.gold, size: 14,
                ))),
                const SizedBox(height: 2),
                Text('$count review${count == 1 ? '' : 's'}',
                    style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
              ]),
              const SizedBox(width: 20),
              // Star distribution bars
              Expanded(child: Column(
                children: [5, 4, 3, 2, 1].map((star) {
                  final c = (dist[star] as num?)?.toInt() ?? 0;
                  final pct = count > 0 ? c / count : 0.0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(children: [
                      Text('$star', style: const TextStyle(
                          color: BrokaColors.textLow, fontSize: 10)),
                      const SizedBox(width: 4),
                      const Icon(Icons.star_rounded, color: BrokaColors.gold, size: 10),
                      const SizedBox(width: 6),
                      Expanded(child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          backgroundColor: BrokaColors.bgMid,
                          valueColor: AlwaysStoppedAnimation(
                              star >= 4 ? BrokaColors.neonGreen
                              : star == 3 ? BrokaColors.gold
                              : Colors.redAccent),
                          minHeight: 6,
                        ),
                      )),
                      const SizedBox(width: 6),
                      SizedBox(width: 18, child: Text('$c',
                          style: const TextStyle(
                              color: BrokaColors.textLow, fontSize: 10))),
                    ]),
                  );
                }).toList(),
              )),
            ]),
          ),

          const SizedBox(height: 12),

          // Individual review cards
          ..._reviews.map((r) {
            final name    = r['reviewer_name'] as String? ?? 'Buyer';
            final rating  = (r['rating'] as num?)?.toInt() ?? 0;
            final comment = r['comment'] as String? ?? '';
            final rawDate = r['created_at'] as String?;
            String dateStr = '';
            if (rawDate != null) {
              try {
                final dt = DateTime.parse(rawDate).toLocal();
                dateStr = '${dt.day}/${dt.month}/${dt.year}';
              } catch (_) {}
            }
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: BrokaColors.border),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  // Reviewer avatar
                  Container(
                    width: 32, height: 32,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                          colors: [BrokaColors.gold, BrokaColors.goldDim]),
                    ),
                    child: Center(child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : 'B',
                      style: const TextStyle(color: Colors.white,
                          fontWeight: FontWeight.w800, fontSize: 13),
                    )),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: const TextStyle(color: BrokaColors.textHigh,
                        fontWeight: FontWeight.w700, fontSize: 12)),
                    Text(dateStr, style: const TextStyle(
                        color: BrokaColors.textLow, fontSize: 10)),
                  ])),
                  // Stars
                  Row(children: List.generate(5, (i) => Icon(
                    i < rating
                        ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: BrokaColors.gold, size: 13,
                  ))),
                ]),
                if (comment.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(comment,
                      style: const TextStyle(color: BrokaColors.textMid,
                          fontSize: 12, height: 1.5)),
                ],
              ]),
            );
          }),
        ],
      ]),
    );
  }

  Widget _buildSectionLabel(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: Text(label, style: const TextStyle(color: BrokaColors.textLow,
        fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
  );

  Widget _buildListingsGrid() {
    if (_loadingListings) return const Padding(padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(color: BrokaColors.gold)));
    if (_listings.isEmpty) return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(child: Column(children: [
        const Icon(Icons.store_outlined, color: BrokaColors.textLow, size: 36),
        const SizedBox(height: 8),
        const Text('No active listings', style: TextStyle(color: BrokaColors.textMid)),
      ])),
    );
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2, childAspectRatio: 0.75,
        mainAxisSpacing: 12, crossAxisSpacing: 12,
      ),
      itemCount: _listings.length,
      itemBuilder: (_, i) => _ListingCard(
        listing: _listings[i],
        onTap: () => Navigator.pushNamed(context, '/product',
            arguments: _listings[i]),
      ),
    );
  }
}

// ── Radar Painter ─────────────────────────────────────────────────────────────
class _RadarPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;

  static const _colors = [
    BrokaColors.gold, BrokaColors.neonBlue, BrokaColors.gold,
    BrokaColors.neonGreen, BrokaColors.neonCyan,
  ];

  _RadarPainter({required this.values, required this.labels});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = math.min(cx, cy) - 30;
    final n  = values.length;

    // Grid rings
    for (int ring = 1; ring <= 4; ring++) {
      final rr = r * ring / 4;
      final path = Path();
      for (int i = 0; i < n; i++) {
        final angle = 2 * math.pi * i / n - math.pi / 2;
        final x = cx + rr * math.cos(angle);
        final y = cy + rr * math.sin(angle);
        if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
      }
      path.close();
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..color = BrokaColors.border
        ..strokeWidth = 0.8);
    }

    // Axes
    for (int i = 0; i < n; i++) {
      final angle = 2 * math.pi * i / n - math.pi / 2;
      canvas.drawLine(Offset(cx, cy),
        Offset(cx + r * math.cos(angle), cy + r * math.sin(angle)),
        Paint()..color = BrokaColors.border..strokeWidth = 0.8);
    }

    // Data polygon fill
    final dataPath = Path();
    for (int i = 0; i < n; i++) {
      final angle = 2 * math.pi * i / n - math.pi / 2;
      final rv = r * values[i];
      final pt = Offset(cx + rv * math.cos(angle), cy + rv * math.sin(angle));
      if (i == 0) dataPath.moveTo(pt.dx, pt.dy); else dataPath.lineTo(pt.dx, pt.dy);
    }
    dataPath.close();

    canvas.drawPath(dataPath, Paint()
      ..style = PaintingStyle.fill
      ..color = BrokaColors.gold.withOpacity(0.18));
    canvas.drawPath(dataPath, Paint()
      ..style = PaintingStyle.stroke
      ..color = BrokaColors.gold
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round);

    // Dots + labels
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < n; i++) {
      final angle = 2 * math.pi * i / n - math.pi / 2;
      final rv = r * values[i];
      final pt = Offset(cx + rv * math.cos(angle), cy + rv * math.sin(angle));

      canvas.drawCircle(pt, 5, Paint()..color = _colors[i % _colors.length]);
      canvas.drawCircle(pt, 5, Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withOpacity(0.6)
        ..strokeWidth = 1.5);

      // Label
      final lx = cx + (r + 22) * math.cos(angle);
      final ly = cy + (r + 22) * math.sin(angle);
      tp.text = TextSpan(
        text: '${labels[i]}\n${(values[i] * 10).toStringAsFixed(1)}',
        style: TextStyle(color: _colors[i % _colors.length],
            fontSize: 8.5, fontWeight: FontWeight.w700),
      );
      tp.layout();
      tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => true;
}

// ── Listing Card ──────────────────────────────────────────────────────────────
class _ListingCard extends StatelessWidget {
  final Listing listing;
  final VoidCallback onTap;
  const _ListingCard({required this.listing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
            child: Container(width: double.infinity, color: BrokaColors.bgCard,
                child: _buildThumb()),
          )),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(listing.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(listing.formattedPrice, style: const TextStyle(
                  color: BrokaColors.gold, fontSize: 12,
                  fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildThumb() {
    final photos = listing.verifiedPhotos;
    if (photos != null && photos.isNotEmpty) {
      final first = photos.split(',').first.trim();
      if (first.isNotEmpty) {
        try {
          return Image.memory(base64Decode(first), fit: BoxFit.cover);
        } catch (_) {
          return Image.network(first, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholder());
        }
      }
    }
    return _placeholder();
  }

  Widget _placeholder() => Center(child: Text(listing.emoji,
      style: const TextStyle(fontSize: 36)));
}
