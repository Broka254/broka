// BROKA — Seller Analytics Command Centre v4.0
// Futuristic UI: radial gauges · glow revenue chart · deal pipeline · Zeno insight cards · revenue calc
// All v3 features preserved: radar, HexTrustBadge, per-product views/day + week, Zeno pricing,
// deal status pills, platform escrow, transaction receipts.
//
// 2026-09-26: on Home's visual system - the constellation, the header every
// screen reached from Home uses (bare back chevron, badge, glowing title,
// square controls) and a pill tab switcher in the brand gradient - instead
// of its own background, a boxed back button, a "LIVE" pill and a Material
// tab strip with a gold underline. What is on the three tabs is unchanged.
//
// 2026-09-29: linked with My Store, the online store's own dashboard. The
// Overview shows the store (open or paused, its link, products, the week's
// visits, Manage) right under the seller's numbers, or the way to open one;
// a store button in the header opens it from any tab. My Store links back.
//
// 2026-09-30: the average deal time - agreement to payout, over the seller's
// recent completed deals - beside Deals Done in the header. Buyers see the
// same figure on the seller's listings and profile. And a Delete on each
// product, which the dashboard never had.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../widgets/motion_widgets.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/axis_line_chart.dart';
import '../widgets/factor_trend_chart.dart';
import '../widgets/zeno_avatar.dart';
import '../data/seller_insights.dart';
import '../theme/motion.dart';
import '../services/api_service.dart';
import '../widgets/particle_field.dart';
import '../models/listing.dart';
import '../models/seller_standing.dart';
import '../core/utils/result.dart';
import '../features/listing_fee/presentation/awaiting_payment_panel.dart';
import '../features/listings/data/repositories/listings_repository.dart';
import '../features/stores/presentation/store_entry.dart';
import '../features/stores/presentation/widgets/menu_store_section.dart';

class SellerDashboardScreen extends StatefulWidget {
  const SellerDashboardScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;
  @override
  State<SellerDashboardScreen> createState() => _SellerDashboardScreenState();
}

