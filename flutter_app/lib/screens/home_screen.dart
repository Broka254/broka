// BROKA v4.0 - Home Screen [Dark Matter Edition]
// Search history, unified discovery rail, listing-first feed.
// Goods/Brokers/House Hunting TabBar and the stats-ticker row were removed
// per Design Journal Volume 6, Ch.23 (Phase 0) — brokers and house hunting
// are out of scope for this release; see Ch.2 on de-emphasizing vanity stats.
// Goods/Traders mode toggle removed per the home-redesign brief
// (2026-08-16) — see _buildDiscoveryRail()'s own comment.
// Final HomeScreen polish pass (2026-08-19, product review): Home no
// longer auto-detects location on open (see initState below) - "GPS-first"
// in the old version of the line above stopped being true, so it's been
// removed rather than left stale. Full rationale at _detectLocation()'s
// old call site and in CHANGES.md.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/utils/result.dart';
import '../utils/backend_time.dart';
import '../main.dart';
import '../services/last_screen_tracker.dart';
import '../services/api_service.dart';
import '../utils/auth_gate.dart';
import '../widgets/particle_field.dart';
import '../widgets/product_grid_view.dart';
import '../widgets/zeno_avatar.dart';
import '../widgets/product_card.dart';
import '../features/categories/data/repositories/categories_repository.dart';
import '../features/categories/domain/models/category.dart';
import '../features/categories/presentation/category_zone_screen.dart';
import '../features/trending/presentation/trending_screen.dart';
import '../features/auctions/presentation/auction_house_screen.dart';
import '../features/buy_agent/presentation/buy_agent_hub_screen.dart';
import '../features/buy_agent/data/repositories/buy_agent_repository.dart';
import '../features/buy_agent/domain/models/buy_agent_request.dart';
import 'ai_assistant_screen.dart';
import '../features/traders/presentation/trader_list_screen.dart';
import '../features/stores/presentation/store_list_screen.dart';
import '../features/listings/domain/models/listing.dart' show BrokaListing;
import '../features/listings/data/repositories/listings_repository.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  int _navIndex = 0;
  String? _locationLabel;
  bool _gettingLocation = false;
  late AnimationController _pulseCtrl;

  // Search history
  List<String> _searchHistory = [];

  // Filters. _priceFilter drives the slider UI live; _committedPriceFilter
  // is what the grid actually fetches against, updated only when the user
  // releases the slider so dragging doesn't refetch on every frame (matches
  // the old _loadListings-on-onChangeEnd behaviour).
  double _maxPrice = 5000000;
  double _priceFilter = 5000000;
  double _committedPriceFilter = 5000000;
  bool _showFilters = false;
  String? _locationFilter;
  // FIX (redesign-guide audit): Home Redesign Guide §5/§20 lists Global
  // filters as Location, Price range, Condition, Sort - this screen only
  // ever had Price + Location. Home's own feed also used to run entirely
  // on the older ApiService.getListings()/Listing stack, which has no
  // condition/sort/search support at all (see listings_repository.dart's
  // ListingsRepository, used everywhere else in the app since Phase 1).
  String? _conditionFilter;
  String? _sortFilter;
  // Bumped whenever something outside the filters changed (returned from
  // Sell, or from a product detail screen) to force the grid below to
  // remount and refetch, since ProductGridView keys off filter state.
  int _feedRefreshNonce = 0;

  // Category carousel (Design Journal Volume 6, Ch.3/Ch.24)
  List<Category> _topCategories = [];
  bool _categoriesLoaded = false;

  BuyAgentRequest? _activeBuyAgentRequest;

  // Design Journal Volume 6, Ch.9/Ch.29 (Appendix C). Variant A is the
  // full layout built across Phases 0-5 below; Variant B is a single
  // prominent search entry that hands straight off to the Advisor
  // persona (ai_assistant_screen.dart). Defaults to 'A': Variant B is an
  // unproven alternative that should require an explicit build flag to
  // enable, not become the silent default.
  //
  // Honest gap: the doc asks this variant split to log time-to-first-
  // listing-view and a week-two-return marker "to whatever analytics
  // path the app already uses." There isn't one - no analytics package,
  // no logEvent/trackEvent call, anywhere in this codebase. Standing up a
  // new pipeline was explicitly ruled out by the same instruction, so
  // this ships the variant switch itself (independently useful and
  // testable) without the metrics calls, rather than either inventing a
  // fake pipeline or silently dropping the requirement.
  static const String _variant = String.fromEnvironment('HOMESCREEN_VARIANT', defaultValue: 'A');
  static const _navItems = [
    {'icon': Icons.grid_view_rounded,      'label': 'Home'},
    {'icon': Icons.inbox_outlined,         'label': 'Inbox'},
    {'icon': Icons.add_circle_outline,     'label': 'Sell'},
    {'icon': Icons.auto_awesome_rounded,   'label': 'Zeno'},
    {'icon': Icons.person_outline_rounded, 'label': 'Profile'},
  ];

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  String get _greetingText {
    final name = ApiService.currentUserName;
    if (name != null && name.isNotEmpty) return '$_greeting, ${name.split(' ').first} 👋';
    return _greeting;
  }

  @override
  void initState() {
    super.initState();
    LastScreenTracker.save('/home');
    // Final HomeScreen polish pass (2026-08-19, product review): the
    // round-2 comment that used to sit here justified auto-detecting
    // location on every Home open because it "feeds the main feed's
    // per-listing distance_km annotation." Checked both halves of that
    // claim against the real code and neither holds up: _fetchListingsPage
    // below sends lat/lng but never max_km, and listings/service.py only
    // *filters* by distance when max_km is provided alongside coordinates
    // - without it, lat/lng doesn't restrict the result set at all, and
    // ProductCard has no distanceKm display anywhere to show even the
    // per-listing annotation. So this was GPS permission + reverse-
    // geocoding work paid for on every Home load with no visible Home
    // benefit - asking a user for location just to open a marketplace.
    // _detectLocation() itself is unchanged and not deleted - trader
    // list/profile, the Buy Agent hub, negotiation, Sell, and the listing
    // map all still read ApiService.currentUserLat/Lng - Home just no
    // longer triggers detection on its own. It should be wired to an
    // explicit call site (e.g. an opt-in "near me" filter) if and when
    // Home grows a feature that genuinely needs it.
    _loadSearchHistory();
    _loadTopCategories();
    // _loadTrending()/_loadLiveAuctions() removed (home-redesign brief
    // round 2, 2026-08-17): Home no longer renders a Trending grid or a
    // Live Auctions carousel of its own (see _buildDiscoveryRail's own
    // note) - both are pure rail destinations now, each fetching its own
    // data only once TrendingScreen/AuctionHouseScreen actually opens.
    // Calling their APIs here was work Home paid for and never used.
    _loadActiveBuyAgentRequest();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _railScrollController.dispose();
    super.dispose();
  }

  final ScrollController _railScrollController = ScrollController();

  // ── Search History ────────────────────────────────────────────────────────

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('search_history') ?? [];
    if (mounted) setState(() => _searchHistory = list);
  }

  Future<void> _addSearchHistory(String query) async {
    if (query.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('search_history') ?? [];
    list.remove(query);
    list.insert(0, query);
    if (list.length > 10) list.removeRange(10, list.length);
    await prefs.setStringList('search_history', list);
    if (mounted) setState(() => _searchHistory = list);
  }

  Future<void> _clearSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('search_history');
    if (mounted) setState(() => _searchHistory = []);
  }

  // ── Category carousel ─────────────────────────────────────────────────────

  Future<void> _loadTopCategories() async {
    final result = await categoriesRepository.getTopLevel();
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _topCategories = data;
        _categoriesLoaded = true;
      }),
      // Previously silent (carousel just stayed empty/hidden) - which made
      // "categories table hasn't been seeded yet" indistinguishable from
      // "this is broken". _categoriesLoaded lets the carousel below tell
      // those two states apart without an alarming error box for what's
      // still a non-critical strip.
      onFailure: (_, __) => setState(() => _categoriesLoaded = true),
    );
  }

  void _openCategoryZone(Category category) {
    // Zero-duration transition is Chapter 3's explicit, deliberate
    // requirement (re-confirmed in Ch.17 of the source spec) - not a
    // missing animation. A plain PageRouteBuilder with
    // transitionDuration: Duration.zero is the correct way to express
    // that, not a very-short AnimationController.
    Navigator.push(context, PageRouteBuilder(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) =>
          CategoryZoneScreen(categoryId: category.id, categoryName: category.name),
    ));
  }

  // Home-redesign brief §3-§6 (2026-08-16): categories, Trending, Auctions,
  // and Traders used to be visually split into three separate rows/areas
  // (a category-circle strip, a "Quick Access" chip row, and a Goods/
  // Traders mode toggle that swapped Home's entire body). All four were
  // unified into one horizontally-scrolling rail, same pill shape for
  // every item, so nothing read as more "special" than anything else.
  //
  // Final HomeScreen polish pass (2026-08-19, product review): still one
  // rail, still one pill shape - categories and Trending/Auctions/Traders
  // are NOT split into separate rows or given different card sizes. But
  // fully identical treatment made two conceptually different kinds of
  // item (ways to browse goods, vs. standalone destinations) hard to tell
  // apart at a glance, so a single thin divider now sits between the last
  // category and Trending onward - see isDestination on _RailItem and
  // _railDivider() below. The old post-load auto-scroll nudge
  // (_nudgeDiscoveryRail(), 0→56px→0) is also gone, replaced by a static
  // right-edge fade so the rail no longer moves on its own; the user
  // controls it entirely now.
  Widget _buildDiscoveryRail() {
    if (_topCategories.isEmpty && !_categoriesLoaded) return const SizedBox(height: 80);
    final items = <_RailItem>[
      ..._topCategories.map((c) => _RailItem(
            emoji: _categoryEmoji(c.name), label: c.name,
            colors: BrokaColors.zoneGradientFor(c.name),
            onTap: () => _openCategoryZone(c),
          )),
      _RailItem(
        emoji: '🔥', label: 'Trending',
        colors: const [BrokaColors.neonPink, Color(0xFFFF6B9D)],
        isDestination: true,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TrendingScreen())),
      ),
      _RailItem(
        emoji: '🔨', label: 'Auctions',
        colors: const [BrokaColors.danger, Color(0xFFFF8C42)],
        isDestination: true,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AuctionHouseScreen())),
      ),
      // Home-redesign brief §6: tapping Traders navigates to a dedicated
      // screen rather than filtering/replacing Home's own product grid -
      // TraderListScreen() with no `embedded` flag gives the full
      // standalone screen (its own back button etc.), same widget the old
      // Goods/Traders toggle used in embedded mode, just reached by
      // pushing a route instead of swapping Home's body via MarketplaceState.
      _RailItem(
        emoji: '👤', label: 'Traders',
        colors: const [BrokaColors.neonBlue, Color(0xFF60A5FA)],
        isDestination: true,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TraderListScreen())),
      ),
      // Store feature, Phase 4 (spec §12/§21): same rail, same pill shape -
      // explicitly NOT a new Home section or grid. This is the entire
      // "minimum Store entry point" the spec asks for on Home; the fuller
      // entry point is a listing's own store badge (ProductCard) or
      // Profile once you own a store.
      _RailItem(
        emoji: '🏬', label: 'Stores',
        colors: const [BrokaColors.gold, BrokaColors.neonPurple],
        isDestination: true,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StoreListScreen())),
      ),
    ];
    // Right-edge fade is a ShaderMask over the ListView's own viewport
    // (BlendMode.dstIn fading source alpha near the right edge) rather
    // than a painted overlay in a guessed background color - stays
    // correct against the header's gradient (BrokaColors.headerGradColors)
    // without hardcoding a fade-to color that could drift from it.
    return SizedBox(
      height: 80,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [Colors.transparent, Colors.white],
          stops: [0.0, 0.07],
        ).createShader(bounds),
        child: ListView.builder(
          controller: _railScrollController,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          itemCount: items.length,
          itemBuilder: (_, i) {
            // Divider sits only at the one category→destination boundary,
            // never between two categories or between two destinations.
            final showDivider = i > 0 && items[i].isDestination && !items[i - 1].isDestination;
            if (!showDivider) return _railPill(items[i]);
            return Row(mainAxisSize: MainAxisSize.min, children: [
              _railDivider(),
              _railPill(items[i]),
            ]);
          },
        ),
      ),
    );
  }

  // Final HomeScreen polish pass (2026-08-19): the one visual cue that
  // categories and Trending/Auctions/Traders aren't quite the same kind of
  // thing - a plain hairline, not a card border, a label, or a new row.
  Widget _railDivider() => Container(
        width: 1,
        height: 44,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: BrokaColors.textLow,
      );

  // Home-redesign brief round 3 (2026-08-18, reported: "Beauty & P...",
  // "Books & Ed..." truncate unreadably at 1 line/68px) - widened the pill
  // slightly and allowed a second line instead of forcing everything onto
  // one truncated line. Long names still ellipsize as a last resort (a
  // 3-word category name could still overflow 2 lines on a 320px-wide
  // device), but most of the real category names in categories/seed.py
  // now fit without cutting off mid-word.
  Widget _railPill(_RailItem item) => GestureDetector(
        onTap: item.onTap,
        child: Container(
          width: 74,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 52,
              height: 52,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: item.colors),
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: item.colors.first.withOpacity(0.30), blurRadius: 8)],
              ),
              child: Container(
                decoration: const BoxDecoration(color: BrokaColors.bgCard, shape: BoxShape.circle),
                child: Center(child: Text(item.emoji, style: const TextStyle(fontSize: 20))),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 9.5, height: 1.15),
            ),
          ]),
        ),
      );

  static const _categoryEmojiMap = <String, String>{
    'automobiles': '🚗', 'vehicles': '🚗', 'electronics': '📱', 'phones': '📱',
    'computers': '💻', 'gaming': '🎮', 'furniture': '🛋️', 'home appliances': '🔌',
    'clothing': '👕', 'beauty': '💄', 'sports': '⚽', 'books': '📚',
    'musical instruments': '🎸', 'farm equipment': '🚜', 'construction': '🏗️',
    'property': '🏠',
    // Canonical taxonomy (mockup-actualization spec §2, Phase 1). 'vehicles'
    // and 'property' above already cover two of these; the rest are new.
    'home & furniture': '🛋️', 'fashion': '👗', 'agriculture': '🌾',
    'beauty & personal care': '💄', 'sports & fitness': '⚽',
    'books & education': '📚', 'music & instruments': '🎸',
    'business & industrial': '🏭', 'pets & animals': '🐾', 'services': '🛠️',
    // 'other' intentionally omitted - falls through to the 🛍️ default
    // below, which suits a real catch-all better than a made-up icon.
  };

  String _categoryEmoji(String name) => _categoryEmojiMap[name.toLowerCase()] ?? '🛍️';

  // _loadTrending()/_loadLiveAuctions()/_buildLiveAuctionsCarousel() removed
  // (home-redesign brief round 2, 2026-08-17): Trending and Auctions are
  // now pure _buildDiscoveryRail() destinations - Home no longer fetches
  // either API or renders a content block for either. TrendingScreen/
  // AuctionHouseScreen are unchanged and fetch their own data when opened.

  Future<void> _loadActiveBuyAgentRequest() async {
    final result = await buyAgentRepository.getActive();
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() => _activeBuyAgentRequest = data),
      onFailure: (_, __) {}, // section just stays hidden - not critical path
    );
  }

  // Home-redesign brief §3-§9 (2026-08-16): the old Quick Access row
  // (Trending/Auctions/Zeno chips) is gone - Trending/Auctions moved into
  // _buildDiscoveryRail() above, Zeno moved into _buildZenoCompactCta()
  // below.

  // Opens the full Hub screen now that it exists (Design v2 §14: "should
  // be a full feature, not merely a bottom-sheet form") - this replaced
  // Home's previous showModalBottomSheet(BuyAgentSheet) call as the entry
  // point from every Zeno touchpoint on this screen. BuyAgentSheet itself
  // is untouched and still reachable via its own route, just no longer
  // linked from here.
  void _openBuyAgentHub() => Navigator.push(
        context, MaterialPageRoute(builder: (_) => const BuyAgentHubScreen()));

  // ── Zeno Buying Agent (Home Redesign Guide §10, Design v2 §14) ────────────
  // Home-redesign brief §9 (2026-08-16): the previous card (avatar +
  // headline + description + full-width button, ~180px tall) is replaced
  // with a single compact row, targeting ~50-70px, since Zeno already has
  // its own bottom-nav destination and doesn't need a second large
  // promotional block on Home. Reuses _pulseCtrl (created in initState,
  // previously unused by anything) for a slow, gentle breathing glow -
  // brief §26: "3-5 seconds... do NOT pulse aggressively."
  Widget _buildZenoCompactCta() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: GestureDetector(
        onTap: _openBuyAgentHub,
        child: AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (context, child) {
            final glow = 0.14 + 0.10 * _pulseCtrl.value;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(
                  colors: [Color(0xFF1A1040), Color(0xFF0E1B3D)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.4)),
                boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(glow), blurRadius: 16, spreadRadius: 1)],
              ),
              child: child,
            );
          },
          child: Row(children: [
            const ZenoAvatar(size: 28, glow: true),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('✨ Find it for me with Zeno',
                  style: TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
            const Icon(Icons.arrow_forward_rounded, color: BrokaColors.neonBlue, size: 18),
          ]),
        ),
      ),
    );
  }

  // "Zeno is watching for you" (Home Redesign Guide §13).
  Widget _buildActiveBuyAgentSection() {
    final req = _activeBuyAgentRequest!;
    // hasMatches, not status == 'matched': "0 matches found!" was reachable
    // whenever the two ever disagreed.
    final matched = req.hasMatches;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GestureDetector(
        onTap: _openBuyAgentHub,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Row(children: [
            const ZenoAvatar(size: 30, glow: true),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Zeno is watching for you',
                    style: TextStyle(color: BrokaColors.textLow, fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
                const SizedBox(height: 2),
                Text('${req.category} · Under KES ${req.maxPrice.toStringAsFixed(0)}',
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  matched
                      ? '${req.matchCount} match${req.matchCount == 1 ? '' : 'es'} found!'
                      : 'Still searching…',
                  style: TextStyle(color: matched ? BrokaColors.success : BrokaColors.textLow, fontSize: 11.5),
                ),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: BrokaColors.textLow, size: 20),
          ]),
        ),
      ),
    );
  }

  // _buildTrendingGrid() removed (home-redesign brief round 2, 2026-08-17).
  // Two independent reasons, not just "less content on Home":
  // 1. Composition - a second, fixed 2-column listing grid sitting above
  //    the real paginated feed was competing content, not a discovery aid
  //    (the whole point of the unified rail is that Trending/Auctions/
  //    Traders are destinations, not their own Home real estate).
  // 2. The "Popular near $location" subtitle it carried was not actually
  //    true: trending/service.py's list_trending has no lat/lng/max_km
  //    handling at all (grepped - zero references) - ranking is purely
  //    view/interest-count with time decay, no geography involved. The
  //    label implied geographic personalization that didn't exist.
  // Trending is now purely a _buildDiscoveryRail() destination -
  // TrendingScreen fetches and shows the real thing, unchanged.

  // ── Listings feed (fetch page for ProductGridView) ───────────────────────
  // Price and location now go to the backend as real query params instead
  // of a client-side .where() after an already-paginated fetch — the
  // latter meant a "page" could come back with only 2 of 20 items visible,
  // or picking a location silently changed nothing at all (location was
  // only ever in the ValueKey below, never actually sent). Same fix as
  // CategoryZoneScreen's Phase 3 pass, applied to Home's own feed.

  Future<List<BrokaListing>> _fetchListingsPage(int page) async {
    // FIX (redesign-guide audit): migrated off ApiService.getListings()/the
    // older Listing model onto the same ListingsRepository/BrokaListing
    // stack every other screen (category zones, trending, buy-agent
    // results) already uses - gains condition/sort filtering (previously
    // impossible from Home at all) and the seller trust fields ProductCard
    // now displays (see listings/service.py _listing_dict). location is
    // the same free-text place-name filter Home always had, now sent to
    // the backend's already-existing `location` param (list_listings ILIKE
    // on location_name) - ListingsRepository just never exposed it before.
    final result = await listingsRepository.getListings(
      limit: 20,
      offset: page * 20,
      maxPrice: _committedPriceFilter,
      condition: _conditionFilter,
      sort: _sortFilter,
      location: _locationFilter,
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    final data = result.fold(onSuccess: (items) => items, onFailure: (_, __) => <BrokaListing>[]);
    // Pin featured listings to the top of each fetched page
    final now = DateTime.now().toUtc();
    final sorted = List<BrokaListing>.from(data)..sort((a, b) {
      // FIX (2026-08-18): plain DateTime.tryParse misreads the backend's
      // naive-UTC timestamps as local time - see utils/backend_time.dart.
      // Here that could keep an already-expired featured listing pinned
      // (or unpin a still-active one) by exactly the device's UTC offset.
      final aUntil = parseBackendUtc(a.featuredUntil);
      final bUntil = parseBackendUtc(b.featuredUntil);
      final aFeat = a.isFeatured && (aUntil?.isAfter(now) ?? false);
      final bFeat = b.isFeatured && (bUntil?.isAfter(now) ?? false);
      if (aFeat && !bFeat) return -1;
      if (!aFeat && bFeat) return 1;
      return 0;
    });
    return sorted;
  }

  // ── Location Detection (GPS-first, IP fallback) ──────────────────────────
  // Fix #2: use Geolocator.getCurrentPosition() first; fall back to IP only
  // when the user denies GPS. This fixes the 0.0km distance bug.

  Future<void> _detectLocation() async {
    setState(() => _gettingLocation = true);
    await _gpsGeolocation();
  }

  Future<void> _gpsGeolocation() async {
    try {
      // Dynamic import so the app still compiles even if geolocator is absent
      // (older builds).  In pubspec.yaml add: geolocator: ^12.0.0
      final geo = await _tryGps();
      if (geo != null) {
        final lat = geo['lat']!;
        final lng = geo['lng']!;
        await ApiService.updateLocation(lat, lng);
        final revLabel = await _reverseGeocode(lat, lng);
        _setLoc(revLabel ?? _coordLabel(lat, lng));
        return;
      }
    } catch (_) {}
    // GPS unavailable or denied — fall back to IP
    await _ipGeolocation();
  }

  Future<Map<String, double>?> _tryGps() async {
    try {
      // Use geolocator if available
      // ignore: depend_on_referenced_packages
      final geolocator = await _geolocatorDynamic();
      if (geolocator == null) return null;
      return geolocator;
    } catch (_) {
      return null;
    }
  }

  /// GPS position using geolocator package.
  Future<Map<String, double>?> _geolocatorDynamic() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) return null;
      }
      if (perm == LocationPermission.deniedForever) return null;
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );
      return {'lat': pos.latitude, 'lng': pos.longitude};
    } catch (_) {
      return null;
    }
  }

  Future<void> _ipGeolocation() async {
    try {
      final response = await http.get(
        Uri.parse('https://ipapi.co/json/'),
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final lat    = (data['latitude']  as num?)?.toDouble();
        final lng    = (data['longitude'] as num?)?.toDouble();
        final city   = data['city']       as String?;
        final region = data['region']     as String?;

        if (lat != null && lng != null) {
          await ApiService.updateLocation(lat, lng);
          final revLabel = await _reverseGeocode(lat, lng);
          final label = revLabel ?? _buildLocationLabel(city, region);
          _setLoc(label.isNotEmpty ? label : _coordLabel(lat, lng));
          return;
        }
      }
    } catch (_) {}
    _setLoc('Kenya');
  }

  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final url = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=json'
          '&lat=$lat&lon=$lng&zoom=10&addressdetails=1');
      final resp = await http.get(url,
          headers: {'User-Agent': 'BrokaApp/2.3'})
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final d = jsonDecode(resp.body) as Map<String, dynamic>;
        final addr = d['address'] as Map<String, dynamic>?;
        if (addr != null) {
          final sub  = addr['suburb']      as String?;
          final town = addr['town']        as String?
              ?? addr['city']              as String?
              ?? addr['village']           as String?;
          final county = addr['county']   as String?
              ?? addr['state_district']   as String?;
          final parts = [sub ?? town, county].where((s) => s != null && s.isNotEmpty);
          if (parts.isNotEmpty) return parts.join(', ');
        }
      }
    } catch (_) {}
    return null;
  }

  String _buildLocationLabel(String? city, String? region) {
    final parts = [city, region].where((s) => s != null && s.isNotEmpty);
    return parts.join(', ');
  }

  void _setLoc(String l) {
    if (mounted) setState(() { _locationLabel = l; _gettingLocation = false; });
  }

  String _coordLabel(double lat, double lng) {
    // Siaya County sub-localities (GPS fallback for when Nominatim is unavailable)
    if (lat >  0.03 && lat < 0.12 && lng > 34.10 && lng < 34.22) return 'Ugunja, Siaya';
    if (lat >  0.25 && lat < 0.40 && lng > 34.05 && lng < 34.20) return 'Bondo, Siaya';
    if (lat > -0.07 && lat < 0.05 && lng > 34.25 && lng < 34.40) return 'Siaya Town';
    if (lat > -0.20 && lat < 0.00 && lng > 34.43 && lng < 34.58) return 'Kisumu';
    if (lat > -0.50 && lat < 0.50 && lng > 33.80 && lng < 34.80) return 'Siaya, Kenya';
    // Major Kenyan cities
    if (lat > -1.50 && lat < -1.10 && lng > 36.60 && lng < 37.10) return 'Nairobi';
    if (lat > -0.20 && lat < 0.20  && lng > 34.60 && lng < 35.00) return 'Kisumu';
    if (lat >  0.00 && lat < 0.60  && lng > 35.00 && lng < 35.50) return 'Eldoret';
    if (lat > -4.20 && lat < -3.80 && lng > 39.50 && lng < 40.00) return 'Mombasa';
    if (lat > -0.60 && lat < -0.20 && lng > 37.00 && lng < 37.30) return 'Thika';
    if (lat > -0.45 && lat < -0.15 && lng > 36.90 && lng < 37.15) return 'Ruiru';
    if (lat > -1.10 && lat < -0.80 && lng > 37.00 && lng < 37.30) return 'Machakos';
    if (lat > -0.40 && lat < 0.00  && lng > 35.25 && lng < 35.55) return 'Nakuru';
    if (lat > -0.70 && lat < -0.35 && lng > 36.05 && lng < 36.35) return 'Naivasha';
    return '${lat.toStringAsFixed(2)}°N, ${lng.toStringAsFixed(2)}°E';
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  static const List<String> _navReasons = [
    '', 'to see your messages', 'to sell something', 'to chat with Zeno',
    'to view your profile',
  ];

  Future<void> _onNav(int i) async {
    if (i == 0) {
      setState(() => _navIndex = 0);
      return;
    }
    // v6.1: guests can browse Home freely, but Inbox/Sell/Zeno/Profile all
    // require an account. requireAuth resumes straight into the tapped
    // destination on success instead of dropping back to Home.
    final authed = await requireAuth(context, reason: _navReasons[i]);
    if (!authed) return;
    if (!mounted) return;
    setState(() => _navIndex = i);
    final routes = ['', '/inbox', '/sell', '/zeno', '/profile'];
    Navigator.pushNamed(context, routes[i]).then((_) {
      if (mounted) setState(() { _navIndex = 0; _feedRefreshNonce++; });
    });
  }

  void _openSearch() {
    showSearch(
      context: context,
      delegate: _ListingSearchDelegate(
        history: _searchHistory,
        onSearch: (q) => _addSearchHistory(q),
        onClearHistory: _clearSearchHistory,
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_variant == 'B') return _buildVariantB();
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: BrokaColors.headerGradColors,
              begin: Alignment.topCenter, end: Alignment.bottomCenter)),
        child: SafeArea(child: Column(children: [
          _buildHeader(),
          if (_showFilters) _buildFilterPanel(),
          // Home-redesign brief, both rounds (2026-08-16, 2026-08-17): the
          // Goods/Traders toggle, the permanent location row, the Trending
          // grid, and the Live Auctions carousel are all gone from here -
          // Traders/Trending/Auctions are rail destinations that navigate
          // to their own screens (see _buildDiscoveryRail), not Home
          // content blocks. Location detection itself is untouched - this
          // is a display/composition change, not a functionality removal.
          _Entrance(delay: const Duration(milliseconds: 0), child: _buildDiscoveryRail()),
          _Entrance(delay: const Duration(milliseconds: 60), child: _buildZenoCompactCta()),
          if (_activeBuyAgentRequest != null)
            _Entrance(delay: const Duration(milliseconds: 100), child: _buildActiveBuyAgentSection()),
          Expanded(child: _buildFeed()),
        ])),
      ),
      bottomNavigationBar: _buildNav(),
    );
  }

  // Variant B: a single prominent search/prompt entry that opens
  // ai_assistant_screen.dart directly, instead of the full Chapter 11
  // layout above (Design Journal Volume 6, Ch.9/Ch.29).
  Widget _buildVariantB() {
    final searchCtrl = TextEditingController();
    void openAdvisor([String? query]) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => AiAssistantScreen(initialQuery: query),
      ));
    }
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: BrokaColors.headerGradColors,
              begin: Alignment.topCenter, end: Alignment.bottomCenter)),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const ZenoAvatar(size: 72, glow: true),
                const SizedBox(height: 20),
                const Text('What are you looking for?',
                    style: TextStyle(color: BrokaColors.textHigh, fontSize: 22, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Text("Tell Zeno what you need — budget, category, anything specific.",
                    style: TextStyle(color: BrokaColors.textLow, fontSize: 13),
                    textAlign: TextAlign.center),
                const SizedBox(height: 28),
                Container(
                  decoration: BoxDecoration(
                    color: BrokaColors.bgCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: BrokaColors.border),
                  ),
                  child: TextField(
                    controller: searchCtrl,
                    style: const TextStyle(color: BrokaColors.textHigh),
                    textInputAction: TextInputAction.search,
                    onSubmitted: openAdvisor,
                    decoration: InputDecoration(
                      hintText: 'e.g. a phone under KES 30,000...',
                      hintStyle: const TextStyle(color: BrokaColors.textLow),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_forward_rounded, color: BrokaColors.gold),
                        onPressed: () => openAdvisor(searchCtrl.text),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => openAdvisor(),
                  child: const Text('Or just start chatting →',
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _buildNav(),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  // Goods/Traders mode toggle removed (home-redesign brief, 2026-08-16) -
  // Home is exclusively the Goods marketplace now; Traders is a
  // _buildDiscoveryRail() destination that pushes its own screen instead
  // of swapping Home's body via MarketplaceState. MarketplaceState itself
  // is untouched (still registered in main.dart) in case anything else
  // ever needs it - just no longer read from this screen.

  Widget _buildHeader() => Container(
    padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: BrokaColors.border.withOpacity(0.5))),
    ),
    child: Row(children: [
      // BROKA brand mark - matches auth_screen.dart's _buildLogo() exactly
      // (same asset, size, corner radius, glow) so the icon that
      // identifies the app on the login screen also appears on Home,
      // which previously only ever showed the wordmark, no icon.
      Container(
        width: 44, height: 44,
        margin: const EdgeInsets.only(right: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          boxShadow: const [BrokaColors.glowGold],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Image.asset('assets/images/broka_icon.png', fit: BoxFit.cover),
        ),
      ),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 6, height: 6, decoration: const BoxDecoration(
              shape: BoxShape.circle, color: BrokaColors.neonGreen)),
          const SizedBox(width: 5),
          Text(_greetingText, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 12, letterSpacing: 0.3)),
        ]),
        const SizedBox(height: 3),
        ShaderMask(
          shaderCallback: (b) => const LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.neonBlue])
              .createShader(b),
          child: const Text('BROKA', style: TextStyle(
              color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900,
              letterSpacing: 2.0)),
        ),
      ])),
      // Filter toggle
      GestureDetector(
        onTap: () => setState(() => _showFilters = !_showFilters),
        child: Container(
          width: 38, height: 38, margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: _showFilters
                ? BrokaColors.gold.withOpacity(0.2) : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _showFilters
                ? BrokaColors.gold : BrokaColors.border),
          ),
          child: Icon(Icons.tune_rounded,
              color: _showFilters ? BrokaColors.gold : BrokaColors.textMid,
              size: 18),
        ),
      ),
      // Search
      GestureDetector(
        onTap: _openSearch,
        child: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: BrokaColors.border),
          ),
          child: const Icon(Icons.search_rounded,
              color: BrokaColors.textMid, size: 20),
        ),
      ),
    ]),
  );

  // Standalone location row removed (home-redesign brief §7/§8, 2026-08-16).
  // _detectLocation()/_locationLabel/_gettingLocation methods/fields are
  // still here unchanged, just no longer auto-triggered by Home (see
  // initState's own comment, final polish pass 2026-08-19) - nothing in
  // this file currently reads _locationLabel on screen, and that's fine:
  // it's dormant, ready plumbing for a real "near me" filter or similar,
  // not dead code to delete.

  // ── Filter Panel ──────────────────────────────────────────────────────────

  Widget _buildFilterPanel() => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    decoration: BoxDecoration(
      color: BrokaColors.bgMid,
      border: Border(bottom: BorderSide(color: BrokaColors.border)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.attach_money_rounded, color: BrokaColors.neonGreen, size: 16),
        const SizedBox(width: 6),
        const Text('Max Price', style: TextStyle(
            color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w600)),
        const Spacer(),
        Text(_formatPrice(_priceFilter), style: const TextStyle(
            color: BrokaColors.neonGreen, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
      SliderTheme(
        data: SliderThemeData(
          activeTrackColor: BrokaColors.gold,
          inactiveTrackColor: BrokaColors.border,
          thumbColor: BrokaColors.gold,
          overlayColor: BrokaColors.gold.withOpacity(0.15),
          trackHeight: 3,
        ),
        child: Slider(
          value: _priceFilter,
          min: 0,
          max: _maxPrice,
          divisions: 50,
          onChanged: (v) => setState(() => _priceFilter = v),
          onChangeEnd: (_) => setState(() => _committedPriceFilter = _priceFilter),
        ),
      ),
      Row(children: [
        const Text('KES 0', style: TextStyle(color: BrokaColors.textLow, fontSize: 10)),
        const Spacer(),
        Text(_formatPrice(_maxPrice),
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        const Icon(Icons.location_on_rounded, color: BrokaColors.neonBlue, size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: GestureDetector(
            onTap: () {
              showDialog(context: context, builder: (ctx) => _LocationFilterDialog(
                current: _locationFilter,
                onSet: (v) {
                  setState(() => _locationFilter = v?.trim().isEmpty == true ? null : v);
                },
              ));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _locationFilter != null
                    ? BrokaColors.neonBlue : BrokaColors.border),
              ),
              child: Text(
                _locationFilter ?? 'All locations',
                style: TextStyle(
                    color: _locationFilter != null
                        ? BrokaColors.neonBlue : BrokaColors.textLow,
                    fontSize: 12),
              ),
            ),
          ),
        ),
        if (_locationFilter != null) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => setState(() => _locationFilter = null),
            child: const Icon(Icons.close_rounded,
                color: BrokaColors.textMid, size: 16),
          ),
        ],
      ]),
      // FIX (redesign-guide audit): Global filters per Home Redesign Guide
      // §5/§20 are Location, Price range, Condition, Sort - this panel only
      // ever had the first two. Chips/dropdown match the same compact
      // style already used elsewhere in this panel rather than opening a
      // second, heavier filter surface for two extra fields.
      const SizedBox(height: 10),
      Row(children: [
        const Icon(Icons.tune_rounded, color: BrokaColors.gold, size: 14),
        const SizedBox(width: 6),
        const Text('Condition', style: TextStyle(
            color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w600)),
        const Spacer(),
        Wrap(spacing: 6, children: [
          _conditionChip(null, 'Any'),
          _conditionChip('new', 'New'),
          _conditionChip('used', 'Used'),
          _conditionChip('refurbished', 'Refurb.'),
        ]),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        const Icon(Icons.sort_rounded, color: BrokaColors.neonBlue, size: 14),
        const SizedBox(width: 6),
        const Text('Sort', style: TextStyle(
            color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w600)),
        const Spacer(),
        DropdownButton<String?>(
          value: _sortFilter,
          dropdownColor: BrokaColors.bgCard,
          underline: const SizedBox.shrink(),
          style: const TextStyle(color: BrokaColors.neonBlue, fontSize: 12, fontWeight: FontWeight.w600),
          items: const [
            DropdownMenuItem(value: null, child: Text('Newest')),
            DropdownMenuItem(value: 'price_low', child: Text('Price: low to high')),
            DropdownMenuItem(value: 'price_high', child: Text('Price: high to low')),
          ],
          onChanged: (v) => setState(() => _sortFilter = v),
        ),
      ]),
    ]),
  );

  Widget _conditionChip(String? value, String label) {
    final selected = _conditionFilter == value;
    return GestureDetector(
      onTap: () => setState(() => _conditionFilter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? BrokaColors.gold.withOpacity(0.18) : BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? BrokaColors.gold : BrokaColors.border),
        ),
        child: Text(label, style: TextStyle(
            color: selected ? BrokaColors.gold : BrokaColors.textMid,
            fontSize: 11.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }

  String _formatPrice(double v) {
    if (v >= 1000000) return 'KES ${(v/1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return 'KES ${(v/1000).toStringAsFixed(0)}K';
    return 'KES ${v.toStringAsFixed(0)}';
  }

  // ── Feed ──────────────────────────────────────────────────────────────────

  Widget _buildFeed() {
    // ProductGridView loads once in initState and exposes no public reload
    // method, so a ValueKey covering every input that should trigger a
    // refetch is the supported way to force one: changing the key remounts
    // fresh state, matching the old per-filter _loadListings() calls.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // FIX (redesign-guide audit, revised round 2 - 2026-08-17): "Popular
      // near you" implied two things that aren't actually true. "Near
      // you": _fetchListingsPage sends lat/lng but never max_km, and
      // listings/service.py only applies distance *filtering* when max_km
      // is provided alongside coordinates (grepped directly) - without it,
      // lat/lng only annotates each result with a distance_km value, it
      // doesn't restrict the result set to nearby listings at all.
      // "Popular": with no sort selected this is the backend's default
      // order (newest first), not a popularity ranking.
      // Final HomeScreen polish pass (2026-08-19, product review): "Discover
      // on Broka" made no false claim, but it also didn't say anything -
      // renamed to "Fresh on Broka," true for the same reason as above
      // (default order is newest-first) and it actually communicates that.
      // Still leaves room for a real recommendation engine later without
      // needing another label change - do NOT rename this to "Recommended
      // for you" / "Popular near you" / "Trending near you" until the
      // backend genuinely computes that signal (no browsing-history-based
      // ranking exists anywhere yet) - never fabricate personalization or
      // geographic relevance the app doesn't actually have.
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text('Fresh on Broka', style: TextStyle(
            color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.bold)),
      ),
      Expanded(
        child: ProductGridView(
          key: ValueKey('goods|$_committedPriceFilter|$_locationFilter|$_conditionFilter|$_sortFilter|$_feedRefreshNonce'),
          fetchPage: _fetchListingsPage,
          onTapItem: (item) {
            Navigator.pushNamed(context, '/product', arguments: {'listingId': (item as BrokaListing).id}).then((_) {
              if (mounted) setState(() => _feedRefreshNonce++);
            });
          },
          emptyStateBuilder: (_) => _emptyState(),
          onViewStore: (storeId, storeSlug) =>
              Navigator.pushNamed(context, '/store-view', arguments: {'storeId': storeId}),
        ),
      ),
    ]);
  }

  // Home-redesign brief round 3 (2026-08-18): added a tappable Sell CTA -
  // this already avoided a blank screen (icon + message existed before),
  // but had no actual next action for the user to take.
  Widget _emptyState() => Center(child: Column(
    mainAxisSize: MainAxisSize.min, children: [
    const Text('📦', style: TextStyle(fontSize: 48)),
    const SizedBox(height: 12),
    const Text('No listings yet', style: TextStyle(color: BrokaColors.textMid)),
    const SizedBox(height: 4),
    const Text('Be the first to post!',
        style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
    const SizedBox(height: 14),
    GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/sell'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text('+ Sell something',
            style: TextStyle(color: BrokaColors.bg, fontWeight: FontWeight.w700, fontSize: 13)),
      ),
    ),
  ]));

  // ── Bottom Nav ────────────────────────────────────────────────────────────

  Widget _buildNav() => Container(
    decoration: BoxDecoration(
      color: BrokaColors.bgMid,
      border: const Border(top: BorderSide(color: BrokaColors.border)),
    ),
    child: SafeArea(top: false, child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(_navItems.length, (i) {
          final item = _navItems[i];
          final selected = _navIndex == i;
          return GestureDetector(
            onTap: () => _onNav(i),
            behavior: HitTestBehavior.opaque,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              item['label'] == 'Zeno'
                  ? ZenoAvatar(size: 24, selected: selected, glow: selected)
                  : Icon(item['icon'] as IconData,
                      size: 24,
                      color: selected ? BrokaColors.gold : BrokaColors.textLow),
              const SizedBox(height: 3),
              Text(item['label'] as String,
                  style: TextStyle(
                      fontSize: 10,
                      color: selected ? BrokaColors.gold : BrokaColors.textLow,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
            ]),
          );
        }),
      ),
    )),
  );
}