class _SellerDashboardScreenState extends State<SellerDashboardScreen>
    with TickerProviderStateMixin {

  // ── Core state ──────────────────────────────────────────────────────────────
  Map<String, dynamic>? _profile;
  List<Listing>         _listings = [];
  bool                  _loading  = true;

  late final TabController       _tabs;
  late final AnimationController _glow;
  // Drives the deal pipeline's flowing arrows.
  late final AnimationController _pulse;

  // ── Per-listing state ────────────────────────────────────────────────────────
  final Map<String, bool>                  _expanded           = {};
  final Map<String, String?>               _listingZeno        = {};
  final Map<String, bool>                  _listingZenoLoading = {};
  final Map<String, Map<String, dynamic>?> _dealStatusMap      = {};
  final Map<String, Map<String, dynamic>?> _boostStatusMap     = {};
  bool                                     _dealsTabLoaded     = false;

  // ── Overview UI state ────────────────────────────────────────────────────────
  bool _revenueWeekMode = true;

  // ── Calculator ───────────────────────────────────────────────────────────────
  // Two strings. The previous version carried five inputs, three text
  // controllers and five derived getters to model a revenue projection from
  // numbers a market trader does not track.
  String _calcExpression = '';
  String _calcResult     = '0';

  // ── Constants ────────────────────────────────────────────────────────────────

  // _staticTips removed - superseded by kSellerInsights in
  // data/seller_insights.dart. It was the fallback list behind the AI
  // insights section, and two things were wrong with it beyond being dead
  // code: it still advertised "Get verified", which no longer exists, and
  // every card quoted a multiplier nobody measured - 4x more views, 60%
  // better deal chances, 3x more deals. The replacements state mechanisms
  // the platform actually applies instead of statistics it cannot support.

  // ── Lifecycle ────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && _tabs.index == 2) _ensureDealsLoaded();
    });
    _glow  = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    // Rebuilds the tab switcher, which draws its own selected state.
    _tabs.animation?.addListener(() {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose(); _glow.dispose(); _pulse.dispose();
    super.dispose();
  }

  // ── Data loaders ─────────────────────────────────────────────────────────────
  // Bumped on every refresh, so the waiting-for-payment panel reloads too.
  int _feeReload = 0;

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _dealsTabLoaded = false; _feeReload++; });
    try {
      final uid = ApiService.currentUserId;
      if (uid == null) { if (mounted) setState(() => _loading = false); return; }
      final profile  = await ApiService.getUserProfile(uid);
      // 50 was presented as the seller's whole catalogue: _pipeListed is
      // _listings.length and _totalViews sums these rows, so a seller with
      // more than 50 products silently saw a truncated business. Raised,
      // and _catalogueTruncated below says so if the new ceiling is hit too
      // rather than quietly under-reporting again.
      final listings = await ApiService.getListings(sellerId: uid, limit: _catalogueLimit);
      if (!mounted) return;
      setState(() { _profile = profile; _listings = listings; _loading = false; });
      _loadRevenue();
      _loadMetrics();
      await _loadStatuses(listings.take(_overviewPreload).toList());
      // If the user sat on the Deals tab while this was loading, the tab
      // listener already fired against an empty _listings and there is no
      // second event coming. Catch up now.
      if (_tabs.index == 2) _ensureDealsLoaded();
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  Map<String, dynamic>? _metrics;
  bool _metricsLoading = false;

  /// Seller standing + daily history + advice, from the Phase 2 endpoint.
  Future<void> _loadMetrics() async {
    if (_metricsLoading) return;
    final uid = ApiService.currentUserId;
    if (uid == null) return;
    if (mounted) setState(() => _metricsLoading = true);
    try {
      final m = await ApiService.getSellerMetrics(uid, days: 90);
      if (mounted) setState(() { _metrics = m; _metricsLoading = false; });
    } catch (_) {
      // Non-fatal: the rest of the dashboard is independent of this call,
      // and an empty trend section is better than an error screen over the
      // parts that did load.
      if (mounted) setState(() => _metricsLoading = false);
    }
  }

  /// Today's value for a metric, so a chart with no history can still plot
  /// a point against its bands instead of saying "no history yet".
  double? _live(String key) =>
      ((_metrics?['current'] as Map?)?[key] as num?)?.toDouble();

  List<TrendPoint> _series(String key) {
    final hist = (_metrics?['history'] as List?) ?? const [];
    return [
      for (final row in hist)
        TrendPoint(
          DateTime.tryParse(row['date'] as String? ?? '') ?? DateTime.now(),
          (row[key] as num?)?.toDouble(),
        ),
    ];
  }

  /// Ceiling on listings fetched for this screen.
  static const _catalogueLimit = 200;

  /// True when the seller may have more products than we loaded, so totals
  /// derived from _listings are floors rather than facts.
  bool get _catalogueTruncated => _listings.length >= _catalogueLimit;

  /// How many listings get their deal/boost status fetched up front.
  /// Enough to fill the Overview funnel above the fold without opening
  /// with a burst of requests.
  static const _overviewPreload = 5;

  /// Max status fetches in flight at once. 50 listings x 2 endpoints was
  /// 100 simultaneous requests the moment the Deals tab was opened - enough
  /// to trip rate limiting, and on a Kenyan mobile connection enough to
  /// make every one of them slow.
  static const _statusConcurrency = 6;

  bool _dealsLoading = false;

  /// Load statuses for the Deals tab, exactly once, and only when there is
  /// something to load.
  ///
  /// BUG (2026-09-15): the old listener set `_dealsTabLoaded = true` before
  /// looping, so opening the Deals tab DURING the initial load marked it
  /// done against an empty `_listings`. The loop did nothing, the flag
  /// stayed true, and deal status never appeared for the rest of the
  /// session - the seller saw every listing as plain "Active" no matter
  /// what was actually in escrow. Setting the flag only after a non-empty
  /// run, plus the catch-up in _load above, closes both halves of it.
  Future<void> _ensureDealsLoaded() async {
    if (_dealsTabLoaded || _dealsLoading || _listings.isEmpty) return;
    _dealsLoading = true;
    try {
      await _loadStatuses(_listings);
      _dealsTabLoaded = true;
    } finally {
      _dealsLoading = false;
    }
  }

  /// Fetch deal + boost status for [items], at most [_statusConcurrency]
  /// listings at a time.
  Future<void> _loadStatuses(List<Listing> items) async {
    for (var i = 0; i < items.length; i += _statusConcurrency) {
      if (!mounted) return;
      final batch = items.skip(i).take(_statusConcurrency);
      await Future.wait([
        for (final l in batch) ...[_loadDealStatus(l.id), _loadBoostStatus(l.id)],
      ]);
    }
  }

  // _loadZenoGlobal() removed with the Zeno Live Analysis section.
  //
  // It asked the model for dashboard tips on every load and every refresh
  // tap, and produced generic marketplace advice because it was never given
  // the seller's objectives or plans. Tokens spent to restate what the
  // static insight cards now say better and for free.

  Future<void> _loadZenoForListing(Listing l) async {
    // A billed model call. The cached-result check alone did
    // not stop a second call, because nothing is cached until the first one
    // RETURNS - so tapping a listing twice while it was thinking bought two
    // answers to the same question.
    if (_listingZeno.containsKey(l.id)) return;
    if (_listingZenoLoading[l.id] == true) return;
    if (mounted) setState(() => _listingZenoLoading[l.id] = true);
    try {
      final reply = await ApiService.zenoChat(
        message: 'Kenyan BROKA seller. Product: ${l.name}. '
            'Category: ${l.category}. Price: KES ${l.price.toStringAsFixed(0)}. '
            'Views: ${l.views}. Give 2 specific pricing recommendations with KES ranges. '
            'One sentence each. Numbered list.',
        history: const [], language: ApiService.currentUserLanguage);
      if (mounted) setState(() { _listingZeno[l.id] = reply; _listingZenoLoading[l.id] = false; });
    } catch (_) { if (mounted) setState(() => _listingZenoLoading[l.id] = false); }
  }

  Future<void> _loadDealStatus(String id) async {
    try {
      final r = await ApiService.getDealStatus(id);
      if (mounted) setState(() => _dealStatusMap[id] = r);
    } catch (_) { if (mounted) setState(() => _dealStatusMap[id] = null); }
  }

  Future<void> _loadBoostStatus(String id) async {
    try {
      final r = await ApiService.checkBoostStatus(id);
      if (mounted) setState(() => _boostStatusMap[id] = r);
    } catch (_) { if (mounted) setState(() => _boostStatusMap[id] = null); }
  }

  // ── Computed props ───────────────────────────────────────────────────────────
  //
  // SCALES. Every score below came through one `_toTen` helper that guessed
  // the source scale from the value itself:
  //
  //     (d <= 5 ? d * 2 : d).clamp(0, 10)
  //
  // That is unrecoverable, because the guess is wrong for the field this
  // dashboard leans on hardest. `trust_score` is 0-100 on the backend
  // (api/core/fraud.trust_band: >=80 trusted, >=50 standard, >=20 at_risk),
  // so EVERY value from 6 to 100 fell through the `else` branch and got
  // clamped straight to 10. A seller sitting at 15/100 - "high_risk", the
  // band that suppresses their ranking - was shown **10.0/10**.
  //
  // `_toTen(null)` was worse: null became 5.0, 5.0 doubled to 10. A brand
  // new seller with no history at all opened this screen to three perfect
  // scores. The one number that would tell them why nobody is buying was
  // guaranteed to say everything is fine.
  //
  // Each field is now converted from its own known scale, and absent data
  // returns null instead of a flattering default.
  static const _ratingMax = 5.0;    // User.rating       (DB default 5.0)
  static const _trustMax  = 100.0;  // User.trust_score  (DB default 100)

  double? _scaled(num? v, double sourceMax) {
    if (v == null) return null;
    return ((v.toDouble() / sourceMax) * 10).clamp(0, 10);
  }

  /// 0-10, or null when the backend has no value.
  ///
  /// No longer plotted. trust_score is 0-100 on the backend and every value
  /// above 6 clamped to a flat 10/10, so as a chart axis it said nothing;
  /// credibility replaced it on the triangle. Kept as a getter because the
  /// underlying score still drives ranking server-side.
  double? get _trustScore => _scaled(_profile?['trust_score'], _trustMax);
  double? get _avgRating  => _scaled(_profile?['rating'], _ratingMax);

  /// Deal completion rate, 0-10. Present only once the seller has completed
  /// a deal - see auth/service.py, which only attaches dcr_score then.
  ///
  /// This replaces "Reliability", which read `_profile['reliability_score']`
  /// - a key the API has never returned. It silently fell back to `rating`,
  /// so the dashboard showed the same number twice under two different
  /// labels and called one of them reliability.
  double? get _reliability => _scaled(_dcrScore, 100.0);

  // NOTE: there is no `_responseRate`. `response_rate` is not a field the
  // API returns and never has been; the getter that used to live here
  // defaulted to 85.0, so every seller on the platform saw an identical,
  // invented "85% response" figure styled exactly like the real metrics
  // beside it. If a genuine reply-rate is added to the profile payload,
  // reinstate the tile then - not before.
  int    get _completedDeals => (_profile?['completed_deals'] as num?)?.toInt() ?? 0;

  /// Mean minutes from agreement to payout over recent completed deals
  /// (backend trust/deal_time.py). Null before the first completed deal,
  /// shown as a dash rather than a 0 that would read as instant.
  double? get _dealTimeMinutes => (_profile?['avg_deal_time_minutes'] as num?)?.toDouble();
  /// Summed over loaded listings.
  ///
  /// The old fallback read `_profile['total_views']` when the list was
  /// empty - a key the API does not return, so that branch evaluated to 0
  /// for everyone and was indistinguishable from the sum of no listings.
  /// Dropped rather than left as a read that looks like a data source.
  int    get _totalViews   => _listings.fold(0, (s, l) => s + l.views);
  bool   get _isVerified   => _profile?['is_verified'] as bool? ?? false;
  int    get _activeCount  => _listings.where((l) => l.status.toLowerCase() == 'active').length;
  int    get _featuredCount => _listings.where((l) => l.isFeatured).length;


  // ── Performance trends (Design Journal Vol.8 §3.2-§3.4) ───────────────────

  /// Six factors over time, each banded into good / acceptable / poor.
  ///
  /// Thresholds are stated here rather than in the chart so they are
  /// visible and arguable in one place. Direction differs per metric:
  /// higher DCR is better, lower response time is better, and the chart
  /// flips the green band accordingly - telling a seller that a worsening
  /// reply time is an improvement would be worse than showing no chart.
  Widget _buildTrendSection() {
    if (_metrics == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _secLabel('PERFORMANCE OVER TIME'),
          const SizedBox(height: 10),
          const ShimmerBox(height: 220,
              radius: BorderRadius.all(Radius.circular(16))),
        ]),
      );
    }

    final charts = <Widget>[
      FactorTrendChart(
        label: 'Overall rating',
        points: _series('overall_rating'),
        currentValue: _live('overall_rating'),
        // Shared with the listing screen's seller standing, which shows
        // buyers these three figures in the same colours.
        goodThreshold: SellerStanding.ratingGood, poorThreshold: SellerStanding.ratingPoor,
        format: (v) => '${v.toStringAsFixed(1)}/10',
        yTitle: 'Rating out of 10',
        lineColor: BrokaColors.gold,
      ),
      FactorTrendChart(
        label: 'Deal completion rate',
        points: _series('dcr'),
        currentValue: _live('dcr'),
        goodThreshold: SellerStanding.dcrGood, poorThreshold: SellerStanding.dcrPoor,
        format: (v) => '${v.toStringAsFixed(0)}%',
        yTitle: 'Completed %',
        lineColor: BrokaColors.neonGreen,
      ),
      FactorTrendChart(
        label: 'Response time',
        points: _series('response_minutes'),
        currentValue: _live('median_response_minutes'),
        // Lower is better: green sits at the BOTTOM of this one.
        higherIsBetter: false,
        goodThreshold: SellerStanding.responseGood, poorThreshold: SellerStanding.responsePoor,
        format: SellerStanding.formatMinutes,
        yTitle: 'Reply time',
        lineColor: BrokaColors.neonBlue,
      ),
      FactorTrendChart(
        label: 'Rank position',
        points: _series('rank_position'),
        currentValue: _live('rank_position'),
        // #1 is the best rank, so smaller is better here too.
        higherIsBetter: false,
        goodThreshold: 10.0, poorThreshold: 50.0,
        format: (v) => '#${v.round()}',
        yTitle: 'Rank',
        wholeNumbers: true,
        lineColor: BrokaColors.neonCyan,
      ),
      FactorTrendChart(
        label: 'Deals completed',
        points: _series('completed_deals'),
        currentValue: _live('completed_deals'),
        goodThreshold: 20.0, poorThreshold: 5.0,
        format: (v) => v.round().toString(),
        yTitle: 'Deals',
        wholeNumbers: true,
        lineColor: BrokaColors.neonGreen,
      ),
      FactorTrendChart(
        label: 'Pending deals',
        points: _series('pending_deals'),
        currentValue: _live('pending_deals'),
        // A growing backlog is bad, so lower is better.
        higherIsBetter: false,
        goodThreshold: 3.0, poorThreshold: 10.0,
        format: (v) => v.round().toString(),
        yTitle: 'Deals',
        wholeNumbers: true,
        lineColor: BrokaColors.gold,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _secLabel('PERFORMANCE OVER TIME'),
        const SizedBox(height: 4),
        const Text('Each graph: the date along the bottom, the value up the side · green is healthy, red needs work',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 10)),
        const SizedBox(height: 12),
        for (int i = 0; i < charts.length; i++) ...[
          FadeSlideIn(index: i, child: charts[i]),
          const SizedBox(height: 10),
        ],
      ]),
    );
  }

  // ── Advice panel ──────────────────────────────────────────────────────────

  /// "Working for you" / "Working against you".
  ///
  /// Server-computed from snapshot deltas, deliberately not a model call -
  /// Zeno cannot see a trend and would phrase a guess about one fluently,
  /// which is worse than phrasing it badly. Every card cites a number the
  /// seller can check.
  Widget _buildAdvicePanel() {
    final advice = _metrics?['advice'] as Map<String, dynamic>?;
    if (advice == null) return const SizedBox.shrink();
    final pos = (advice['positives'] as List?) ?? const [];
    final neg = (advice['negatives'] as List?) ?? const [];
    final recs = (advice['recommendations'] as List?) ?? const [];
    if (pos.isEmpty && neg.isEmpty && recs.isEmpty) {
      return const SizedBox.shrink();
    }

    Widget card(Map c, bool positive) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (positive ? BrokaColors.neonGreen : BrokaColors.danger)
            .withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(
            color: positive ? BrokaColors.neonGreen : BrokaColors.danger,
            width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(positive
                  ? Icons.trending_up_rounded
                  : Icons.error_outline_rounded,
              size: 14,
              color: positive ? BrokaColors.neonGreen : BrokaColors.danger),
          const SizedBox(width: 6),
          Expanded(child: Text(c['title'] as String? ?? '',
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontSize: 12.5, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 5),
        Text(c['detail'] as String? ?? '',
            style: const TextStyle(color: BrokaColors.textMid,
                fontSize: 11.5, height: 1.35)),
      ]),
    );

    // Recommendations: prescription, after the two diagnosis panels.
    //
    // "Working for you" and "needs attention" both say what the numbers
    // ARE. This says what to do about them, and which part of the app does
    // it - an instruction without a mechanism is a nag.
    Widget recCard(Map c) {
      final featured = c['featured'] == true;
      return PressableScale(
        onTap: () {
          HapticFeedback.selectionClick();
          final action = c['action'] as String?;
          // The explainer, not the create form. Tapping a recommendation
          // should explain the thing before asking the seller to commit to
          // it - dropping them straight into a naming form is how a free
          // feature reads as a signup wall.
          if (action == 'store') Navigator.pushNamed(context, '/store-explainer');
          if (action == 'deals') _tabs.animateTo(2);
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            // The store card is visually distinct because it is the only
            // one that is a feature rather than a correction - it should
            // not read as another thing the seller is doing wrong.
            color: featured
                ? Color.alphaBlend(
                    BrokaColors.gold.withOpacity(0.10), BrokaColors.bgCard)
                : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: featured
                ? BrokaColors.gold.withOpacity(0.40)
                : BrokaColors.neonBlue.withOpacity(0.22)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(featured ? Icons.storefront_rounded : Icons.tips_and_updates_rounded,
                  size: 15,
                  color: featured ? BrokaColors.gold : BrokaColors.neonBlue),
              const SizedBox(width: 7),
              Expanded(child: Text(c['title'] as String? ?? '',
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontSize: 12.5, fontWeight: FontWeight.w700))),
              if (featured)
                const Icon(Icons.arrow_forward_rounded,
                    size: 14, color: BrokaColors.gold),
            ]),
            const SizedBox(height: 5),
            Text(c['detail'] as String? ?? '',
                style: const TextStyle(color: BrokaColors.textMid,
                    fontSize: 11.5, height: 1.4)),
            // Explicit button on the featured card. An arrow in the corner
            // is a hint; a labelled control is an invitation, and this is
            // the one card meant to be acted on rather than absorbed.
            if (c['cta'] != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(c['cta'] as String,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 11.5, fontWeight: FontWeight.w800)),
                  const SizedBox(width: 5),
                  const Icon(Icons.arrow_forward_rounded,
                      size: 13, color: Colors.white),
                ]),
              ),
            ],
          ]),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (pos.isNotEmpty) ...[
          _secLabel('WORKING FOR YOU'),
          const SizedBox(height: 10),
          for (final c in pos) card(c as Map, true),
        ],
        if (neg.isNotEmpty) ...[
          const SizedBox(height: 10),
          _secLabel('NEEDS YOUR ATTENTION'),
          const SizedBox(height: 10),
          for (final c in neg) card(c as Map, false),
        ],
        if (recs.isNotEmpty) ...[
          const SizedBox(height: 10),
          _secLabel('RECOMMENDED NEXT'),
          const SizedBox(height: 10),
          for (final c in recs) recCard(c as Map),
        ],
      ]),
    );
  }

  // ── Pipeline counts ──────────────────────────────────────────────────────────
  //
  // Every stage is counted over the SAME population: the listings loaded on
  // this screen. `_pipeDone` used to read `_completedDeals` from the
  // profile - an all-time, account-wide figure - while the stages beside it
  // counted current listings. A seller with a long history and few live
  // listings got a funnel where COMPLETE exceeded LISTED, and percentages
  // over 100%.
  //
  // `_statusKnown` exists because the other stages can only see listings
  // whose deal status has actually been fetched. Before the Deals tab is
  // opened that is 5 of them, so NEGOTIATING and PAYMENT read low and there
  // was nothing on screen to say the number was provisional.
  int get _pipeListed => _listings.length;
  int get _statusKnown => _listings.where((l) => _dealStatusMap.containsKey(l.id)).length;
  bool get _pipeIsPartial => _statusKnown < _listings.length;
  int get _pipeNeg    => _listings.where((l) {
    final raw = ((_dealStatusMap[l.id]?['deal_status'] ?? _dealStatusMap[l.id]?['status'] ?? '') as Object)
        .toString().toLowerCase();
    return raw.contains('pending') && !raw.contains('funded') && !raw.contains('escrow');
  }).length;
  int get _pipeEscrow => _listings.where((l) {
    final raw = ((_dealStatusMap[l.id]?['deal_status'] ?? _dealStatusMap[l.id]?['status'] ?? '') as Object)
        .toString().toLowerCase();
    return raw.contains('funded') || raw.contains('escrow') || raw.contains('pending_delivery');
  }).length;
  int get _pipeDone   => _listings.where((l) {
    final ls = l.status.toLowerCase();
    if (ls == 'sold' || ls == 'completed') return true;
    final raw = ((_dealStatusMap[l.id]?['deal_status'] ??
                  _dealStatusMap[l.id]?['status'] ?? '') as Object)
        .toString().toLowerCase();
    return raw.contains('completed') || raw.contains('released');
  }).length;

  // ── Revenue chart data (real, from completed deals) ──────────────────────────
  List<double>? _revenueWeekReal;
  List<double>? _revenueMonthReal;
  bool _revenueHasRealData = false;
  bool _revenueLoading = true;

  List<double> get _revenueData {
    final real = _revenueWeekMode ? _revenueWeekReal : _revenueMonthReal;
    if (real != null) return real;
    return List.filled(_revenueWeekMode ? 7 : 6, 0.0);
  }

  Future<void> _loadRevenue() async {
    final uid = ApiService.currentUserId;
    if (uid == null) { if (mounted) setState(() => _revenueLoading = false); return; }
    if (mounted) setState(() => _revenueLoading = true);
    try {
      final week = await ApiService.getSellerRevenue(uid, period: 'week');
      final month = await ApiService.getSellerRevenue(uid, period: 'month');
      if (!mounted) return;
      setState(() {
        _revenueWeekReal  = (week['values'] as List).map((v) => (v as num).toDouble()).toList();
        _revenueMonthReal = (month['values'] as List).map((v) => (v as num).toDouble()).toList();
        _revenueHasRealData =
            (week['has_real_data'] as bool? ?? false) || (month['has_real_data'] as bool? ?? false);
        _revenueLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _revenueLoading = false);
    }
  }

  // ── Deal helpers ─────────────────────────────────────────────────────────────
  String   _dealLabel(Listing l) {
    final ls  = l.status.toLowerCase();
    if (ls == 'sold' || ls == 'completed') return 'Complete';
    final raw = (((_dealStatusMap[l.id]?['deal_status'] ??
                   _dealStatusMap[l.id]?['status']) ?? '') as Object).toString().toLowerCase();
    if (raw.contains('funded') || raw.contains('escrow') || raw.contains('pending_delivery')) {
      return 'In Escrow';
    }
    if (raw.contains('pending'))   return 'Pending';
    if (raw.contains('completed')) return 'Complete';
    if (ls == 'pending')           return 'Pending';
    return 'Active';
  }
  Color    _dealColour(String s) => switch (s) {
    'Complete'  => BrokaColors.neonGreen,
    'In Escrow' => BrokaColors.neonBlue,
    'Pending'   => BrokaColors.warning,
    _           => BrokaColors.gold,
  };
  IconData _dealIcon(String s) => switch (s) {
    'Complete'  => Icons.check_circle_rounded,
    'In Escrow' => Icons.lock_rounded,
    'Pending'   => Icons.hourglass_bottom_rounded,
    _           => Icons.store_rounded,
  };

  // ── Utility ──────────────────────────────────────────────────────────────────
  String _fmt(int n)      => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}K' : '$n';
  String _kes(double v)   => 'KES ${v.toStringAsFixed(2)}';
  String _timeAgo(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inDays > 30) return '${diff.inDays ~/ 30}mo ago';
    if (diff.inDays >  0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    return 'just now';
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ROOT BUILD
  // ════════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    // The constellation Home and every screen reached from it sit on. The
    // cards below are opaque, so the field shows in the gaps between
    // sections rather than competing with the numbers and trend lines.
    body: ConstellationBackground(
      animate: widget.animateBackground,
      child: DecoratedBox(
        // The dashboard's gold, washing down from the top the way a
        // category's colour does in its Zone.
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
            _buildTabSwitcher(),
            Expanded(
              child: _loading
                  ? _buildLoadingShimmer()
                  : TabBarView(
                      controller: _tabs,
                      children: [_buildOverviewTab(), _buildProductsTab(), _buildDealsTab()],
                    ),
            ),
          ]),
        ),
      ),
    ),
  );

  static const _dashGradient = [BrokaColors.gold, BrokaColors.neonBlue];

  /// The header every screen reached from Home wears (CollapsingScreenHeader's
  /// layout, fixed here because the three tabs each own their scroll view).
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
              _dashGradient.first.withOpacity(0.28),
              _dashGradient.last.withOpacity(0.14),
            ]),
            border: Border.all(color: _dashGradient.first.withOpacity(0.5)),
          ),
          child: const Icon(Icons.insights_rounded, size: 18, color: BrokaColors.textHigh),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ZoneGlowText(
            'Seller Dashboard',
            gradient: _dashGradient,
            fontSize: narrow ? 17 : 19,
            maxLines: 1,
            letterSpacing: narrow ? 0.8 : 1.1,
          ),
        ),
        const SizedBox(width: 8),
        BrokaHeaderButton(
          key: const Key('dashboard-my-store'),
          icon: Icons.storefront_rounded,
          // My Store, or for a seller without a store the introduction to
          // one (StoreEntry decides).
          onTap: () => StoreEntry.open(context),
          tooltip: 'My Store',
        ),
        const SizedBox(width: 8),
        BrokaHeaderButton(icon: Icons.refresh_rounded, onTap: _load, tooltip: 'Refresh'),
      ]),
    );
  }

  /// Overview / Products / Deals as a pill switcher in Home's chip language:
  /// the dark card surface, and the selected tab in the brand gradient.
  Widget _buildTabSwitcher() {
    const labels = ['Overview', 'Products', 'Deals'];
    final position = _tabs.animation?.value ?? _tabs.index.toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Container(
        height: 44,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.86),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: BrokaColors.border),
        ),
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth / labels.length;
          return Stack(children: [
            // The selected pill slides with a swipe between tabs as well as
            // on a tap, because it follows the TabController's animation.
            Positioned(
              left: position * w,
              top: 0,
              bottom: 0,
              width: w,
              child: Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.25), blurRadius: 10),
                  ],
                ),
              ),
            ),
            Row(children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: _tabs.index == i,
                    child: GestureDetector(
                      key: Key('dashboard-tab-$i'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _tabs.animateTo(i),
                      child: Center(
                        child: Text(labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: (position - i).abs() < 0.5
                                  ? Colors.white
                                  : BrokaColors.textMid,
                              fontSize: 13,
                              fontWeight: (position - i).abs() < 0.5
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            )),
                      ),
                    ),
                  ),
                ),
            ]),
          ]);
        }),
      ),
    );
  }

  /// Skeleton in the shape of the real Overview tab.
  ///
  /// Was a centred spinner (despite the name). A spinner says "something is
  /// happening somewhere" and leaves the screen empty, so when content
  /// lands the whole layout appears at once and jumps. Blocking out the
  /// actual sections means the page is already the right shape before the
  /// data arrives - the wait reads shorter and nothing moves when it ends.
  Widget _buildLoadingShimmer() => const SingleChildScrollView(
    physics: NeverScrollableScrollPhysics(),
    padding: EdgeInsets.fromLTRB(16, 20, 16, 56),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ShimmerBox(height: 132, radius: BorderRadius.all(Radius.circular(18))),  // command header
      SizedBox(height: 14),
      Row(children: [
        Expanded(child: ShimmerBox(height: 108)),
        SizedBox(width: 10),
        Expanded(child: ShimmerBox(height: 108)),
      ]),                                                                       // radial stats
      SizedBox(height: 14),
      ShimmerBox(height: 180, radius: BorderRadius.all(Radius.circular(16))),   // revenue chart
      SizedBox(height: 14),
      ShimmerBox(height: 96,  radius: BorderRadius.all(Radius.circular(16))),   // pipeline
      SizedBox(height: 14),
      ShimmerBox(height: 140, radius: BorderRadius.all(Radius.circular(16))),   // Zeno insight
    ]),
  );

  // ════════════════════════════════════════════════════════════════════════════
  // TAB 0 — OVERVIEW
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildOverviewTab() {
    // Sections cascade in rather than appearing as one block.
    //
    // Eleven stacked cards arriving simultaneously gives the eye no order to
    // read them in; a 45ms cascade makes the hierarchy legible without
    // anyone waiting for it - the stagger caps at 8, so the tail of the page
    // is never held back behind an animation the user has not scrolled to.
    final sections = <Widget>[
      // First: a listing buyers can't see is the one thing here that is
      // costing the seller sales right now.
      AwaitingPaymentPanel(reloadSignal: _feeReload),
      _buildCommandHeader(),
      _buildStoreSection(),
      _buildRadialStatCards(),
      _buildRevenueChart(),
      _buildDealPipeline(),
      _buildAdvicePanel(),
      _buildTrendSection(),
      _buildZenoInsightCards(),
      _buildRadarSection(),
      _buildRevenueCalculator(),
      // Removed: "Get Verified Badge" and "Feature a Listing".
      //
      // Both sold position. That is incompatible with the rest of this
      // screen: there is no reason to work on completion rate or reply
      // speed if a listing can be pinned to the top of the feed for KES 99,
      // and no reason to earn trust if a badge can be bought. Rank is
      // computed from DCR, response time and credibility - all earned,
      // none purchasable - and a paid bypass would make every number above
      // decorative.
      _buildHowItWorksButton(),
      _buildReceiptsButton(),
    ];

    // Overview was the only tab without pull-to-refresh - Products and Deals
    // both had one, so the gesture worked on two tabs out of three and did
    // nothing on the one carrying the numbers most worth re-checking.
    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 56),
        child: Column(children: [
          for (int i = 0; i < sections.length; i++)
            FadeSlideIn(index: i, child: sections[i]),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  // ── Online store ─────────────────────────────────────────────────────────────

  /// The seller's online store, the same card the Menu shows: open or
  /// paused, the link, products and the week's visits, with Manage (My
  /// Store), Preview and Share. Without a store, the way to open one - for
  /// a seller who isn't set up as a business yet, that starts with the
  /// business details. Keyed on the refresh counter, so pulling to refresh
  /// the dashboard refreshes the store too.
  Widget _buildStoreSection() {
    final profile = _profile;
    final bool? businessReady = profile == null
        ? null
        : profile['account_type'] == 'buyer_seller' && profile['seller_tier'] == 'long_term';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _secLabel('YOUR ONLINE STORE'),
        const SizedBox(height: 10),
        MenuStoreSection(
          key: ValueKey('dashboard-store-$_feeReload'),
          businessReady: businessReady,
        ),
      ]),
    );
  }

  // ── Command header ────────────────────────────────────────────────────────────
  Widget _buildCommandHeader() => AnimatedBuilder(
    animation: _glow,
    builder: (_, __) => Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        // Stops composited over bg rather than left translucent.
        //
        // BoxDecoration asserts color == null || gradient == null, so an
        // opaque base cannot simply be added underneath - the tint has to
        // be flattened into the stops themselves. alphaBlend does that:
        // the card keeps its exact previous appearance against a plain
        // background while becoming fully opaque against the constellation.
        //
        // It matters because these two stops were translucent, so with the
        // ambient field behind the dashboard the stars drifted through the
        // middle of the header and the seller's name sat on top of them.
        // The field belongs in the gaps between sections, not inside them.
        gradient: LinearGradient(colors: [
          Color.alphaBlend(BrokaColors.gold.withOpacity(0.13), BrokaColors.bg),
          Color.alphaBlend(BrokaColors.neonBlue.withOpacity(0.07), BrokaColors.bg),
          BrokaColors.bg,
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: BrokaColors.gold.withOpacity(0.25 + 0.08 * _glow.value), width: 1.5),
        boxShadow: [BoxShadow(
            color: BrokaColors.gold.withOpacity(0.06 + 0.04 * _glow.value),
            blurRadius: 28, spreadRadius: 2)]),
      child: Column(children: [
        Row(children: [
          Container(width: 52, height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              boxShadow: [BoxShadow(
                  color: BrokaColors.gold.withOpacity(0.30 + 0.18 * _glow.value),
                  blurRadius: 18 + 10 * _glow.value)]),
            child: const Icon(Icons.insights_rounded, color: Colors.white, size: 26)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ApiService.currentUserName ?? 'Your Store',
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 5),
            Row(children: [
              if (_isVerified) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: BrokaColors.neonGreen.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.35))),
                  child: const Row(children: [
                    Icon(Icons.verified_rounded, color: BrokaColors.neonGreen, size: 11),
                    SizedBox(width: 4),
                    Text('VERIFIED', style: TextStyle(
                        color: BrokaColors.neonGreen, fontSize: 9,
                        fontWeight: FontWeight.w800, letterSpacing: 1)),
                  ])),
                const SizedBox(width: 8),
              ],
              const Text('BROKA SELLER',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 10, letterSpacing: 1.4)),
            ]),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${_listings.length}', style: const TextStyle(
                color: BrokaColors.gold, fontSize: 34, fontWeight: FontWeight.w900,
                height: 1.0, fontFamily: 'monospace')),
            const Text('PRODUCTS', style: TextStyle(
                color: BrokaColors.textMid, fontSize: 8, letterSpacing: 1.6)),
          ]),
        ]),
        const SizedBox(height: 18),
        Container(height: 1, color: BrokaColors.border),
        const SizedBox(height: 14),
        Row(children: [
          _miniStat(_fmt(_totalViews),          'Total Views', BrokaColors.neonBlue),
          _vDivider(),
          _miniStat('$_completedDeals',         'Deals Done',  BrokaColors.neonGreen),
          _vDivider(),
          _miniStat(
              _dealTimeMinutes == null ? '—' : SellerStanding.formatMinutes(_dealTimeMinutes!),
              'Avg Deal Time', BrokaColors.gold),
          _vDivider(),
          _miniStat('$_featuredCount',          'Featured',    BrokaColors.neonCyan),
        ]),
        if (_dcrScore != null) ...[
          const SizedBox(height: 14),
          Container(height: 1, color: BrokaColors.border),
          const SizedBox(height: 14),
          _buildDcrRow(),
        ],
      ]),
    ),
  );

  // Volume 2 §3.6: "framed the way ... every metric ... - as something that
  // explains itself, not a mysterious score." Copy here is a simple static
  // high/low split, not the fully Zeno-narrated, position-aware version the
  // doc's own example shows ("move you from position #14 to the top 5") -
  // that needs a live per-category rank position this pass doesn't compute,
  // and the doc explicitly defers exact tone/language to Chapter 5.
  double? get _dcrScore  => (_profile?['dcr_score'] as num?)?.toDouble();
  bool    get _dcrIsGood => (_dcrScore ?? 0) >= 70;

  /// Is the completion rate MEASURED, or is it still the prior?
  ///
  /// §3.2 smooths DCR toward a prior of 0.80 so a seller with two deals
  /// cannot show 100%. The side effect: a seller with ZERO deals shows 80%
  /// - and the dashboard presented that as "You complete 80% of your deals
  /// through BROKA — a strong track record buyers can see", to someone who
  /// has never completed a deal. The prior is a sensible starting estimate;
  /// it is not a track record, and calling it one is the same class of
  /// fabrication as the 85% response rate.
  ///
  /// Part XVI puts the eligibility bar at 10 completed transactions. One is
  /// used here as the bar for SHOWING a number at all, with anything under
  /// ten marked provisional - between those two points the figure is real
  /// but thin, and saying so is better than either hiding it or
  /// overselling it.
  bool get _dcrIsMeasured => _completedDeals > 0 && _dcrScore != null;
  bool get _dcrIsProvisional => _completedDeals > 0 && _completedDeals < 10;

  Widget _buildDcrRow() {
    // Nothing completed yet: say what is actually true, and what moves it.
    if (!_dcrIsMeasured) {
      return const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.trending_up, size: 18, color: BrokaColors.gold),
        SizedBox(width: 8),
        Expanded(child: Text(
          'Your completion rate starts once you close your first deal through '
          'BROKA. It is the biggest single factor in how your listings rank.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4),
        )),
      ]);
    }
    return _buildMeasuredDcrRow();
  }

  Widget _buildMeasuredDcrRow() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(_dcrIsGood ? Icons.verified_outlined : Icons.trending_up,
          size: 18, color: _dcrIsGood ? BrokaColors.neonGreen : BrokaColors.gold),
      const SizedBox(width: 8),
      Expanded(
        child: RichText(
          text: TextSpan(
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4),
            children: [
              const TextSpan(text: 'You complete '),
              TextSpan(
                text: '${_dcrScore!.toStringAsFixed(0)}%',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: _dcrIsGood ? BrokaColors.neonGreen : BrokaColors.gold,
                ),
              ),
              TextSpan(
                text: _dcrIsGood
                    ? ' of your deals through BROKA — a strong track record buyers can see.'
                    : ' of your deals through BROKA. Completing more deals on-platform helps your listings rank higher in search.',
              ),
              // Thin evidence gets labelled as thin. Under ten completed
              // deals the smoothing still dominates the figure, so it moves
              // a lot with each new deal - a seller should know that before
              // reading it as settled.
              if (_dcrIsProvisional)
                const TextSpan(
                  text: ' Still early — this will move a lot over your next '
                        'few deals.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _miniStat(String v, String l, Color c) => Expanded(child: Column(children: [
    _CountUpText(value: v, style: TextStyle(
        color: c, fontSize: 15, fontWeight: FontWeight.w800)),
    const SizedBox(height: 2),
    // textLow (#2E3D5A) is 1.88:1 on this background - the same failure
    // found in the message receipts. A label nobody can read is not a
    // label. textMid measures 7.33:1.
    Text(l, style: const TextStyle(
        color: BrokaColors.textMid, fontSize: 8.5, letterSpacing: 0.8,
        fontWeight: FontWeight.w600)),
  ]));

  Widget _vDivider() => Container(width: 1, height: 28, color: BrokaColors.border);

  // ── Radial Gauge Stat Cards ───────────────────────────────────────────────────
  Widget _buildRadialStatCards() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _secLabel('LIVE METRICS'),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _radialCard(
          label: 'TOTAL VIEWS', value: _fmt(_totalViews),
          progress: (_totalViews / math.max(_totalViews, 1000)).clamp(0.0, 1.0),
          // Was a hardcoded "+12% vs last week" shown to every seller,
          // including one with a single view and no history at all. Nothing
          // computes a week-over-week delta; the snapshot table will support
          // one once it has two weeks in it. Until then the sub-label states
          // the count, which is a fact.
          color: BrokaColors.neonCyan,
          sub: _totalViews == 1 ? '1 view so far' : '${_fmt(_totalViews)} so far',
          up: _totalViews > 0)),
        const SizedBox(width: 10),
        Expanded(child: _radialCard(
          label: 'DEALS DONE', value: '$_completedDeals',
          progress: (_completedDeals / math.max(_completedDeals + 4, 20)).clamp(0.0, 1.0),
          color: BrokaColors.neonGreen, sub: '$_activeCount active', up: true)),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _radialCard(
          label: 'FEATURED', value: '$_featuredCount',
          progress: _listings.isEmpty
              ? 0.0 : (_featuredCount / _listings.length).clamp(0.0, 1.0),
          color: BrokaColors.gold,
          sub: 'of ${_listings.length} products', up: _featuredCount > 0)),
        const SizedBox(width: 10),
        // Deal completion rate in the slot response rate used to occupy.
        // It is a real, computed figure (domains/trust/completion_rate.py)
        // and it is the one the platform actually ranks on, so it is worth
        // the space that a hardcoded 85% was taking.
        Expanded(child: !_dcrIsMeasured
            ? _radialCard(
                label: 'COMPLETION', value: '—',
                progress: 0.0, color: BrokaColors.textMid,
                sub: 'after first deal', up: false)
            : _radialCard(
                label: 'COMPLETION', value: '${_dcrScore!.toInt()}%',
                progress: (_dcrScore! / 100).clamp(0.0, 1.0),
                color: BrokaColors.neonBlue,
                sub: _dcrIsProvisional ? 'provisional' : 'deals completed',
                up: _dcrScore! >= 70)),
      ]),
    ]),
  );

  Widget _radialCard({
    required String label, required String value, required double progress,
    required Color color, required String sub, required bool up,
  }) => AnimatedBuilder(
    animation: _glow,
    builder: (_, __) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.20 + 0.08 * _glow.value)),
        boxShadow: [BoxShadow(
            color: color.withOpacity(0.04 + 0.03 * _glow.value), blurRadius: 18)]),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 8,
              fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          const SizedBox(height: 6),
          // Shrinks rather than overflows: beside the 56px gauge, half a
          // 320dp screen leaves about 50px for a figure like "12,480".
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: TextStyle(
                color: color, fontSize: 24, fontWeight: FontWeight.w900,
                fontFamily: 'monospace', height: 1.0)),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                size: 10, color: up ? BrokaColors.neonGreen : BrokaColors.danger),
            const SizedBox(width: 3),
            Flexible(
              child: Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 9)),
            ),
          ]),
        ])),
        SizedBox(width: 56, height: 56, child: CustomPaint(
          painter: _RadialGaugePainter(
              progress: progress, color: color, glowT: _glow.value),
          child: Center(child: Text('${(progress * 100).toInt()}%',
              style: TextStyle(
                  color: color, fontSize: 10, fontWeight: FontWeight.w800))),
        )),
      ]),
    ),
  );

  // ── Revenue Overview Chart ────────────────────────────────────────────────────

  /// The date each revenue bucket starts on, oldest first, matching the
  /// server's buckets (ListingService.get_seller_revenue): the last 7 days
  /// ending today, or the last 6 weeks ending today.
  ///
  /// The x-axis used to read Mon..Sun, but the buckets are the last seven
  /// days, not a calendar week - so on a Wednesday the point labelled
  /// "Mon" was last Thursday.
  List<DateTime> _revenueBucketStarts() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final n = _revenueData.length;
    return _revenueWeekMode
        ? [for (var i = 0; i < n; i++) today.subtract(Duration(days: n - 1 - i))]
        : [for (var i = 0; i < n; i++) today.subtract(Duration(days: (n - 1 - i) * 7 + 6))];
  }

  static String _kesAxis(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(v % 1000000 == 0 ? 0 : 1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)}K';
    return v.toStringAsFixed(0);
  }

  Widget _buildRevenueChart() {
    final data      = _revenueData;
    final maxV      = data.reduce(math.max);
    final minV      = data.reduce(math.min);
    final avgV      = data.reduce((a, b) => a + b) / data.length;
    final maxIdx    = data.indexOf(maxV);
    final minIdx    = data.indexOf(minV);
    final starts    = _revenueBucketStarts();
    final labels    = [for (final d in starts) shortDate(d)];
    final showEmpty = !_revenueLoading && !_revenueHasRealData;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 20, 18, 20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.18)),
          boxShadow: [BoxShadow(
              color: BrokaColors.neonCyan.withOpacity(0.04), blurRadius: 20)]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const SizedBox(width: 6),
            const Expanded(child: Text('REVENUE OVERVIEW', style: TextStyle(
                color: BrokaColors.textHigh, fontSize: 12,
                fontWeight: FontWeight.w800, letterSpacing: 1.0))),
            if (_revenueLoading)
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(
                  strokeWidth: 1.6, color: BrokaColors.neonCyan))
            else
              Container(
                decoration: BoxDecoration(
                    color: BrokaColors.bg, borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: BrokaColors.border)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _toggleBtn('WEEK',  _revenueWeekMode,  () => setState(() => _revenueWeekMode = true)),
                  _toggleBtn('MONTH', !_revenueWeekMode, () => setState(() => _revenueWeekMode = false)),
                ]),
              ),
          ]),
          const SizedBox(height: 18),
          SizedBox(height: 190, child: Stack(alignment: Alignment.center, children: [
            AxisLineChart(
              key: const Key('revenue-chart'),
              values: data,
              positions: [for (var i = 0; i < data.length; i++) i / (data.length - 1)],
              xTicks: [for (var i = 0; i < labels.length; i++) AxisTick(i / (labels.length - 1), labels[i])],
              yFormat: _kesAxis,
              xTitle: _revenueWeekMode ? 'Day' : 'Week starting',
              yTitle: 'Revenue (KES)',
              lineColor: BrokaColors.neonCyan,
              // Revenue starts at zero: a quiet week drawn at the bottom,
              // not stretched to fill the chart.
              yFloor: 0,
              minStep: 1,
            ),
            if (showEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: BrokaColors.bg.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: BrokaColors.border),
                ),
                child: const Text('No completed sales yet — this fills in once a deal is released.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 10)),
              ),
          ])),
          const SizedBox(height: 16),
          Container(height: 1, color: BrokaColors.border),
          const SizedBox(height: 14),
          Row(children: [
            _revStat(Icons.arrow_circle_up_rounded, 'HIGHEST',
                'KES ${maxV.toStringAsFixed(0)}', BrokaColors.neonGreen, labels[maxIdx]),
            _revDivider(),
            _revStat(Icons.arrow_circle_down_rounded, 'LOWEST',
                'KES ${minV.toStringAsFixed(0)}', BrokaColors.danger, labels[minIdx]),
            _revDivider(),
            _revStat(Icons.bar_chart_rounded, 'AVERAGE',
                'KES ${avgV.toStringAsFixed(0)}', BrokaColors.gold,
                _revenueWeekMode ? 'Per day' : 'Per week'),
          ]),
        ]),
      ),
    );
  }

  Widget _toggleBtn(String label, bool active, VoidCallback onTap) => PressableScale(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: active ? BrokaColors.gold.withOpacity(0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        border: active ? Border.all(color: BrokaColors.gold.withOpacity(0.35)) : null),
      child: Text(label, style: TextStyle(
          color: active ? BrokaColors.gold : BrokaColors.textMid,
          fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.8))));

  Widget _revStat(IconData ic, String lbl, String val, Color c, String sub) =>
      Expanded(child: Column(children: [
        Icon(ic, color: c, size: 16),
        const SizedBox(height: 4),
        Text(lbl, style: const TextStyle(
            color: BrokaColors.textMid, fontSize: 7, letterSpacing: 0.8)),
        const SizedBox(height: 2),
        Text(val, style: TextStyle(
            color: c, fontSize: 11, fontWeight: FontWeight.w800)),
        const SizedBox(height: 1),
        Text(sub, style: const TextStyle(color: BrokaColors.textMid, fontSize: 8)),
      ]));

  Widget _revDivider() => Container(width: 1, height: 44, color: BrokaColors.border);

  Widget _viewsStat(String lbl, String val, Color c) =>
      Expanded(child: Column(children: [
        Text(lbl, style: const TextStyle(
            color: BrokaColors.textMid, fontSize: 7, letterSpacing: 0.8)),
        const SizedBox(height: 4),
        Text(val, style: TextStyle(
            color: c, fontSize: 13, fontWeight: FontWeight.w800)),
      ]));

  // ── Deal Pipeline ─────────────────────────────────────────────────────────────
  Widget _buildDealPipeline() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _secLabel('DEAL PIPELINE'),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.border)),
        // Drifts horizontally, like the insights rail.
        //
        // Four stages plus arrows do not fit a phone without squeezing each
        // one to about 70px, which is where the counts stop being readable.
        // Letting it scroll gives each stage room, and the drift makes the
        // later stages discoverable without the seller having to guess that
        // the row moves at all.
        child: SizedBox(
          // Grows with the user's text size, which the stage labels do.
          height: 118 * MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.35),
          child: _AutoScrollRail(
            itemCount: 1,
            itemWidth: 520,
            // One wide item rather than four narrow ones: the arrows only
            // mean anything between adjacent stages, so the row has to stay
            // a single unit that slides, not four cards that reflow.
            builder: (_, __) => SizedBox(width: 520, child: Row(children: [
          _pipeStage(Icons.format_list_bulleted_rounded, _pipeListed, 'LISTED',
              BrokaColors.neonBlue, '100%'),
          _pipeArrow(),
          _pipeStage(Icons.handshake_rounded, _pipeNeg, 'NEGOTIATING',
              BrokaColors.warning,
              _pipeListed > 0 ? '${(_pipeNeg / _pipeListed * 100).round()}%' : '0%'),
          _pipeArrow(),
          _pipeStage(Icons.payment_rounded, _pipeEscrow, 'PAYMENT',
              BrokaColors.gold,
              _pipeListed > 0 ? '${(_pipeEscrow / _pipeListed * 100).round()}%' : '0%'),
          _pipeArrow(),
          _pipeStage(Icons.check_circle_rounded, _pipeDone, 'COMPLETE',
              BrokaColors.neonGreen,
              _pipeListed > 0 ? '${(_pipeDone / _pipeListed * 100).round()}%' : '0%'),
            ])),
          ),
        ),
      ),
      // Say so when the funnel is still filling in, instead of letting
      // provisional numbers read as final ones.
      if (_pipeIsPartial) ...[
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.info_outline_rounded,
              size: 11, color: BrokaColors.textMid),
          const SizedBox(width: 5),
          Text('Checked $_statusKnown of $_pipeListed · open Deals for the rest',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
        ]),
      ],
    ]),
  );

  Widget _pipeStage(IconData ic, int cnt, String lbl, Color c, String pct) =>
      Expanded(child: AnimatedBuilder(
        animation: _glow,
        builder: (_, __) => Column(children: [
          Container(width: 44, height: 44,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: c.withOpacity(0.11),
              border: Border.all(
                  color: c.withOpacity(0.40 + 0.18 * _glow.value), width: 1.5),
              boxShadow: [BoxShadow(
                  color: c.withOpacity(0.10 + 0.08 * _glow.value), blurRadius: 12)]),
            child: Icon(ic, color: c, size: 20)),
          const SizedBox(height: 8),
          Text('$cnt', style: TextStyle(
              color: c, fontSize: 20, fontWeight: FontWeight.w900,
              fontFamily: 'monospace', height: 1.0)),
          const SizedBox(height: 3),
          // One line, scaled to fit: the pipeline row is a fixed 118px, and
          // "NEGOTIATING" wrapping to two lines on a small phone overflowed it.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(lbl, maxLines: 1, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 7,
                fontWeight: FontWeight.w700, letterSpacing: 0.8),
              textAlign: TextAlign.center),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.withOpacity(0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.withOpacity(0.22))),
            child: Text(pct, style: TextStyle(
                color: c, fontSize: 8, fontWeight: FontWeight.w700))),
        ]),
      ));

  Widget _pipeArrow() => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      ...List.generate(3, (i) => AnimatedBuilder(
        animation: _pulse,
        builder: (_, __) => Container(
          width: 4, height: 1.5,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: BrokaColors.textLow.withOpacity(
                0.3 + 0.4 * ((_pulse.value + i * 0.33) % 1.0)),
            borderRadius: BorderRadius.circular(1))))),
      const Icon(Icons.chevron_right_rounded, color: BrokaColors.textLow, size: 14),
    ]),
  );

  // ── Zeno Insight Cards ────────────────────────────────────────────────────────
  // ── Zeno insights ─────────────────────────────────────────────────────────
  //
  // Fixed cards from data/seller_insights.dart, on a slow auto-scrolling
  // rail. No model call.
  //
  // The AI version asked Zeno for tips on every refresh and got generic
  // marketplace advice back, because it was never told the seller's
  // objectives or plans - it assumed what they needed to know and billed
  // for the assumption. These explain levers the seller controls and the
  // consequences the platform actually applies, which stays true for every
  // reader.
  Widget _buildZenoInsightCards() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            // Zeno's own face on Zeno's own section.
            const ZenoAvatar(size: 30),
            const SizedBox(width: 9),
            const Text('ZENO INSIGHTS', style: TextStyle(
                color: BrokaColors.textMid, fontSize: 11,
                letterSpacing: 1.6, fontWeight: FontWeight.w800)),
            const Spacer(),
            // Hands off to the full list the moment someone shows real
            // interest. The rail drifting is right for a glance and wrong
            // for a seller who has decided to read them - waiting for a
            // card to come round, or swiping back because one went past,
            // is a poor way to read twenty things.
            PressableScale(
              onTap: () {
                HapticFeedback.selectionClick();
                Navigator.pushNamed(context, '/zeno-insights');
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: BrokaColors.gold.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: BrokaColors.gold.withOpacity(0.32)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('See all ${kSellerInsights.length}',
                      style: const TextStyle(color: BrokaColors.gold,
                          fontSize: 10.5, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 3),
                  const Icon(Icons.arrow_forward_rounded,
                      size: 12, color: BrokaColors.gold),
                ]),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 150,
          child: _AutoScrollRail(
            itemCount: kSellerInsights.length,
            itemWidth: 268,
            builder: (ctx, i) => _insightCard(kSellerInsights[i]),
          ),
        ),
      ]),
    );
  }

  Widget _insightCard(SellerInsight t) => Container(
    width: 268,
    margin: const EdgeInsets.only(right: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
          begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: t.accent.withOpacity(0.28)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 28, height: 28,
          decoration: BoxDecoration(shape: BoxShape.circle,
              color: t.accent.withOpacity(0.14)),
          child: Icon(t.icon, size: 15, color: t.accent)),
        const SizedBox(width: 9),
        Expanded(child: Text(t.title, maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textHigh,
                fontSize: 12.5, fontWeight: FontWeight.w800, height: 1.2))),
      ]),
      const SizedBox(height: 9),
      Expanded(child: Text(t.body, maxLines: 5,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: BrokaColors.textMid,
              fontSize: 11.2, height: 1.4))),
    ]),
  );
  // ── Trust triangle ────────────────────────────────────────────────────────
  //
  // Three axes, all earned: completion rate, buyer rating, credibility.
  //
  // Replaces a four-axis chart whose "Deals" spoke was a made-up saturation
  // curve over the deal count and whose "Trust" spoke was the raw
  // trust_score - which is 0-100 on the backend and clamped to a flat 10/10
  // for every seller above 6. Three real numbers beat four where one is
  // invented and another is broken.
  //
  // Credibility is the new one: track record rather than current form, and
  // deliberately the slowest of the three to move. Completion rate and
  // rating respond to this month; credibility answers "how long have they
  // been doing this properly", which is what a buyer is really asking.
  Widget _buildRadarSection() {
    final credibility =
        ((_metrics?['current'] as Map?)?['credibility'] as num?)?.toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _secLabel('TRUST & PERFORMANCE'),
        const SizedBox(height: 4),
        const Text('Every one of these is earned — none can be bought',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 10)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
                begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: BrokaColors.border)),
          child: Column(children: [
            SizedBox(
              height: 230,
              child: AnimatedBuilder(
                // Rides the existing glow controller, so the rings breathe
                // in time with the rest of the dashboard instead of
                // introducing a second, subtly different rhythm.
                animation: _glow,
                builder: (_, __) => TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: BrokaMotion.reduced(context)
                      ? Duration.zero : const Duration(milliseconds: 1100),
                  curve: Curves.easeOutCubic,
                  builder: (_, t, ___) => CustomPaint(
                    painter: _TrustTrianglePainter(
                      // A missing score plots at 0 rather than at a
                      // flattering guess. A spoke collapsed to the centre is
                      // an honest "no data yet", and legible at a glance.
                      values: [
                        (_reliability ?? 0) / 10,
                        (_avgRating ?? 0) / 10,
                        (credibility ?? 0) / 10,
                      ],
                      labels: const ['Completion', 'Rating', 'Credibility'],
                      scores: [_reliability ?? 0, _avgRating ?? 0, credibility ?? 0],
                      progress: t,
                      pulse: _glow.value,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              HexTrustBadge(score: _reliability ?? 0, label: 'Completion'),
              HexTrustBadge(score: _avgRating ?? 0,   label: 'Rating'),
              HexTrustBadge(score: credibility ?? 0,  label: 'Credibility'),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _buildRevenueCalculator() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 34, height: 34,
            decoration: BoxDecoration(shape: BoxShape.circle,
                color: BrokaColors.neonGreen.withOpacity(0.12)),
            child: const Icon(Icons.calculate_rounded,
                color: BrokaColors.neonGreen, size: 17)),
          const SizedBox(width: 10),
          const Text('CALCULATOR', style: TextStyle(
              color: BrokaColors.textHigh, fontSize: 13,
              fontWeight: FontWeight.w800, letterSpacing: 1.1)),
        ]),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: BrokaColors.bg.withOpacity(0.55),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_calcExpression.isEmpty ? '0' : _calcExpression,
                style: const TextStyle(color: BrokaColors.textMid,
                    fontSize: 13, fontFamily: 'monospace')),
            const SizedBox(height: 4),
            Text(_calcResult,
                style: const TextStyle(color: BrokaColors.neonGreen,
                    fontSize: 26, fontWeight: FontWeight.w800,
                    fontFamily: 'monospace')),
          ]),
        ),
        const SizedBox(height: 12),
        for (final row in const [
          ['C', '%', '/', '*'],
          ['7', '8', '9', '-'],
          ['4', '5', '6', '+'],
          ['1', '2', '3', '='],
          ['0', '.', '⌫', ''],
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(children: [
              for (final key in row)
                Expanded(child: key.isEmpty
                    ? const SizedBox()
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _calcKey(key))),
            ]),
          ),
      ]),
    ),
  );

  Widget _calcKey(String k) {
    final isOp = '+-*/=%'.contains(k);
    final isClear = k == 'C' || k == '⌫';
    return PressableScale(
      onTap: () => _onCalcKey(k),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: isOp
              ? BrokaColors.neonGreen.withOpacity(0.13)
              : (isClear ? BrokaColors.danger.withOpacity(0.10)
                         : BrokaColors.bg.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: isOp
              ? BrokaColors.neonGreen.withOpacity(0.3) : BrokaColors.border),
        ),
        alignment: Alignment.center,
        child: Text(k, style: TextStyle(
            color: isOp ? BrokaColors.neonGreen
                        : (isClear ? BrokaColors.danger : BrokaColors.textHigh),
            fontSize: 17, fontWeight: FontWeight.w700)),
      ),
    );
  }

  void _onCalcKey(String k) {
    HapticFeedback.selectionClick();
    setState(() {
      switch (k) {
        case 'C':
          _calcExpression = ''; _calcResult = '0';
          break;
        case '⌫':
          if (_calcExpression.isNotEmpty) {
            _calcExpression =
                _calcExpression.substring(0, _calcExpression.length - 1);
          }
          break;
        case '=':
          _calcResult = _evaluate(_calcExpression);
          break;
        default:
          _calcExpression += k;
          // Live result as you type, but never overwrite a real answer with
          // an error while the expression is mid-way through being written -
          // "35*" is incomplete, not wrong.
          final live = _evaluate(_calcExpression);
          if (live != 'Error') _calcResult = live;
      }
    });
  }

  /// Left-to-right evaluation with * and / taking precedence.
  ///
  /// Hand-rolled rather than pulling in an expression package: this handles
  /// five operators over a flat string with no parentheses, and adding a
  /// dependency for that would be more code than the parser.
  String _evaluate(String expr) {
    if (expr.trim().isEmpty) return '0';
    try {
      final tokens = <String>[];
      var number = '';
      for (final ch in expr.split('')) {
        if ('0123456789.'.contains(ch)) {
          number += ch;
        } else if (ch == '%') {
          // POSTFIX, not infix. "3500*15%" is how anyone actually asks for
          // 15% of 3500, and treating % as a binary operator made the most
          // common question a trader has - what is 15% off - return Error.
          // So % converts the number it follows into a fraction: 15% -> 0.15,
          // and 3500-3500*15% gives 2975.
          if (number.isEmpty) return 'Error';
          number = (double.parse(number) / 100).toString();
        } else if ('+-*/'.contains(ch)) {
          if (number.isEmpty) return 'Error';   // leading or doubled operator
          tokens..add(number)..add(ch);
          number = '';
        } else {
          return 'Error';
        }
      }
      if (number.isEmpty) return 'Error';       // trailing operator
      tokens.add(number);

      // Pass 1: * and / (% is handled in tokenising, above)
      final pass = <String>[];
      var i = 0;
      while (i < tokens.length) {
        final t = tokens[i];
        if (t == '*' || t == '/') {
          final a = double.parse(pass.removeLast());
          final b = double.parse(tokens[i + 1]);
          if (t == '/' && b == 0) return 'Error';
          pass.add((t == '*' ? a * b : a / b).toString());
          i += 2;
        } else {
          pass.add(t); i += 1;
        }
      }

      // Pass 2: + -
      var acc = double.parse(pass.first);
      for (var j = 1; j < pass.length; j += 2) {
        final b = double.parse(pass[j + 1]);
        acc = pass[j] == '+' ? acc + b : acc - b;
      }

      if (acc.isNaN || acc.isInfinite) return 'Error';
      // Trim a trailing .0 - a trader reading a price does not want "450.0".
      return acc == acc.roundToDouble()
          ? acc.toStringAsFixed(0)
          : acc.toStringAsFixed(2);
    } catch (_) {
      return 'Error';
    }
  }

  Widget _calcInput({
    required String label, String prefix = '', required TextEditingController controller,
    required void Function(double) onChanged,
  }) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(
        color: BrokaColors.textMid, fontSize: 8,
        letterSpacing: 1.0, fontWeight: FontWeight.w700)),
    const SizedBox(height: 6),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: BrokaColors.bg, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: BrokaColors.border)),
      child: Row(children: [
        if (prefix.isNotEmpty)
          Text(prefix, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        Expanded(child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13,
              fontWeight: FontWeight.w700, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            isDense: true, border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 8)),
          onChanged: (s) => onChanged(double.tryParse(s) ?? 0),
        )),
      ])),
  ]);

  Widget _calcSlider({
    required String label, required double value, required double min,
    required double max, required String suffix, required Color color,
    required void Function(double) onChanged,
  }) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      Text(label, style: const TextStyle(
          color: BrokaColors.textMid, fontSize: 8,
          letterSpacing: 1.0, fontWeight: FontWeight.w700)),
      const Spacer(),
      Text('${value.toStringAsFixed(1)}$suffix', style: TextStyle(
          color: color, fontSize: 11,
          fontWeight: FontWeight.w800, fontFamily: 'monospace')),
    ]),
    SliderTheme(
      data: SliderThemeData(
        trackHeight: 2.5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        activeTrackColor: color, inactiveTrackColor: BrokaColors.border,
        thumbColor: color, overlayColor: color.withOpacity(0.15)),
      child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)),
  ]);

  Widget _calcRow(String l, String v, Color c, {bool bold = false}) =>
      Row(children: [
        Expanded(child: Text(l,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11))),
        Text(v, style: TextStyle(
            color: c, fontSize: 11, fontFamily: 'monospace',
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
      ]);

  // ── Verification CTA ──────────────────────────────────────────────────────────
  // ── How BROKA works ───────────────────────────────────────────────────────
  //
  // Everything above this assumes the seller already knows what DCR is and
  // why rank matters. A number nobody understands is a number nobody acts
  // on - a seller who does not know that off-platform deals cost them
  // ranking has no reason to stop doing them, and every metric on this
  // screen is then decoration.
  Widget _buildHowItWorksButton() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: PressableScale(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.pushNamed(context, '/how-broka-works');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
              BrokaColors.neonBlue.withOpacity(0.08), BrokaColors.bgCard),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.30)),
        ),
        child: Row(children: [
          Container(width: 36, height: 36,
            decoration: BoxDecoration(shape: BoxShape.circle,
                color: BrokaColors.neonBlue.withOpacity(0.14)),
            child: const Icon(Icons.school_rounded,
                color: BrokaColors.neonBlue, size: 18)),
          const SizedBox(width: 12),
          const Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Learn how BROKA works',
                  style: TextStyle(color: BrokaColors.textHigh,
                      fontSize: 13.5, fontWeight: FontWeight.w800)),
              SizedBox(height: 2),
              Text('Escrow, your rating, your ranking — and what moves them',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 11)),
            ])),
          const Icon(Icons.arrow_forward_ios_rounded,
              size: 13, color: BrokaColors.textMid),
        ]),
      ),
    ),
  );

  // ── Receipts button ───────────────────────────────────────────────────────────
  Widget _buildReceiptsButton() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: PressableScale(
      onTap: () => Navigator.pushNamed(context, '/receipt-history'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF00B300).withOpacity(0.35))),
        child: Row(children: [
          Container(width: 40, height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF00B300).withOpacity(0.12),
              border: Border.all(color: const Color(0xFF00B300).withOpacity(0.40))),
            child: const Icon(Icons.receipt_long_outlined, color: Color(0xFF00B300), size: 20)),
          const SizedBox(width: 14),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Payment Receipts', style: TextStyle(
                color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 14)),
            SizedBox(height: 2),
            Text('Sales, listing fees and premium plans',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
          ])),
          const Icon(Icons.chevron_right_rounded, color: BrokaColors.textLow, size: 20),
        ]),
      ),
    ),
  );

  // ════════════════════════════════════════════════════════════════════════════
  // TAB 1 — PRODUCTS
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildProductsTab() {
    if (_listings.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 72, height: 72,
          decoration: BoxDecoration(shape: BoxShape.circle, color: BrokaColors.bgCard,
              border: Border.all(color: BrokaColors.gold.withOpacity(0.25))),
          child: const Icon(Icons.storefront_outlined, color: BrokaColors.textLow, size: 36)),
        const SizedBox(height: 16),
        const Text('No products yet',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 16)),
        const SizedBox(height: 8),
        const Text("Tap 'Sell' to list your first product",
            style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
        const SizedBox(height: 20),
        PressableScale(
          onTap: () => Navigator.pushNamed(context, '/sell'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.30), blurRadius: 12)]),
            child: const Text('List a Product',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)))),
      ]));
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        itemCount: _listings.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) return FadeSlideIn(index: 0, child: _buildProductsHeader());
          // index i, not i-1, so the header counts as the first beat and
          // the first card follows it rather than arriving alongside.
          return FadeSlideIn(index: i, child: _buildProductCard(_listings[i - 1]));
        }),
    );
  }

  Widget _buildProductsHeader() => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_listings.length} PRODUCT${_listings.length == 1 ? "" : "S"}',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 10,
                fontWeight: FontWeight.w700, letterSpacing: 1.4)),
        const SizedBox(height: 2),
        Text('$_activeCount active · $_featuredCount featured',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      ])),
      PressableScale(
        onTap: () => Navigator.pushNamed(context, '/sell'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.25), blurRadius: 8)]),
          child: const Text('+ List Product',
              style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)))),
    ]),
  );

  Widget _buildProductCard(Listing l) {
    final isExpanded = _expanded[l.id] ?? false;
    final label      = _dealLabel(l);
    final colour     = _dealColour(label);
    final boost      = _boostStatusMap[l.id];
    final featured   = l.isFeatured || (boost?['is_featured'] as bool? ?? false);

    return AnimatedBuilder(
      animation: _glow,
      builder: (_, child) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: featured
                ? BrokaColors.neonCyan.withOpacity(0.38 + 0.14 * _glow.value)
                : BrokaColors.border,
            width: featured ? 1.5 : 1),
          boxShadow: featured ? [BoxShadow(
              color: BrokaColors.neonCyan.withOpacity(0.06 + 0.04 * _glow.value),
              blurRadius: 20)] : null),
        child: child,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(children: [
          // ── Card header ─────────────────────────────────────────────────────
          // The most-tapped element on this tab - expanding a listing.
          // PressableScale sets HitTestBehavior.opaque itself.
          PressableScale(
            onTap: () {
              HapticFeedback.selectionClick();
              final opening = !(_expanded[l.id] ?? false);
              setState(() => _expanded[l.id] = opening);
              if (opening) {
                _loadZenoForListing(l);
                if (!_dealStatusMap.containsKey(l.id)) _loadDealStatus(l.id);
                if (!_boostStatusMap.containsKey(l.id)) _loadBoostStatus(l.id);
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Row(children: [
                Container(width: 46, height: 46,
                  decoration: BoxDecoration(
                    color: BrokaColors.gold.withOpacity(0.11),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: BrokaColors.gold.withOpacity(0.20))),
                  child: Center(child: Text(l.emoji, style: const TextStyle(fontSize: 22)))),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.name, style: const TextStyle(
                      color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 14),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 5),
                  Row(children: [
                    Text(l.category, style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 11)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: colour.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: colour.withOpacity(0.30))),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_dealIcon(label), color: colour, size: 9),
                        const SizedBox(width: 3),
                        Text(label, style: TextStyle(
                            color: colour, fontSize: 9, fontWeight: FontWeight.w800)),
                      ])),
                  ]),
                ])),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Row(children: [
                    const Icon(Icons.visibility_rounded, size: 11, color: BrokaColors.neonBlue),
                    const SizedBox(width: 3),
                    Text('${l.views}', style: const TextStyle(
                        color: BrokaColors.neonBlue, fontWeight: FontWeight.w800, fontSize: 14)),
                  ]),
                  const SizedBox(height: 5),
                  if (featured)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: BrokaColors.neonCyan.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.40))),
                      child: const Text('FEATURED', style: TextStyle(
                          color: BrokaColors.neonCyan, fontSize: 8,
                          fontWeight: FontWeight.w800, letterSpacing: 0.8))),
                  const SizedBox(height: 4),
                  Icon(isExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                      color: BrokaColors.textLow, size: 20),
                ]),
              ]),
            ),
          ),
          // ── Price + age row ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Row(children: [
              const Icon(Icons.sell_rounded, size: 11, color: BrokaColors.textLow),
              const SizedBox(width: 4),
              Text(l.formattedPrice, style: const TextStyle(
                  color: BrokaColors.gold, fontWeight: FontWeight.w700, fontSize: 12)),
              const Spacer(),
              Text(l.createdAt != null ? 'Listed ${_timeAgo(l.createdAt!)}' : 'Recently listed',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
            ]),
          ),
          // ── Per-listing insights ─────────────────────────────────────────────
          //
          // Its own labelled target rather than something buried in the
          // expanded body: this is the screen that answers "why isn't this
          // one selling", which is the question a seller opens the app with.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Row(children: [
              Expanded(
                child: PressableScale(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Navigator.pushNamed(context, '/listing-insights', arguments: l);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      color: BrokaColors.neonBlue.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.32)),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.insights_rounded,
                            size: 14, color: BrokaColors.neonBlue),
                        SizedBox(width: 6),
                        Text('View insights',
                            style: TextStyle(color: BrokaColors.neonBlue,
                                fontSize: 12, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Smaller and red, beside the thing a seller taps most: it
              // should be findable, not the obvious tap.
              Semantics(
                button: true,
                label: 'Delete ${l.name}',
                child: PressableScale(
                  key: Key('delete-listing-${l.id}'),
                  onTap: () => _deleteListing(l),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
                    decoration: BoxDecoration(
                      color: BrokaColors.danger.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: BrokaColors.danger.withOpacity(0.35)),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.delete_outline_rounded, size: 14, color: BrokaColors.danger),
                      SizedBox(width: 5),
                      Text('Delete', style: TextStyle(color: BrokaColors.danger,
                          fontSize: 12, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
          // ── Expanded analytics body ──────────────────────────────────────────
          if (isExpanded) _buildProductExpandedBody(l, label, featured),
        ]),
      ),
    );
  }

  /// Asks first, then takes the listing off BROKA. The backend refuses while
  /// a buyer's deal on it is under way, and says so - shown as it comes.
  Future<void> _deleteListing(Listing l) async {
    HapticFeedback.selectionClick();
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: BrokaColors.border)),
        title: const Text('Delete this listing?',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 17)),
        content: Text(
          '"${l.name}" will be taken off BROKA. Buyers won\'t find it in search, '
          'your store or anywhere else. This can\'t be undone.',
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it', style: TextStyle(color: BrokaColors.textMid)),
          ),
          TextButton(
            key: const Key('confirm-delete-listing'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete',
                style: TextStyle(color: BrokaColors.danger, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final result = await listingsRepository.deleteListing(l.id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    result.fold(
      onSuccess: (_) {
        setState(() {
          _listings.removeWhere((x) => x.id == l.id);
          _expanded.remove(l.id);
          _dealStatusMap.remove(l.id);
          _boostStatusMap.remove(l.id);
        });
        messenger.showSnackBar(SnackBar(
          content: Text('"${l.name}" deleted'),
          behavior: SnackBarBehavior.floating,
        ));
      },
      onFailure: (message, _) => messenger.showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: BrokaColors.danger,
      )),
    );
  }

  Widget _buildProductExpandedBody(Listing l, String dealLabel, bool isFeatured) {
    final daysSinceListed = l.createdAt != null
        ? math.max(1, DateTime.now().difference(l.createdAt!).inDays)
        : null;
    final avgPerDay = daysSinceListed != null ? l.views / daysSinceListed : null;

    return Column(children: [
      Container(height: 1, color: BrokaColors.border),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _secLabel('VIEWS', color: BrokaColors.neonBlue),
          const SizedBox(height: 10),
          Row(children: [
            _viewsStat('TOTAL VIEWS', _fmt(l.views), BrokaColors.neonBlue),
            _revDivider(),
            _viewsStat(
              'AVG / DAY',
              avgPerDay != null ? avgPerDay.toStringAsFixed(1) : '—',
              BrokaColors.neonCyan,
            ),
            _revDivider(),
            _viewsStat(
              'LISTED',
              daysSinceListed != null ? '${daysSinceListed}d ago' : 'Recently',
              BrokaColors.gold,
            ),
          ]),
          const SizedBox(height: 22),
          _buildListingZenoPricing(l),
          const SizedBox(height: 16),
          _buildDealStatusRow(l, dealLabel),
          const SizedBox(height: 16),
          if (dealLabel == 'Pending' || dealLabel == 'Active') _buildPlatformCTA(l),
          // The per-listing "get featured" CTA is gone with the rest of the
          // paid placement. It was the same mechanic as the dashboard card
          // removed earlier - pay to sit above sellers who earned the spot -
          // and leaving it here would have contradicted the explainer two
          // screens away that says position cannot be bought.
          if (isFeatured) _buildActiveFeaturedBadge(l),
        ]),
      ),
    ]);
  }

  Widget _buildListingZenoPricing(Listing l) {
    final tip     = _listingZeno[l.id];
    final loading = _listingZenoLoading[l.id] ?? false;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.gold.withOpacity(0.10), BrokaColors.neonBlue.withOpacity(0.06)]),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.28))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(5)),
            child: const Text('ZENO PRICING', style: TextStyle(
                color: Colors.white, fontSize: 8,
                fontWeight: FontWeight.w900, letterSpacing: 1.0))),
          const Spacer(),
          if (loading)
            const SizedBox(width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold))
          else
            PressableScale(
              onTap: () { _listingZeno.remove(l.id); _loadZenoForListing(l); },
              child: const Icon(Icons.refresh_rounded, size: 14, color: BrokaColors.gold)),
        ]),
        const SizedBox(height: 8),
        loading && tip == null
            ? const Text('Zeno is analysing this product…',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12, fontStyle: FontStyle.italic))
            : tip != null
              ? Text(tip, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 12, height: 1.55))
              : const Text('Tap ↻ above to get pricing tips for this product.',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      ]),
    );
  }

  Widget _buildDealStatusRow(Listing l, String label) {
    final c = _dealColour(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withOpacity(0.25))),
      child: Row(children: [
        Container(width: 34, height: 34,
          decoration: BoxDecoration(shape: BoxShape.circle, color: c.withOpacity(0.14)),
          child: Icon(_dealIcon(label), color: c, size: 17)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('DEAL STATUS', style: TextStyle(
              color: c, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: c, fontSize: 14, fontWeight: FontWeight.w700)),
        ])),
        if (label == 'In Escrow')
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: BrokaColors.neonBlue.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.30))),
            child: const Text('Escrow Secured', style: TextStyle(
                color: BrokaColors.neonBlue, fontSize: 10, fontWeight: FontWeight.w700))),
      ]),
    );
  }

  Widget _buildPlatformCTA(Listing l) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: BrokaColors.neonBlue.withOpacity(0.07),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.28))),
    child: Row(children: [
      Container(width: 36, height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle, color: BrokaColors.neonBlue.withOpacity(0.14)),
        child: const Icon(Icons.shield_rounded, color: BrokaColors.neonBlue, size: 18)),
      const SizedBox(width: 12),
      const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Keep this deal on BROKA', style: TextStyle(
            color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 12)),
        SizedBox(height: 3),
        Text('Escrow holds payment until delivery — '
             'you only get paid when the buyer confirms receipt.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11, height: 1.4)),
      ])),
    ]),
  );

  Widget _buildActiveFeaturedBadge(Listing l) {
    final until = l.featuredUntil;
    final diff  = until?.difference(DateTime.now());
    final lbl   = diff != null && diff.isNegative
        ? 'Featured listing has expired'
        : diff != null
          ? 'Featured for ${diff.inDays > 0 ? "${diff.inDays}d" : "${diff.inHours}h"} more'
          : 'Featured listing active';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrokaColors.neonCyan.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.35))),
      child: Row(children: [
        const Icon(Icons.star_rounded, color: BrokaColors.neonCyan, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(lbl, style: const TextStyle(
            color: BrokaColors.neonCyan, fontWeight: FontWeight.w700, fontSize: 12))),
        // The "Renew" button that sat here is gone with the rest of paid
        // placement. A seller whose feature is expiring still sees the
        // countdown in the label to the left; it simply cannot be extended
        // by paying, which is the point of removing it.
      ]),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // TAB 2 — DEALS
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildDealsTab() {
    final withDeals = _listings.where((l) => _dealStatusMap.containsKey(l.id)).toList();
    final inEscrow  = withDeals.where((l) => _dealLabel(l) == 'In Escrow').toList();
    final pending   = withDeals.where((l) => _dealLabel(l) == 'Pending').toList();
    final completed = withDeals.where((l) => _dealLabel(l) == 'Complete').toList();
    final active    = withDeals.where((l) => _dealLabel(l) == 'Active').toList();

    return RefreshIndicator(
      // Was an un-awaited fire-and-forget loop over every listing: the
      // spinner vanished the instant the gesture ended while 100 requests
      // were still in flight, so "refreshed" appeared on screen before any
      // of the data had come back. _loadStatuses batches at 6 and returns
      // when the work is actually done, which is what RefreshIndicator is
      // asking for.
      onRefresh: () => _loadStatuses(_listings),
      color: BrokaColors.gold,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _secLabel('DEAL SUMMARY'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _dealSummaryCard(
                '${inEscrow.length}', 'In Escrow',
                Icons.lock_rounded, BrokaColors.neonBlue)),
            const SizedBox(width: 10),
            Expanded(child: _dealSummaryCard(
                '${pending.length}', 'Pending',
                Icons.hourglass_bottom_rounded, BrokaColors.warning)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _dealSummaryCard(
                '${completed.length}', 'Completed',
                Icons.check_circle_rounded, BrokaColors.neonGreen)),
            const SizedBox(width: 10),
            Expanded(child: _dealSummaryCard(
                '${active.length}', 'No Deal Yet',
                Icons.store_rounded, BrokaColors.textMid)),
          ]),
          const SizedBox(height: 24),
          _buildEscrowBanner(),
          const SizedBox(height: 24),
          if (inEscrow.isNotEmpty) ...[
            _secLabel('IN ESCROW — PAYMENT SECURED', color: BrokaColors.neonBlue),
            const SizedBox(height: 10),
            ...inEscrow.map(_dealCard),
            const SizedBox(height: 20),
          ],
          if (pending.isNotEmpty) ...[
            _secLabel('PENDING DEALS', color: BrokaColors.warning),
            const SizedBox(height: 10),
            ...pending.map(_dealCard),
            const SizedBox(height: 20),
          ],
          if (completed.isNotEmpty) ...[
            _secLabel('RECENTLY COMPLETED', color: BrokaColors.neonGreen),
            const SizedBox(height: 10),
            ...completed.map(_dealCard),
            const SizedBox(height: 20),
          ],
          if (active.isNotEmpty) ...[
            _secLabel('NO ACTIVE DEAL'),
            const SizedBox(height: 10),
            ...active.map(_dealCard),
            const SizedBox(height: 20),
          ],
          if (withDeals.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 30),
              child: Center(child: Column(children: [
                CircularProgressIndicator(color: BrokaColors.gold, strokeWidth: 2),
                SizedBox(height: 14),
                Text('Loading deal statuses…',
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
              ]))),
          _buildReceiptsButton(),
        ]),
      ),
    );
  }

  Widget _dealSummaryCard(String v, String l, IconData ic, Color c) =>
      AnimatedBuilder(
        animation: _glow,
        builder: (_, __) => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
                begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.withOpacity(0.18 + 0.08 * _glow.value)),
            boxShadow: [BoxShadow(
                color: c.withOpacity(0.04 + 0.02 * _glow.value), blurRadius: 12)]),
          child: Row(children: [
            Container(width: 36, height: 36,
              decoration: BoxDecoration(shape: BoxShape.circle, color: c.withOpacity(0.12)),
              child: Icon(ic, color: c, size: 18)),
            const SizedBox(width: 10),
            // Expanded + ellipsis: "Completed" beside the icon is wider than
            // half a small phone at a large text size.
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _CountUpText(value: v, style: TextStyle(
                  color: c, fontSize: 20,
                  fontWeight: FontWeight.w800, fontFamily: 'monospace')),
              Text(l,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
            ])),
          ]),
        ));

  Widget _buildEscrowBanner() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [
        BrokaColors.neonBlue.withOpacity(0.10),
        BrokaColors.neonGreen.withOpacity(0.06)]),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.28))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Icon(Icons.shield_rounded, color: BrokaColors.neonBlue, size: 18),
        SizedBox(width: 8),
        Text('BROKA Escrow Protection', style: TextStyle(
            color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 13)),
      ]),
      const SizedBox(height: 8),
      const Text(
        'When buyers pay through BROKA, their payment is held in escrow. '
        'You receive the funds only after the buyer confirms receipt — '
        'giving both parties full protection. Never accept payment outside the platform.',
        style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.5)),
      const SizedBox(height: 10),
      // Wrap, not Row: three chips don't fit one line on a small phone.
      Wrap(spacing: 8, runSpacing: 6, children: [
        _chip2('No cash risks'),
        _chip2('Dispute protection'),
        _chip2('Instant release'),
      ]),
    ]),
  );

  Widget _chip2(String l) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: BrokaColors.neonBlue.withOpacity(0.10),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.25))),
    child: Text(l, style: const TextStyle(
        color: BrokaColors.neonBlue, fontSize: 9, fontWeight: FontWeight.w700)));

  Widget _dealCard(Listing l) {
    final label  = _dealLabel(l);
    final colour = _dealColour(label);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colour.withOpacity(0.22))),
      child: Row(children: [
        Container(width: 40, height: 40,
          decoration: BoxDecoration(
            color: BrokaColors.gold.withOpacity(0.10),
            borderRadius: BorderRadius.circular(10)),
          child: Center(child: Text(l.emoji, style: const TextStyle(fontSize: 20)))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.name, style: const TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 13),
            maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(l.formattedPrice, style: const TextStyle(
              color: BrokaColors.gold, fontSize: 12, fontWeight: FontWeight.w600)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: colour.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: colour.withOpacity(0.30))),
            child: Text(label, style: TextStyle(
                color: colour, fontSize: 10, fontWeight: FontWeight.w700))),
          const SizedBox(height: 5),
          Row(children: [
            const Icon(Icons.visibility_rounded, size: 10, color: BrokaColors.textLow),
            const SizedBox(width: 3),
            Text('${l.views}', style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 10)),
          ]),
        ]),
      ]),
    );
  }

  // ── Shared helper ─────────────────────────────────────────────────────────────
  /// The Menu's section label (MenuSectionLabel): textMid, not textLow - at
  /// about 1.6:1 against the background the old labels could not be read.
  Widget _secLabel(String t, {Color? color}) => Text(t, style: TextStyle(
      color: color ?? BrokaColors.textMid, fontSize: 11,
      fontWeight: FontWeight.w700, letterSpacing: 1.3));
}

// ══════════════════════════════════════════════════════════════════════════════
// CUSTOM PAINTERS
// ══════════════════════════════════════════════════════════════════════════════

// ── Radial Gauge (for stat cards) ────────────────────────────────────────────
class _RadialGaugePainter extends CustomPainter {
  final double progress; // 0.0 – 1.0
  final Color  color;
  final double glowT;   // animation value 0.0 – 1.0
  _RadialGaugePainter({required this.progress, required this.color, required this.glowT});

  @override
  void paint(Canvas canvas, Size size) {
    final cx    = size.width / 2;
    final cy    = size.height / 2;
    final r     = math.min(cx, cy) - 5;
    const start = -math.pi * 0.75;
    const sweep = math.pi * 1.5;

    // Track ring
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      start, sweep, false,
      Paint()
        ..color = BrokaColors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round);

    if (progress <= 0) return;
    final arc = sweep * progress.clamp(0.0, 1.0);

    // Glow halo
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      start, arc, false,
      Paint()
        ..color = color.withOpacity(0.25 + 0.12 * glowT)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));

    // Main arc — violet→color gradient
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      start, arc, false,
      Paint()
        ..shader = SweepGradient(
          colors: [color.withOpacity(0.5), color],
          startAngle: start,
          endAngle:   start + sweep,
          tileMode: TileMode.clamp,
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_RadialGaugePainter o) =>
      o.progress != progress || o.glowT != glowT;
}