// ── Location Filter Dialog ────────────────────────────────────────────────────
class _LocationFilterDialog extends StatefulWidget {
  final String? current;
  final ValueChanged<String?> onSet;
  const _LocationFilterDialog({required this.current, required this.onSet});

  @override
  State<_LocationFilterDialog> createState() => _LocationFilterDialogState();
}

class _LocationFilterDialogState extends State<_LocationFilterDialog> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.current ?? '');
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: BrokaColors.bgMid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: BrokaColors.border)),
      title: const Text('Filter by Location',
          style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
      content: TextField(
        controller: _ctrl,
        style: const TextStyle(color: BrokaColors.textHigh),
        decoration: const InputDecoration(
          hintText: 'e.g. Kisumu, Nairobi, Siaya',
          prefixIcon: Icon(Icons.location_on_rounded,
              color: BrokaColors.neonBlue, size: 18),
        ),
        onSubmitted: (v) { widget.onSet(v.isEmpty ? null : v); Navigator.pop(context); },
      ),
      actions: [
            IconButton(
              tooltip: 'Seller Dashboard',
              icon: const Icon(Icons.dashboard_rounded, color: BrokaColors.gold),
              onPressed: () => Navigator.pushNamed(context, '/seller-dashboard'),
            ),
        TextButton(
          onPressed: () { widget.onSet(null); Navigator.pop(context); },
          child: const Text('Clear', style: TextStyle(color: BrokaColors.textMid)),
        ),
        ElevatedButton(
          onPressed: () { widget.onSet(_ctrl.text.isEmpty ? null : _ctrl.text);
            Navigator.pop(context); },
          style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.gold,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

// ── Search Delegate with History ──────────────────────────────────────────────
// Heuristic-only, deliberately conservative: a plain product name ("iPhone
// 13") should never get swept into this, only text that reads like a
// buyer describing a specific need in their own words (Design v2 §4:
// "Natural buying request -> Zeno intent extraction"). Length plus an
// intent/budget signal word, or a 4+ digit number (a KES price mentioned
// inline, e.g. "under 30000") is enough to *offer* the handoff - it never
// blocks or replaces plain listing search, which still runs regardless.
bool _looksLikeBuyingRequest(String q) {
  final words = q.trim().split(RegExp(r'\s+'));
  if (words.length < 5) return false;
  final lower = q.toLowerCase();
  const signals = [
    'under', 'below', 'less than', 'around', 'budget', 'looking for',
    'need a', 'need an', 'want a', 'want an', 'find me', 'within', 'near me',
  ];
  return signals.any((s) => lower.contains(s)) || RegExp(r'\d{4,}').hasMatch(q);
}

enum _SearchMode { listings, traders }

class _ListingSearchDelegate extends SearchDelegate<String> {
  final List<String> history;
  final ValueChanged<String> onSearch;
  final VoidCallback onClearHistory;
  // FIX (redesign-guide audit): this delegate is named/labelled as
  // listing search ("Search listings, traders, locations...") but
  // previously only ever called ApiService.searchUsers - product search
  // from Home's search icon did not exist at all, despite both design
  // docs calling out Home search as one of the most important elements
  // and giving product-search examples explicitly. Now searches listings
  // by default (the marketplace's actual primary content) with trader
  // search kept one tap away via the mode toggle below, rather than
  // removed.
  _SearchMode _mode = _SearchMode.listings;
  List<BrokaListing> _listingResults = [];
  List<Map<String, dynamic>> _traderResults = [];
  bool _loading = false;
  Timer? _debounce;

  _ListingSearchDelegate({
    required this.history,
    required this.onSearch,
    required this.onClearHistory,
  });

  @override
  String get searchFieldLabel => 'Search listings, traders, locations...';

  @override
  ThemeData appBarTheme(BuildContext context) => Theme.of(context).copyWith(
    appBarTheme: const AppBarTheme(backgroundColor: BrokaColors.bgCard),
    inputDecorationTheme: const InputDecorationTheme(
        hintStyle: TextStyle(color: BrokaColors.textLow), border: InputBorder.none),
    textTheme: const TextTheme(
        titleLarge: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
  );

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(icon: const Icon(Icons.clear, color: BrokaColors.textMid),
          onPressed: () { query = ''; showSuggestions(context); }),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back_ios_new_rounded,
        color: BrokaColors.textMid, size: 18),
    onPressed: () => close(context, ''));

  @override
  Widget buildResults(BuildContext context) {
    onSearch(query);
    return _buildBody(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.isEmpty) return _buildHistory(context);
    _debounce?.cancel();
    _loading = true;
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final q = query.trim();
      try {
        final results = await Future.wait([
          listingsRepository.getListings(search: q, limit: 24),
          ApiService.searchUsers(q),
        ]);
        final listingsResult = results[0] as Result<List<BrokaListing>>;
        _listingResults = listingsResult.fold(
          onSuccess: (items) => items, onFailure: (_, __) => <BrokaListing>[],
        );
        _traderResults = (results[1] as List).cast<Map<String, dynamic>>();
      } catch (_) {
        _listingResults = [];
        _traderResults = [];
      }
      _loading = false;
      showResults(context);
    });
    return _buildBody(context);
  }

  Widget _buildHistory(BuildContext context) {
    if (history.isEmpty) {
      return Container(color: BrokaColors.bg,
        child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.search_rounded, size: 48, color: BrokaColors.textLow),
          SizedBox(height: 12),
          Text('Search for listings, traders, or locations',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 14),
              textAlign: TextAlign.center),
        ])));
    }
    return Container(color: BrokaColors.bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(children: [
          const Text('RECENT SEARCHES', style: TextStyle(
              color: BrokaColors.textLow, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          const Spacer(),
          GestureDetector(
            onTap: () { onClearHistory(); showSuggestions(context); },
            child: const Text('Clear', style: TextStyle(
                color: BrokaColors.gold, fontSize: 12)),
          ),
        ]),
      ),
      Expanded(child: ListView.builder(
        itemCount: history.length,
        itemBuilder: (_, i) => ListTile(
          leading: const Icon(Icons.history_rounded,
              color: BrokaColors.textLow, size: 18),
          title: Text(history[i], style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 14)),
          trailing: const Icon(Icons.north_west_rounded,
              color: BrokaColors.textLow, size: 14),
          onTap: () { query = history[i]; showResults(context); },
        ),
      )),
    ]));
  }

  Widget _modeChip(BuildContext context, String label, _SearchMode mode, int count) {
    final selected = _mode == mode;
    return GestureDetector(
      onTap: () { _mode = mode; showResults(context); },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? BrokaColors.neonBlue.withOpacity(0.18) : BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? BrokaColors.neonBlue : BrokaColors.border),
        ),
        child: Text(
          count > 0 ? '$label ($count)' : label,
          style: TextStyle(
            color: selected ? BrokaColors.neonBlue : BrokaColors.textMid,
            fontSize: 12.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final trimmed = query.trim();
    final showZenoBanner = trimmed.isNotEmpty && _looksLikeBuyingRequest(trimmed) && _mode == _SearchMode.listings;
    return Container(
      color: BrokaColors.bg,
      child: Column(children: [
        if (trimmed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(children: [
              _modeChip(context, 'Listings', _SearchMode.listings, _listingResults.length),
              const SizedBox(width: 8),
              _modeChip(context, 'Traders', _SearchMode.traders, _traderResults.length),
            ]),
          ),
        if (showZenoBanner)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  BrokaColors.neonPurple.withOpacity(0.20),
                  BrokaColors.neonBlue.withOpacity(0.12),
                ]),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.35)),
              ),
              child: Row(children: [
                const ZenoAvatar(size: 30, glow: true),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('This sounds like a specific request — want Zeno to find and negotiate it for you?',
                      style: TextStyle(color: BrokaColors.textHigh, fontSize: 12)),
                ),
                const SizedBox(width: 6),
                TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                  onPressed: () {
                    close(context, '');
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => BuyAgentHubScreen(initialQuery: trimmed),
                    ));
                  },
                  child: const Text('Ask Zeno', style: TextStyle(
                      color: BrokaColors.neonBlue, fontWeight: FontWeight.bold, fontSize: 12.5)),
                ),
              ]),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.neonBlue))
              : _mode == _SearchMode.listings
                  ? _buildListingResults(context)
                  : _buildTraderResults(context),
        ),
      ]),
    );
  }

  Widget _buildListingResults(BuildContext context) {
    if (_listingResults.isEmpty && query.isNotEmpty) {
      return Center(child: Text('No listings for "$query"',
          style: const TextStyle(color: BrokaColors.textMid)));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.68,
      ),
      itemCount: _listingResults.length,
      itemBuilder: (_, i) {
        final item = _listingResults[i];
        return ProductCard(
          item: item,
          onTap: () {
            close(context, item.id);
            Navigator.pushNamed(context, '/product', arguments: {'listingId': item.id});
          },
        );
      },
    );
  }

  Widget _buildTraderResults(BuildContext context) {
    if (_traderResults.isEmpty && query.isNotEmpty) {
      return Center(child: Text('No traders for "$query"',
          style: const TextStyle(color: BrokaColors.textMid)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _traderResults.length,
      itemBuilder: (_, i) {
        final u = _traderResults[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.border),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: CircleAvatar(
              backgroundColor: BrokaColors.gold.withOpacity(0.3),
              backgroundImage: (u['profile_photo'] as String?)?.isNotEmpty == true
                  ? MemoryImage(base64Decode(u['profile_photo'] as String))
                  : null,
              child: (u['profile_photo'] as String?)?.isNotEmpty == true
                  ? null
                  : Text((u['name'] as String? ?? '?')[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
            title: Text(u['name'] ?? '', style: const TextStyle(
                color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
            subtitle: Row(children: [
              const Icon(Icons.star_rounded, size: 12, color: BrokaColors.gold),
              const SizedBox(width: 3),
              Text('${(u['rating'] as num?)?.toStringAsFixed(1) ?? '5.0'}  · ${u['completed_deals'] ?? 0} deals',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
            ]),
            trailing: u['is_verified'] == true
                ? const Icon(Icons.verified_rounded, color: BrokaColors.gold, size: 18)
                : null,
            onTap: () {
              close(context, u['id']?.toString() ?? '');
              Navigator.pushNamed(context, '/user-profile',
                  arguments: u['id']?.toString());
            },
          ),
        );
      },
    );
  }
}

// Home-redesign brief §5 (2026-08-16): one shared shape for every item in
// the unified discovery rail (real categories + Trending/Auctions/Traders),
// so all of them render with identical pill treatment - nothing reads as a
// bigger or differently-styled card than a category circle. isDestination
// (final polish pass, 2026-08-19) does NOT change that shape - it only
// flags the three non-category entries so _buildDiscoveryRail() can draw
// one thin divider ahead of them. The pill itself is identical either way.
class _RailItem {
  final String emoji;
  final String label;
  final List<Color> colors;
  final VoidCallback onTap;
  final bool isDestination;
  const _RailItem({
    required this.emoji,
    required this.label,
    required this.colors,
    required this.onTap,
    this.isDestination = false,
  });
}

// Home-redesign brief §21 ("Home screen entrance... fade/slide, staggered")
// - a small reusable one-shot fade+slide-in, not a full choreographed
// AnimationController per section. Deliberately simple: it fires once on
// first build via a delayed setState rather than a driven controller, so
// nothing here can leak a controller or need manual disposal bookkeeping
// across the several sections that use it.
class _Entrance extends StatefulWidget {
  final Widget child;
  final Duration delay;
  const _Entrance({required this.child, this.delay = Duration.zero});

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : const Offset(0, 0.04),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