// ── Futuristic Day-views Bar Chart (Mon–Sun) ──────────────────────────────────
class _DayViewsPainter extends CustomPainter {
  final List<double> values;
  static const _labels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  _DayViewsPainter({required this.values});

  @override
  void paint(Canvas canvas, Size size) {
    final n      = values.length;
    const gap    = 5.0;
    final bottom = size.height - 18.0;
    final barW   = (size.width - gap * (n - 1)) / n;
    final maxIdx = values.indexOf(values.reduce(math.max));
    final tp     = TextPainter(textDirection: TextDirection.ltr);

    // Grid
    for (int g = 1; g <= 4; g++) {
      final y = bottom - (bottom - 2) * g / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y),
          Paint()..color = BrokaColors.border..strokeWidth = 0.6);
    }

    for (int i = 0; i < n; i++) {
      final left = i * (barW + gap);
      final barH = (bottom - 2) * values[i].clamp(0.02, 1.0);
      final top  = bottom - barH;
      final rr   = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, top, barW, barH),
        topLeft: const Radius.circular(5), topRight: const Radius.circular(5));

      canvas.drawRRect(rr, Paint()
        ..shader = LinearGradient(
          colors: [
            const Color(0xFF3B82F6).withOpacity(0.85),
            const Color(0xFF8B5CF6),
            const Color(0xFF8B5CF6),
          ],
          begin: Alignment.bottomCenter, end: Alignment.topCenter,
        ).createShader(Rect.fromLTWH(left, top, barW, barH)));

      if (i == maxIdx) {
        canvas.drawRRect(rr.inflate(2), Paint()
          ..color = const Color(0xFF8B5CF6).withOpacity(0.28)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
        canvas.drawLine(Offset(left + 2, top), Offset(left + barW - 2, top),
            Paint()
              ..color = const Color(0xFF00E5CC)
              ..strokeWidth = 1.5
              ..strokeCap = StrokeCap.round);
      }

      tp.text = TextSpan(text: _labels[i],
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 8.5));
      tp.layout();
      tp.paint(canvas, Offset(left + barW / 2 - tp.width / 2, bottom + 4));
    }
  }

  @override
  bool shouldRepaint(_DayViewsPainter o) => o.values != values;
}

// ── Futuristic Week-views Line Chart (6 weeks) ────────────────────────────────
class _WeekViewsPainter extends CustomPainter {
  final List<double> values;
  _WeekViewsPainter({required this.values});

  @override
  void paint(Canvas canvas, Size size) {
    final n      = values.length;
    if (n < 2) return;
    final bottom  = size.height - 16.0;
    final usableH = bottom - 4.0;
    final step    = size.width / (n - 1);

    final pts = List.generate(n,
        (i) => Offset(i * step, bottom - usableH * values[i].clamp(0.05, 1.0)));

    // Fill
    final fillPath = Path()..moveTo(pts.first.dx, bottom);
    for (final p in pts) {
      fillPath.lineTo(p.dx, p.dy);
    }
    fillPath.lineTo(pts.last.dx, bottom);
    fillPath.close();
    canvas.drawPath(fillPath, Paint()
      ..shader = LinearGradient(
        colors: [
          const Color(0xFF8B5CF6).withOpacity(0.35),
          const Color(0xFF00E5CC).withOpacity(0.05)],
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)));

    final linePath = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (int i = 1; i < n; i++) {
      linePath.lineTo(pts[i].dx, pts[i].dy);
    }

    // Shadow
    canvas.drawPath(linePath, Paint()
      ..color = const Color(0xFF8B5CF6).withOpacity(0.30)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));

    // Main line
    canvas.drawPath(linePath, Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF8B5CF6), Color(0xFF3B82F6), Color(0xFF00E5CC)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round);

    // Dots
    for (final p in pts) {
      canvas.drawCircle(p, 5, Paint()
        ..color = const Color(0xFF8B5CF6).withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawCircle(p, 3, Paint()..color = const Color(0xFF00E5CC));
      canvas.drawCircle(p, 1.5, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_WeekViewsPainter o) => o.values != values;
}

// ── Radar Chart ───────────────────────────────────────────────────────────────
class _BarChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final Color        color;
  _BarChartPainter({required this.values, required this.labels, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final n    = values.length;
    final barW = (size.width - (n - 1) * 6) / n;
    final tp   = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < n; i++) {
      final left = i * (barW + 6);
      final barH = (size.height - 20) * values[i];
      final top  = size.height - 20 - barH;
      final rr   = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, top, barW, barH),
        topLeft: const Radius.circular(4), topRight: const Radius.circular(4));
      canvas.drawRRect(rr, Paint()
        ..shader = LinearGradient(
          colors: [color.withOpacity(0.9), color.withOpacity(0.4)],
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
        ).createShader(Rect.fromLTWH(left, top, barW, barH)));
      tp.text = TextSpan(text: labels[i],
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 9));
      tp.layout();
      tp.paint(canvas, Offset(left + barW / 2 - tp.width / 2, size.height - 14));
    }
  }

  @override
  bool shouldRepaint(_BarChartPainter o) => false;
}

/// Counts a numeric stat up from zero on first build.
///
/// Takes the already-formatted string ("1.2K", "KES 4,500", "87%") and
/// animates only the leading number it finds, leaving prefixes, suffixes
/// and separators alone - so the widget never has to know the formatting
/// rules of every caller, and a value it cannot parse simply renders as
/// given instead of breaking.
///
/// Worth the widget because a dashboard's whole job is the numbers: having
/// them arrive rather than appear is what makes the screen feel alive, and
/// it draws the eye to the figures in the order they matter.
class _CountUpText extends StatelessWidget {
  final String value;
  final TextStyle style;
  const _CountUpText({required this.value, required this.style});

  static final _leadingNumber = RegExp(r'^([^0-9-]*)(-?[0-9]+(?:\.[0-9]+)?)(.*)$');

  @override
  Widget build(BuildContext context) {
    final m = _leadingNumber.firstMatch(value);
    if (m == null || BrokaMotion.reduced(context)) {
      return Text(value, style: style);
    }
    final prefix = m.group(1)!;
    final target = double.tryParse(m.group(2)!);
    final suffix = m.group(3)!;
    if (target == null) return Text(value, style: style);

    final decimals = m.group(2)!.contains('.')
        ? m.group(2)!.split('.')[1].length : 0;

    return TweenAnimationBuilder<double>(
      // Keyed on the target so a refresh that changes the number animates
      // to the new one instead of restarting from zero.
      key: ValueKey(value),
      tween: Tween(begin: 0, end: target),
      duration: BrokaMotion.slow,
      curve: BrokaMotion.enter,
      builder: (_, v, __) => Text(
        '$prefix${v.toStringAsFixed(decimals)}$suffix',
        style: style,
      ),
    );
  }
}

/// Horizontal rail that scrolls itself, slowly and continuously.
///
/// Auto-scroll exists because twenty cards behind a swipe are twenty cards
/// nobody reads — the first two get seen and the rest may as well not be
/// there. Drifting means a seller glancing at the dashboard meets a
/// different one each time.
///
/// Three things keep it from becoming annoying:
///   * It is slow (~22 logical px/sec), so it reads as ambient rather than
///     as something demanding attention.
///   * Touching it stops it, permanently for that visit. Content that keeps
///     moving while you are trying to read it is worse than static content,
///     and a seller who swipes has said what they want.
///   * It honours reduce-motion by not starting at all.
///
/// Wraps by jumping back to the start rather than reversing: a rail that
/// ping-pongs makes the same two cards the ones you always see.
class _AutoScrollRail extends StatefulWidget {
  final int itemCount;
  final double itemWidth;
  final Widget Function(BuildContext, int) builder;
  const _AutoScrollRail({
    required this.itemCount, required this.itemWidth, required this.builder});

  @override
  State<_AutoScrollRail> createState() => _AutoScrollRailState();
}

class _AutoScrollRailState extends State<_AutoScrollRail>
    with SingleTickerProviderStateMixin {
  final ScrollController _ctrl = ScrollController();
  Ticker? _ticker;
  bool _stopped = false;
  Duration _last = Duration.zero;

  static const _pixelsPerSecond = 22.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || BrokaMotion.reduced(context)) return;
      _ticker = createTicker(_tick)..start();
    });
  }

  void _tick(Duration elapsed) {
    if (_stopped || !_ctrl.hasClients) { _last = elapsed; return; }
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // Guard against a huge first frame or a resume after backgrounding
    // dumping the rail straight to the end.
    if (dt <= 0 || dt > 0.5) return;

    final max = _ctrl.position.maxScrollExtent;
    if (max <= 0) return;
    var next = _ctrl.offset + _pixelsPerSecond * dt;
    if (next >= max) next = 0;
    _ctrl.jumpTo(next);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // Any user-driven scroll hands control over for good.
          if (n is UserScrollNotification) _stopped = true;
          return false;
        },
        child: ListView.builder(
          controller: _ctrl,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: widget.itemCount,
          itemBuilder: widget.builder,
        ),
      );
}

/// Animated three-axis trust chart.
///
/// Draws in as the values sweep out from the centre, so the shape arrives
/// rather than appearing — on a screen whose whole job is showing a seller
/// where they stand, the growth reads as progress.
///
/// The old painter drew four flat rings and a static polygon. This adds a
/// gradient fill, per-vertex markers, a soft glow tied to the dashboard's
/// existing pulse, and scores printed beside each label so the shape does
/// not have to be read against a grid to mean anything.
class _TrustTrianglePainter extends CustomPainter {
  final List<double> values;   // 0..1
  final List<String> labels;
  final List<double> scores;   // 0..10, for the printed figure
  final double progress;       // 0..1 draw-in
  final double pulse;          // 0..1 ambient breath

  _TrustTrianglePainter({
    required this.values, required this.labels, required this.scores,
    required this.progress, required this.pulse,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2 + 6);
    final radius = math.min(size.width, size.height) / 2 - 42;
    final n = values.length;

    // -90 degrees puts the first axis at the top; a flat-topped triangle
    // reads as a shape rather than as an arrow pointing somewhere.
    double angle(int i) => -math.pi / 2 + i * 2 * math.pi / n;
    Offset at(int i, double r) =>
        centre + Offset(math.cos(angle(i)) * r, math.sin(angle(i)) * r);

    // ── Rings ────────────────────────────────────────────────────────────
    for (var ring = 1; ring <= 4; ring++) {
      final r = radius * ring / 4;
      final path = Path();
      for (var i = 0; i < n; i++) {
        final p = at(i, r);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, Paint()
        ..color = BrokaColors.border.withOpacity(ring == 4 ? 0.55 : 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = ring == 4 ? 1.2 : 0.8);
    }

    // Spokes
    for (var i = 0; i < n; i++) {
      canvas.drawLine(centre, at(i, radius), Paint()
        ..color = BrokaColors.border.withOpacity(0.3)
        ..strokeWidth = 0.8);
    }

    // ── The shape ────────────────────────────────────────────────────────
    final pts = [
      for (var i = 0; i < n; i++)
        at(i, radius * values[i].clamp(0.0, 1.0) * progress)
    ];
    final shape = Path();
    for (var i = 0; i < n; i++) {
      i == 0 ? shape.moveTo(pts[i].dx, pts[i].dy)
             : shape.lineTo(pts[i].dx, pts[i].dy);
    }
    shape.close();

    canvas.drawPath(shape, Paint()
      ..shader = RadialGradient(
        colors: [
          BrokaColors.gold.withOpacity(0.38),
          BrokaColors.neonBlue.withOpacity(0.16),
        ],
      ).createShader(Rect.fromCircle(center: centre, radius: radius)));

    canvas.drawPath(shape, Paint()
      ..color = BrokaColors.gold.withOpacity(0.55 + 0.25 * pulse)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeJoin = StrokeJoin.round);

    // ── Vertices and labels ──────────────────────────────────────────────
    for (var i = 0; i < n; i++) {
      canvas.drawCircle(pts[i], 7 + 2 * pulse,
          Paint()..color = BrokaColors.gold.withOpacity(0.16));
      canvas.drawCircle(pts[i], 3.4, Paint()..color = BrokaColors.gold);

      final labelPos = at(i, radius + 24);
      final tp = TextPainter(
        text: TextSpan(children: [
          TextSpan(text: '${labels[i]}\n', style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 10.5,
              fontWeight: FontWeight.w700)),
          TextSpan(text: scores[i].toStringAsFixed(1), style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 13,
              fontWeight: FontWeight.w900)),
        ]),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, labelPos - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_TrustTrianglePainter o) =>
      o.progress != progress || o.pulse != pulse || o.values != values;
}

