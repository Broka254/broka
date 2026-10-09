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
//
// Collapsing-scroll pass (2026-09-18): Home used to be a Column - a fixed
// header, rail and Zeno CTA, with the product feed squeezed into whatever
// Expanded space was left and scrolling inside its own ScrollController.
// That meant the marketplace only ever owned the bottom two-thirds of the
// screen no matter how far you scrolled, and two vertical scrollables sat
// in the same screen. Home is now ONE CustomScrollView: the header is a
// SliverPersistentHeader that collapses to a compact sticky search bar, the
// rail/Zeno/Buy Agent sections are ordinary slivers that scroll away, and
// the feed is ProductGridView in its new `sliver: true` mode, so the
// listings progressively inherit the screen. Pull-to-refresh moved up to
// the one scroll view (see _onRefresh + ProductGridController) and the
// bottom nav stays outside it, fixed. Background is the same
// ConstellationBackground the auth screens use, so Home and sign-in read as
// one app.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../core/utils/result.dart';
import '../utils/backend_time.dart';
import '../main.dart';
import '../services/last_screen_tracker.dart';
import '../services/api_service.dart';
import '../services/global_poller_service.dart';
import '../theme/motion.dart';
import '../utils/auth_gate.dart';
import '../utils/price_format.dart';
import '../widgets/constellation_background.dart';
import '../widgets/delivery_nudge.dart';
import '../widgets/product_grid_view.dart';
import '../widgets/zeno_avatar.dart';
import '../features/categories/data/repositories/categories_repository.dart';
import '../features/categories/domain/models/category.dart';
import '../features/categories/domain/category_visual.dart';
import '../features/discovery/domain/destination_visual.dart';
import '../features/categories/presentation/category_navigation.dart';
import '../features/categories/presentation/widgets/category_art_card.dart';
import '../features/trending/presentation/trending_screen.dart';
import '../features/auctions/domain/auctions_enabled.dart';
import '../features/safe_payment/payments_shown.dart';
import '../features/safe_payment/safe_payment.dart' show openEscrowServices;
import '../features/auctions/presentation/auction_house_screen.dart';
import 'zeno_screen.dart';
import '../features/zeno_assistant/zeno_session.dart';
import '../features/zeno_assistant/zeno_action_runner.dart';
import '../features/buy_agent/data/repositories/buy_agent_repository.dart';
import '../features/buy_agent/domain/models/buy_agent_request.dart';
import '../features/buy_agent/presentation/widgets/agent_motion.dart';
import 'ai_assistant_screen.dart';
import 'listing_search_screen.dart';
import '../features/traders/presentation/trader_list_screen.dart';
import '../features/stores/presentation/store_list_screen.dart';
import '../features/listings/domain/models/listing.dart' show BrokaListing;
import '../features/listings/data/repositories/listings_repository.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// Whether the category rail's "there's more" glide runs (see
  /// _playRailHint). Tests that measure where the rail's pills sit turn it
  /// off; home_rail_hint_test.dart covers the glide itself.
  @visibleForTesting
  static bool railHintEnabled = true;

  /// Once per app launch: a hint repeated on every return to Home stops
  /// being a hint and starts being the rail wandering off on its own.
  static bool _railHintShown = false;

  @visibleForTesting
  static void debugResetRailHint() => _railHintShown = false;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  int _navIndex = 0;
  // Dormant by design, not dead: see the "Standalone location row removed"
  // note further down. Kept as ready plumbing for a "near me" filter.
  // ignore: unused_field
  String? _locationLabel;
  // ignore: unused_field
  bool _gettingLocation = false;

  // The single vertical scroll owner for the whole screen (collapsing-scroll
  // pass, brief §3). Nothing below it scrolls vertically on its own - the
  // discovery rail is horizontal, and ProductGridView runs in sliver mode
  // precisely so it does not bring a second controller into this viewport.
  final ScrollController _scrollController = ScrollController();

  // Lets this screen's RefreshIndicator - which now lives above the whole
  // CustomScrollView rather than inside the grid - drive the feed's refetch
  // and await it.
  final ProductGridController _feedController = ProductGridController();

  // Filters. _priceFilter drives the slider UI live; _committedPriceFilter
  // is what the grid actually fetches against, updated only when the user
  // releases the slider so dragging doesn't refetch on every frame (matches
  // the old _loadListings-on-onChangeEnd behaviour).
  //
  // The slider's top end means "no limit", not "KES 5,000,000": it used to be
  // sent as max_price on every request, so with no filter touched Home hid
  // every car, plot and house priced above five million.
  final double _maxPrice = 5000000;
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
    {'icon': Icons.menu_rounded,           'label': 'Menu'},
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
    _railScrollController.addListener(_onRailScroll);
    _loadTopCategories();
    // _loadTrending()/_loadLiveAuctions() removed (home-redesign brief
    // round 2, 2026-08-17): Home no longer renders a Trending grid or a
    // Live Auctions carousel of its own (see _buildDiscoveryRail's own
    // note) - both are pure rail destinations now, each fetching its own
    // data only once TrendingScreen/AuctionHouseScreen actually opens.
    // Calling their APIs here was work Home paid for and never used.
    _loadActiveBuyAgentRequest();
    // The Zeno CTA's breathing glow and its rotating message now live inside
    // _ZenoCompactCta (bottom of this file) instead of an AnimationController
    // owned here. A controller at this level drove a ~4-frames-per-second
    // setState() over the ENTIRE HomeScreen - header, rail, and every
    // product card - for an effect confined to one 56px row (brief §7/§15).
  }

  @override
  void dispose() {
    _railHintTimer?.cancel();
    _railScrollController.removeListener(_onRailScroll);
    _railScrollController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // Pull-to-refresh for the whole screen (brief §16). Refreshes the feed and
  // the two other things Home actually shows, so a pull that visibly reloads
  // the listings also picks up a new category or a Buy Agent match rather
  // than leaving them stale.
  Future<void> _onRefresh() async {
    await Future.wait([
      _feedController.refresh(),
      _loadTopCategories(),
      _loadActiveBuyAgentRequest(),
    ]);
  }

  // The filter panel is a sliver below the header now, so opening it while
  // scrolled down would drop it somewhere off-screen. Returning to the top
  // keeps "tap tune -> see filters" true at any scroll position.
  void _toggleFilters() {
    setState(() => _showFilters = !_showFilters);
    if (_showFilters && _scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.animateTo(0,
          duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  final ScrollController _railScrollController = ScrollController();

  // ── "There's more" on the category rail (2026-09-26) ─────────────────────
  //
  // People were seeing the first five or six categories and not realising
  // the rail scrolls - Land, Services and the rest were a swipe away that
  // nobody made. The 2026-08-19 pass had removed a 56px auto-nudge for moving
  // on its own; this brings motion back in a form that shows the thing it is
  // pointing at: once per launch the rail glides far enough to bring about
  // two more categories into view, pauses, and glides home. A touch on the
  // rail ends it on the spot, it is skipped under reduced motion, and it
  // doesn't run when every category already fits. The chevron at the right
  // edge stays until the end of the rail has been seen, for anyone who
  // missed the glide.

  Timer? _railHintTimer;
  bool _railTouched = false;
  bool _railAtEnd = false;

  void _onRailScroll() {
    final c = _railScrollController;
    if (!c.hasClients) return;
    final atEnd = c.position.pixels >= c.position.maxScrollExtent - 4;
    if (atEnd != _railAtEnd && mounted) setState(() => _railAtEnd = atEnd);
  }

  void _scheduleRailHint() {
    if (!HomeScreen.railHintEnabled || HomeScreen._railHintShown || _railTouched) return;
    _railHintTimer?.cancel();
    // After Home has settled and the rail has faded in (_Entrance), so the
    // glide is something seen rather than part of the page arriving.
    _railHintTimer = Timer(const Duration(milliseconds: 900), _playRailHint);
  }

  Future<void> _playRailHint() async {
    if (!mounted || _railTouched || HomeScreen._railHintShown) return;
    if (BrokaMotion.reduced(context)) return;
    final c = _railScrollController;
    if (!c.hasClients) return;
    final max = c.position.maxScrollExtent;
    if (max <= 0) return; // every category already fits
    HomeScreen._railHintShown = true;
    // A card and the gap after it.
    final pill = _railCardWidth(context) + 10;
    final reveal = math.min(max, pill * 1.6);
    // animateTo's future completes when a drag interrupts it, too.
    await c.animateTo(reveal,
        duration: const Duration(milliseconds: 1100), curve: Curves.easeInOutCubic);
    if (!mounted || _railTouched) return;
    _railHintTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || _railTouched || !c.hasClients) return;
      c.animateTo(0, duration: const Duration(milliseconds: 900), curve: Curves.easeInOutCubic);
    });
  }

  /// The chevron: a page of rail further on.
  void _railForward() {
    final c = _railScrollController;
    if (!c.hasClients) return;
    _railTouched = true;
    final target = math.min(c.position.maxScrollExtent,
        c.position.pixels + c.position.viewportDimension * 0.7);
    c.animateTo(target, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
  }

  // ── Category carousel ─────────────────────────────────────────────────────

  Future<void> _loadTopCategories() async {
    final result = await categoriesRepository.getTopLevel();
    if (!mounted) return;
    result.fold(
      onSuccess: (data) {
        setState(() {
          _topCategories = data;
          _categoriesLoaded = true;
        });
        // The rail has to be laid out before it knows how far it scrolls.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _onRailScroll();
          _scheduleRailHint();
        });
      },
      // Previously silent (carousel just stayed empty/hidden) - which made
      // "categories table hasn't been seeded yet" indistinguishable from
      // "this is broken". _categoriesLoaded lets the carousel below tell
      // those two states apart without an alarming error box for what's
      // still a non-critical strip.
      onFailure: (_, __) => setState(() => _categoriesLoaded = true),
    );
  }

  // Zero-duration transition is Chapter 3's explicit, deliberate
  // requirement (re-confirmed in Ch.17 of the source spec) - not a missing
  // animation; category_navigation.dart owns it now that the Zone's types of
  // item and the directories open category screens too.
  void _openCategoryZone(Category category) => openCategoryZone(context, category);

  // Home-redesign brief §3-§6 (2026-08-16): categories, Trending, Auctions,
  // and Traders used to be visually split into three separate rows/areas
  // (a category-circle strip, a "Quick Access" chip row, and a Goods/
  // Traders mode toggle that swapped Home's entire body). All four were
  // unified into one horizontally-scrolling rail, one shape for every
  // item, with one thin divider between the last category and Trending
  // onward (final polish pass, 2026-08-19 - see isDestination on _RailItem).
  //
  // Photo cards (2026-10-08): the rail's circles of emoji became the
  // website's category cards - the category's picture, its name over it -
  // under a "Shop by category" line with "See all", which opens every
  // category as a grid (category_directory_screen.dart). Each category now
  // leads to its types of item, each type to a screen of its own with its
  // brands to filter by, so the first thing a buyer sees of a category is
  // what is in it. The destinations stay at the end of the same row, drawn
  // from their gradient and emoji in the same card frame.
  //
  // Still one row, so the feed keeps the top half of the screen
  // (home_collapsing_scroll_test.dart guards it): the cards are landscape
  // and compact, and the heading is one small line. The 2026-09-26 glide and
  // chevron are unchanged - a half-visible last card says "more" too, but a
  // first-time user still needs to see the row move once (see _playRailHint).
  //
  // Heights are derived from the text scale (brief §14/§28): the row used to
  // overflow on two-line labels at large text sizes when it was hardcoded.
  static double _railCardWidth(BuildContext context) =>
      _narrow(context) ? 112.0 : 122.0;

  Widget _buildDiscoveryRail() {
    final narrow = _narrow(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3);
    final cardWidth = _railCardWidth(context);
    // Two lines of name at the user's text size, above a picture that still
    // shows: 24px badge + two lines + padding, with room to spare at 1.0.
    final cardHeight = (narrow ? 84.0 : 88.0) + 24 * (textScale - 1);
    final labelSize = narrow ? 11.5 : 12.0;
    const railPadding = 8.0; // the ListView's own vertical padding, top + bottom

    if (_topCategories.isEmpty && !_categoriesLoaded) {
      return SizedBox(height: cardHeight + railPadding + _railHeadingHeight(textScale.toDouble()));
    }
    final items = <_RailItem>[
      // Straight from categoriesRepository.getTopLevel() - however many the
      // backend returns is however many render. No count, no slots, no index
      // -> visual mapping: each card asks the resolver for its own name.
      ..._topCategories.map((c) {
        final visual = CategoryVisuals.resolve(c.name);
        return _RailItem(
          emoji: visual.emoji, label: c.name,
          colors: visual.gradient,
          assetPath: visual.assetPath,
          onTap: () => _openCategoryZone(c),
        );
      }),
      // The four fixed destinations, from the same registry the screens they
      // open read their own title, icon and gradient from - so the card and
      // its destination cannot drift apart (they had: a pink 🔥 pill opened a
      // plain white-on-black AppBar with no trace of either).
      _RailItem(
        emoji: DestinationVisuals.trending.emoji,
        label: DestinationVisuals.trending.label,
        colors: DestinationVisuals.trending.gradient,
        isDestination: true,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TrendingScreen())),
      ),
      // Auctions are off for launch (kAuctionsEnabled): the Auction House
      // is still in the app, with nothing leading to it.
      if (kAuctionsEnabled)
        _RailItem(
          emoji: DestinationVisuals.auctions.emoji,
          label: DestinationVisuals.auctions.label,
          colors: DestinationVisuals.auctions.gradient,
          isDestination: true,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AuctionHouseScreen())),
        ),
      // Home-redesign brief §6: tapping Traders navigates to a dedicated
      // screen rather than filtering/replacing Home's own product grid.
      _RailItem(
        emoji: DestinationVisuals.traders.emoji,
        label: DestinationVisuals.traders.label,
        colors: DestinationVisuals.traders.gradient,
        isDestination: true,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TraderListScreen())),
      ),
      // Store feature, Phase 4 (spec §12/§21): same row, same card -
      // explicitly NOT a new Home section or grid.
      _RailItem(
        emoji: DestinationVisuals.stores.emoji,
        label: DestinationVisuals.stores.label,
        colors: DestinationVisuals.stores.gradient,
        isDestination: true,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StoreListScreen())),
      ),
    ];
    // Right-edge fade is a ShaderMask over the ListView's own viewport
    // (BlendMode.dstIn fading source alpha near the right edge) rather
    // than a painted overlay in a guessed background color.
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _railHeading(textScale.toDouble()),
      SizedBox(
        height: cardHeight + railPadding,
        child: Stack(children: [
          // A finger on the rail ends the "there's more" glide at once.
          Listener(
            onPointerDown: (_) {
              _railTouched = true;
              _railHintTimer?.cancel();
            },
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.centerRight,
                end: Alignment.centerLeft,
                colors: [Colors.transparent, Colors.white],
                stops: [0.0, 0.06],
              ).createShader(bounds),
              child: ListView.builder(
                key: const Key('home-category-rail'),
                controller: _railScrollController,
                scrollDirection: Axis.horizontal,
                // 16 puts the first card's edge on the same content edge as
                // the search bar, the Zeno CTA, the Fresh heading and the
                // grid (brief §16); each card carries a 10px gap after it.
                padding: const EdgeInsets.fromLTRB(16, railPadding / 2, 6, railPadding / 2),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  // Divider sits only at the one category→destination boundary,
                  // never between two categories or between two destinations.
                  final showDivider = i > 0 && items[i].isDestination && !items[i - 1].isDestination;
                  final card = Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: CategoryArtCard(
                      key: Key('home-rail-card-${items[i].label}'),
                      label: items[i].label,
                      emoji: items[i].emoji,
                      gradient: items[i].colors,
                      assetPath: items[i].assetPath,
                      width: cardWidth,
                      height: cardHeight,
                      labelSize: labelSize,
                      onTap: items[i].onTap,
                    ),
                  );
                  if (!showDivider) return card;
                  return Row(mainAxisSize: MainAxisSize.min, children: [
                    _railDivider(cardHeight),
                    card,
                  ]);
                },
              ),
            ),
          ),
          // "More this way", level with the cards, until the end of the
          // rail has been seen.
          Positioned(
            right: 6,
            top: railPadding / 2 + cardHeight / 2 - 14,
            child: IgnorePointer(
              ignoring: _railAtEnd,
              child: AnimatedOpacity(
                opacity: _railAtEnd ? 0 : 1,
                duration: const Duration(milliseconds: 220),
                child: Semantics(
                  button: true,
                  label: 'More categories',
                  child: GestureDetector(
                    key: const Key('home-rail-more'),
                    onTap: _railForward,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: BrokaColors.bgCard.withOpacity(0.92),
                        border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.5)),
                        boxShadow: [
                          BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.25), blurRadius: 8),
                        ],
                      ),
                      child: const Icon(Icons.chevron_right_rounded,
                          size: 20, color: BrokaColors.textHigh),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    ]);
  }

  static double _railHeadingHeight(double textScale) => 13 * 1.2 * textScale + 6;

  /// "Shop by category" and the way to every category at once.
  Widget _railHeading(double textScale) => SizedBox(
        height: _railHeadingHeight(textScale),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(children: [
            const Expanded(
              child: Text('Shop by category',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.1)),
            ),
            if (_topCategories.isNotEmpty)
              GestureDetector(
                key: const Key('home-categories-see-all'),
                behavior: HitTestBehavior.opaque,
                onTap: () => openAllCategories(context, _topCategories),
                child: const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Text('See all ›',
                      style: TextStyle(
                          color: BrokaColors.gold,
                          fontSize: 12.5,
                          height: 1.2,
                          fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
        ),
      );

  // Final HomeScreen polish pass (2026-08-19): the one visual cue that
  // categories and Trending/Auctions/Traders aren't quite the same kind of
  // thing - a plain hairline, not a card border, a label, or a new row.
  Widget _railDivider(double cardHeight) => Container(
        width: 1,
        height: cardHeight * 0.7,
        margin: const EdgeInsets.only(right: 10),
        color: BrokaColors.textLow,
      );

  // Category-alignment pass (2026-09-18): _categoryEmojiMap and the
  // _categoryEmoji() lookup that used to sit here are gone. They were the
  // most complete of the app's six category tables and still a duplicate -
  // paired with BrokaColors.zoneGradients, which was keyed the same way and
  // had already drifted from it. Both now live in
  // features/categories/domain/category_visual.dart, which CategoryZoneScreen,
  // ProductCard, the Listing model, Boost and Inbox all read from too, so the
  // rail's icon and the Zone's icon can no longer disagree.


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

  // Opens Zeno in buying-agent mode: a conversation, not a form.
  //
  // This used to open BuyAgentHubScreen, a three-stage wizard - one
  // sentence in, a confirmation card, a result grid. Typing "iPhone"
  // searched for the word "iPhone" and returned "0 results found", because
  // the flow had no way to ask which iPhone, how much RAM, or what budget,
  // and no way to say what it nearly found. Zeno now asks first and
  // reports back in conversation (see zeno_screen.dart's header).
  //
  // The watch card is reloaded on the way back: Zeno can start a watch or
  // replace the current one, and the card used to keep showing the old
  // one until the next pull-to-refresh.
  void _openBuyAgentHub() => Navigator.push(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: ZenoActionRunner.buyingAgentRoute),
          builder: (_) => const ZenoScreen(mode: ZenoMode.buyingAgent),
        ),
      ).then((_) {
        if (mounted) _loadActiveBuyAgentRequest();
      });

  // ── Zeno Buying Agent (Home Redesign Guide §10, Design v2 §14) ────────────
  // Home-redesign brief §9 (2026-08-16): the previous card (avatar +
  // headline + description + full-width button, ~180px tall) is replaced
  // with a single compact row, targeting ~50-70px, since Zeno already has
  // its own bottom-nav destination and doesn't need a second large
  // promotional block on Home. That compact row is unchanged in spirit and
  // size; collapsing-scroll pass (2026-09-18, brief §6/§7) only moved its
  // animation into _ZenoCompactCta at the bottom of this file, where the
  // breathing glow and the rotating message rebuild 56px instead of the
  // whole screen. The large promotional card is NOT coming back.
  Widget _buildZenoCompactCta() => _ZenoCompactCta(onTap: _openBuyAgentHub);

  // Stops the buyer's standing watch. Until this existed nothing in the app
  // could: Zeno told a buyer with a watch running to "cancel that one from
  // the home screen", and this card was all the home screen had - so a
  // buyer's first watch was the only one they would ever get.
  Future<void> _stopWatching(BuyAgentRequest req) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        title: const Text('Stop watching?',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
        content: Text(
          "Zeno will stop looking for ${req.category} under ${formatKes(req.maxPrice)} "
          "and won't tell you about new matches.",
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 13.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep watching', style: TextStyle(color: BrokaColors.textMid))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stop', style: TextStyle(color: BrokaColors.gold))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await buyAgentRepository.cancelRequest();
    if (!mounted) return;
    // NO_ACTIVE_REQUEST: already stopped elsewhere, so the card goes too.
    final stopped = result.isSuccess &&
        (result.data['status'] == 'SUCCESS' || result.data['error_code'] == 'NO_ACTIVE_REQUEST');
    if (stopped) {
      setState(() => _activeBuyAgentRequest = null);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't stop that watch just now. Try again in a moment."),
      ));
    }
  }

  String? _watchTimeLeft(BuyAgentRequest req) {
    final days = req.daysLeft(DateTime.now());
    if (days == null || days <= 0) return null;
    return days == 1 ? 'Last day of watching' : '$days days left';
  }

  // "Zeno is watching for you" (Home Redesign Guide §13).
  Widget _buildActiveBuyAgentSection() {
    final req = _activeBuyAgentRequest!;
    // hasMatches, not status == 'matched': "0 matches found!" was reachable
    // whenever the two ever disagreed.
    final matched = req.hasMatches;
    final tone = matched ? BrokaColors.success : BrokaColors.neonCyan;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GestureDetector(
        onTap: _openBuyAgentHub,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [tone.withOpacity(0.10), BrokaColors.bgCard],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: tone.withOpacity(0.35)),
          ),
          child: Row(children: [
            // A watch is Zeno working while the buyer isn't: the same
            // turning ring and radar pings as the agent's own screen, so it
            // reads as live rather than as a saved search.
            const AgentOrb(size: 28, pings: true),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Zeno is watching for you',
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
                const SizedBox(height: 2),
                Text('${req.category} · Under ${formatKes(req.maxPrice)}',
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  matched
                      ? '${req.matchCount} match${req.matchCount == 1 ? '' : 'es'} found!'
                      : 'Still searching…',
                  style: TextStyle(color: matched ? BrokaColors.success : BrokaColors.textMid, fontSize: 11.5),
                ),
                // Watches end by themselves (BUY_AGENT_WATCH_DAYS); say when,
                // so one doesn't just vanish from Home.
                if (_watchTimeLeft(req) case final left?)
                  Text(left, style: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5)),
              ]),
            ),
            IconButton(
              tooltip: 'Stop watching',
              onPressed: () => _stopWatching(req),
              icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 18),
              visualDensity: VisualDensity.compact,
            ),
            const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid, size: 20),
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
      maxPrice: _priceLimited ? _committedPriceFilter : null,
      condition: _conditionFilter,
      sort: _sortFilter,
      location: _locationFilter,
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    // A failure is thrown, not turned into an empty page. As an empty page it
    // showed "No listings yet - be the first to post!" to anyone offline, and
    // an empty page 2 also told the grid there was nothing more to load, so a
    // dropped request ended the feed for good. ProductGridView shows a
    // thrown error with a Retry button.
    final data = switch (result) {
      Success(:final data) => data,
      Failure(:final message) => throw HomeFeedFailure(message),
    };
    // Every order but the default is one the buyer picked - price, newest -
    // and pinning featured listings above it broke that order on every page
    // ("low to high" opened on a boosted KES 80,000 phone).
    if (_sortFilter != null) return data;
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

  // Dormant by design - see the "Standalone location row removed" note.
  // ignore: unused_element
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
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
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
    'to open your menu',
  ];

  Future<void> _onNav(int i) async {
    if (i == 0) {
      setState(() => _navIndex = 0);
      return;
    }
    // v6.1: guests can browse Home freely, but Inbox/Sell/Zeno/Menu all
    // require an account. requireAuth resumes straight into the tapped
    // destination on success instead of dropping back to Home.
    final authed = await requireAuth(context, reason: _navReasons[i]);
    if (!authed) return;
    if (!mounted) return;
    setState(() => _navIndex = i);
    final routes = ['', '/inbox', '/sell', '/zeno', '/menu'];
    Navigator.pushNamed(context, routes[i]).then((_) {
      if (mounted) setState(() { _navIndex = 0; _feedRefreshNonce++; });
      // Back from reading: bring the Inbox badge down now, not at the
      // poller's next tick.
      unawaited(GlobalPollerService.instance.catchUp());
    });
  }

  Future<void> _talkToZeno() async {
    final authed = await requireAuth(context, reason: _navReasons[3]);
    if (!authed || !mounted) return;
    // Straight into voice, over Home, the way a phone's assistant opens
    // over whatever is on screen: Zeno's session (zeno_session.dart), grown
    // out of the Zeno tab. What is said lands in the Zeno tab's
    // conversation. Without a session - never in the app - the Zeno tab
    // opens in voice mode instead.
    final session = ZenoSession.maybeOf(context);
    if (session != null) {
      HapticFeedback.mediumImpact();
      session.start(from: const Alignment(0.4, 0.97));
      return;
    }
    setState(() => _navIndex = 3);
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: '/zeno'),
        builder: (_) => const ZenoScreen(startInVoice: true),
      ),
    ).then((_) {
      if (mounted) setState(() { _navIndex = 0; _feedRefreshNonce++; });
    });
  }

  // Listings only. Finding a trader is the Traders screen's search - see
  // listing_search_screen.dart's header for what the old search did wrong.
  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ListingSearchScreen()),
    );
  }

  /// Whether the price slider is below its top end - the only time it is a
  /// filter at all (see _maxPrice).
  bool get _priceLimited => _committedPriceFilter < _maxPrice;

  /// Any filter narrowing the feed, so the header can say so while the panel
  /// is closed. Without it, a condition picked yesterday silently hid most of
  /// the marketplace with nothing on screen to explain why.
  bool get _filtersActive =>
      _priceLimited ||
      _locationFilter != null ||
      _conditionFilter != null ||
      _sortFilter != null;

  void _resetFilters() => setState(() {
        _priceFilter = _maxPrice;
        _committedPriceFilter = _maxPrice;
        _locationFilter = null;
        _conditionFilter = null;
        _sortFilter = null;
      });

  // ── Build ─────────────────────────────────────────────────────────────────

  // One scroll owner, top to bottom (brief §1/§3/§18).
  //
  // Everything that used to sit in a fixed Column above the feed is a sliver
  // now, in the same viewport as the listings, so scrolling moves the header,
  // the rail and Zeno up and off while the grid takes over the screen. The
  // only thing that survives a full scroll is the collapsed header's compact
  // search bar (~58px), which brief §2/§10 explicitly allows - and the bottom
  // nav, which is outside the scroll view entirely (brief §11).
  @override
  Widget build(BuildContext context) {
    if (_variant == 'B') return _buildVariantB();
    final media = MediaQuery.of(context);
    // Header geometry is computed here, where there IS a context, and handed
    // to the delegate: SliverPersistentHeaderDelegate.maxExtent has no
    // context of its own, and a header sized without knowing the device's
    // text scale is exactly how a header overflows on someone's phone
    // (brief §14/§27).
    final textScale = media.textScaler.scale(1.0).clamp(1.0, 1.35);
    final narrow = _narrow(context);

    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // Same constellation field as auth_screen.dart, so signing in and
      // landing on Home read as one continuous surface (brief §9). It owns
      // its own controller and paints inside RepaintBoundaries, so the mesh
      // animating never rebuilds or repaints the feed scrolling over it.
      body: ConstellationBackground(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _onRefresh,
            color: BrokaColors.gold,
            backgroundColor: BrokaColors.bgCard,
            // Clear of the pinned header so the spinner isn't half-hidden
            // behind the collapsed search bar.
            displacement: 72,
            child: CustomScrollView(
              controller: _scrollController,
              // Keeps the pull-to-refresh gesture alive even when the feed
              // is short enough not to overflow the screen (an empty
              // marketplace still has to be refreshable).
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _HomeHeaderDelegate(
                    greeting: _greetingText,
                    filtersOpen: _showFilters,
                    filtersActive: _filtersActive,
                    onToggleFilters: _toggleFilters,
                    onOpenSearch: _openSearch,
                    narrow: narrow,
                    textScale: textScale.toDouble(),
                  ),
                ),
                if (_showFilters)
                  SliverToBoxAdapter(child: _buildFilterPanel()),
                // Home-redesign brief, both rounds (2026-08-16, 2026-08-17):
                // the Goods/Traders toggle, the permanent location row, the
                // Trending grid, and the Live Auctions carousel are all gone
                // from here - Traders/Trending/Auctions are rail destinations
                // that navigate to their own screens (see
                // _buildDiscoveryRail), not Home content blocks. Location
                // detection itself is untouched - this is a display
                // composition change, not a functionality removal.
                SliverToBoxAdapter(
                  child: _Entrance(
                      delay: const Duration(milliseconds: 0),
                      child: _buildDiscoveryRail()),
                ),
                SliverToBoxAdapter(
                  child: _Entrance(
                      delay: const Duration(milliseconds: 60),
                      child: _buildZenoCompactCta()),
                ),
                // Brief §12: the active Buy Agent section scrolls with
                // everything else rather than claiming a permanent band of
                // the screen.
                if (_activeBuyAgentRequest != null)
                  SliverToBoxAdapter(
                    child: _Entrance(
                        delay: const Duration(milliseconds: 100),
                        child: _buildActiveBuyAgentSection()),
                  ),
                // Can't be notified - said where it's seen, with what it
                // costs (delivery_nudge.dart). Signed in only: a guest has
                // nobody writing to them yet.
                if (ApiService.currentUserId != null)
                  const SliverToBoxAdapter(child: DeliveryNudge()),
                SliverToBoxAdapter(child: _buildFeedHeading()),
                _buildFeedSliver(),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ],
            ),
          ),
        ),
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
  //
  // Collapsing-scroll pass (2026-09-18, brief §2): the header is no longer a
  // Container at the top of a Column - it is _HomeHeaderDelegate at the
  // bottom of this file, driven by a SliverPersistentHeader. It carries the
  // same two controls it always had (the filter toggle and the search
  // entry), the same brand mark, and the same greeting; what is new is that
  // it CONTRACTS as you scroll instead of standing still forever. Built as a
  // sliver rather than a Transform on a fixed box so the scroll view itself
  // owns the collapse (brief §2's explicit requirement) and pull-to-refresh
  // and pagination keep working through it.

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
    decoration: const BoxDecoration(
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
        Text(_priceFilter >= _maxPrice ? 'Any price' : _formatPrice(_priceFilter),
            style: const TextStyle(
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
        const Text('KES 0', style: TextStyle(color: BrokaColors.textMid, fontSize: 10)),
        const Spacer(),
        Text('${_formatPrice(_maxPrice)}+',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
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
          // null is the backend's ranking (seller trust, completion rate,
          // freshness - listings/service.py), which this used to label
          // "Newest". Picking "Newest" therefore changed nothing; 'recent'
          // is the backend's strictly-newest order.
          items: const [
            DropdownMenuItem(value: null, child: Text('Top ranked')),
            DropdownMenuItem(value: 'recent', child: Text('Newest')),
            DropdownMenuItem(value: 'price_low', child: Text('Price: low to high')),
            DropdownMenuItem(value: 'price_high', child: Text('Price: high to low')),
          ],
          onChanged: (v) => setState(() => _sortFilter = v),
        ),
      ]),
      if (_filtersActive)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _resetFilters,
            icon: const Icon(Icons.restart_alt_rounded, size: 16, color: BrokaColors.gold),
            label: const Text('Reset filters',
                style: TextStyle(color: BrokaColors.gold, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
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

  // Brief §5: the K/M ladder that used to live here is gone - the slider
  // read "KES 5.0M" for a max of 5,000,000 and "KES 30K" for anything
  // between 29,500 and 30,499, which is not a price filter a buyer can aim
  // with. utils/price_format.dart is the one implementation now, shared with
  // ProductCard and BrokaListing.priceFormatted.
  String _formatPrice(double v) => formatKes(v);

  // ── Feed ──────────────────────────────────────────────────────────────────

  // Heading and grid are two separate slivers now (they used to be a Column
  // whose second child was an Expanded ProductGridView with its own
  // scrollable). "Fresh on Broka" therefore scrolls away with everything
  // above it, and the grid below shares the screen's one viewport.
  Widget _buildFeedHeading() => Padding(
        // FIX (redesign-guide audit, revised round 2 - 2026-08-17): "Popular
        // near you" implied two things that aren't actually true. "Near
        // you": _fetchListingsPage sends lat/lng but never max_km, and
        // listings/service.py only applies distance *filtering* when max_km
        // is provided alongside coordinates (grepped directly) - without it,
        // lat/lng only annotates each result with a distance_km value, it
        // doesn't restrict the result set to nearby listings at all.
        // "Popular": with no sort selected this is the backend's default
        // order (newest first), not a popularity ranking.
        // Final HomeScreen polish pass (2026-08-19, product review):
        // "Discover on Broka" made no false claim, but it also didn't say
        // anything - renamed to "Fresh on Broka," true for the same reason
        // as above (default order is newest-first) and it actually
        // communicates that. Still leaves room for a real recommendation
        // engine later without needing another label change - do NOT rename
        // this to "Recommended for you" / "Popular near you" / "Trending
        // near you" until the backend genuinely computes that signal (no
        // browsing-history-based ranking exists anywhere yet) - never
        // fabricate personalization or geographic relevance the app doesn't
        // actually have.
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        child: Row(children: [
          Text('🔥 ', style: TextStyle(fontSize: _narrow(context) ? 14 : 15)),
          // Flexible, or the ellipsis below can never engage: a bare Text in
          // a Row overflowed on a 320dp phone at a large text size. flex 4
          // against the rule's 1, so the rule never squeezes the heading
          // into an ellipsis - at a 1.35 text scale it needs up to ~60% of
          // the row (on a 320dp phone).
          Flexible(
            flex: 4,
            child: Text('Fresh on Broka',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    // Brief §5: 16-18px on a normal phone, stepped down rather
                    // than ellipsised on a small one.
                    fontSize: _narrow(context) ? 15.5 : 17,
                    height: 1.1,
                    letterSpacing: -0.2,
                    fontWeight: FontWeight.w800)),
          ),
          // A rule fading out to the right (2026-09-29 visual upgrade): the
          // feed starts here, and the rail and Zeno above it are not part of
          // it. A hairline, not a card edge or a background band. Dropped
          // on a small phone, where the escrow pill needs the room.
          if (!_narrow(context)) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    BrokaColors.gold.withOpacity(0.55),
                    BrokaColors.neonBlue.withOpacity(0.18),
                    Colors.transparent,
                  ], stops: const [0.0, 0.45, 1.0]),
                ),
              ),
            ),
          ],
          // Escrow on the first screen anyone sees (2026-10-08): BROKA holds
          // no payments, and a buyer who never hears of escrow pays a
          // stranger and hopes. On the heading's own row, so the feed still
          // starts in the top half (brief §2) - the full callout is on every
          // listing and in every deal chat (escrow_callout.dart). Flexible
          // and scaled down rather than overflowing at a large text size.
          // Hidden with every other way to a payment (payments_shown.dart).
          if (paymentsShown) ...[
            const SizedBox(width: 8),
            const Flexible(
              flex: 3,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: _EscrowPill(),
              ),
            ),
          ],
        ]),
      );

  /// Small-Android breakpoint, shared by every responsive size on this screen
  /// so they all step down together rather than at four different widths.
  static bool _narrow(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 360;

  Widget _buildFeedSliver() {
    // ProductGridView loads once in initState, so a ValueKey covering every
    // input that should trigger a refetch is still how a filter change forces
    // one: changing the key remounts fresh state, matching the old
    // per-filter _loadListings() calls. _feedController is the other half -
    // it refetches WITHOUT remounting, which is what pull-to-refresh needs
    // (a remount would throw away the scroll position mid-gesture).
    return ProductGridView(
      key: ValueKey('goods|$_committedPriceFilter|$_locationFilter|$_conditionFilter|$_sortFilter|$_feedRefreshNonce'),
      sliver: true,
      // 16px page gutter, matching every section above it, with the grid's
      // own 12px inter-card spacing untouched (brief §16). The default
      // EdgeInsets.all(12) every other caller uses is unchanged - this is
      // Home lining its feed up with its own header, not a new default.
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      controller: _feedController,
      fetchPage: _fetchListingsPage,
      onTapItem: (item) {
        Navigator.pushNamed(context, '/product', arguments: {'listingId': (item as BrokaListing).id}).then((_) {
          if (mounted) setState(() => _feedRefreshNonce++);
        });
      },
      emptyStateBuilder: (_) => _emptyState(),
      onViewStore: (storeId, storeSlug) =>
          Navigator.pushNamed(context, '/store-view', arguments: {'storeId': storeId}),
    );
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

  // Polish pass (2026-09-18, brief §10). Same five destinations, same routes,
  // same auth gating, same Zeno avatar - three contrast fixes:
  //   * Unselected was BrokaColors.textLow (#2E3D5A) on #070B16. That is
  //     roughly 1.6:1 - four of the five destinations were effectively
  //     invisible, which reads as "disabled", not "not current". textMid
  //     gives them a real presence while selected still wins outright.
  //   * Selected now carries a small violet pill behind it and a 2px
  //     indicator above the label, so "you are on Home" survives a glance.
  //   * A shadow along the top edge lifts the bar off the feed, so cards
  //     scrolling past it read as passing UNDER a fixed bar.
  Widget _buildNav() => Container(
    decoration: BoxDecoration(
      color: BrokaColors.bgMid,
      border: const Border(top: BorderSide(color: BrokaColors.border)),
      boxShadow: [
        BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 16,
            offset: const Offset(0, -3)),
      ],
    ),
    child: SafeArea(top: false, child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: List.generate(_navItems.length, (i) {
          final item = _navItems[i];
          final selected = _navIndex == i;
          final tint = selected ? BrokaColors.gold : BrokaColors.textMid;
          // Expanded, not spaceAround with intrinsically-sized children: five
          // items whose widths are set by their own labels add up to more
          // than a 320dp row ("Profile", as it was, tipped it over), and a
          // Row has no way to give back the difference - it just overflows.
          // An even fifth each also means the whole column below an icon is
          // the tap target, not just the glyph.
          return Expanded(
            child: GestureDetector(
              onTap: () => _onNav(i),
              // Holding the Zeno tab opens Zeno already listening - the way
              // holding a phone's side button wakes its assistant.
              onLongPress: item['label'] == 'Zeno' ? _talkToZeno : null,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    decoration: BoxDecoration(
                      color: selected
                          ? BrokaColors.gold.withOpacity(0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: item['label'] == 'Zeno'
                        ? ZenoAvatar(size: 23, selected: selected, glow: selected)
                        : item['label'] == 'Inbox'
                            ? _InboxNavIcon(color: tint)
                            : Icon(item['icon'] as IconData, size: 23, color: tint),
                  ),
                  const SizedBox(height: 3),
                  Text(item['label'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10,
                          height: 1.1,
                          color: tint,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
                ]),
              ),
            ),
          );
        }),
      ),
    )),
  );
}

/// The Inbox tab's icon, with the number of unread messages across all
/// conversations (GlobalPollerService.unreadTotal, refreshed every sweep).
/// Nothing on Home said a message was waiting; the count lived only inside
/// the Inbox, one tap away from where anyone would see it.
class _InboxNavIcon extends StatelessWidget {
  const _InboxNavIcon({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: GlobalPollerService.instance.unreadTotal,
        builder: (_, unread, icon) {
          final label = unread > 99 ? '99+' : '$unread';
          return Semantics(
            label: unread > 0 ? 'Inbox, $unread unread' : 'Inbox',
            excludeSemantics: true,
            child: Stack(clipBehavior: Clip.none, children: [
              icon!,
              if (unread > 0)
                Positioned(
                  right: -9, top: -6,
                  child: Container(
                    key: const Key('inbox-unread-badge'),
                    constraints: const BoxConstraints(minWidth: 17),
                    height: 17,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: BrokaColors.danger,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: BrokaColors.bgMid, width: 1.5),
                    ),
                    child: Text(label,
                        maxLines: 1,
                        textScaler: TextScaler.noScaling,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 9.5,
                            fontWeight: FontWeight.w800, height: 1.0)),
                  ),
                ),
            ]),
          );
        },
        child: Icon(Icons.inbox_outlined, size: 23, color: color),
      );
}

/// A feed page that failed to load, thrown so ProductGridView shows its retry
/// state instead of an empty marketplace.
class HomeFeedFailure implements Exception {
  HomeFeedFailure(this.message);
  final String message;
  @override
  String toString() => message;
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

// Home-redesign brief §5 (2026-08-16): one shared shape for every item in
// the unified discovery rail (real categories + Trending/Auctions/Traders/
// Stores) - a CategoryArtCard since 2026-10-08. isDestination (final polish
// pass, 2026-08-19) does NOT change that shape - it only flags the
// non-category entries so _buildDiscoveryRail() can draw one thin divider
// ahead of them.
class _RailItem {
  final String emoji;
  final String label;
  final List<Color> colors;
  final VoidCallback onTap;
  final bool isDestination;
  /// The card's picture; null (the destinations, "Other") draws it from
  /// [colors] and [emoji].
  final String? assetPath;
  const _RailItem({
    required this.emoji,
    required this.label,
    required this.colors,
    required this.onTap,
    this.isDestination = false,
    this.assetPath,
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

// ── Collapsing Home header (collapsing-scroll pass, 2026-09-18) ───────────────
//
// Brief §2/§18: at rest this is the full BROKA identity - brand mark,
// wordmark, greeting, and a full-width search bar. As the user scrolls, the
// brand block slides up under the status bar and fades, and what stays
// behind is a ~60px sticky search row with the filter toggle beside it. Scroll
// back and it comes down again, smoothly, because the scroll view itself is
// driving the collapse.
//
// Two decisions worth stating, because both were explicitly asked for:
//
//  * This is a SliverPersistentHeader delegate, not a Transform over a fixed
//    box. Sliver geometry is what makes the listings actually inherit the
//    freed space; translating a fixed header would move pixels while the grid
//    below kept exactly the viewport it always had.
//  * Collapsing happens by SHRINKING this delegate's child, so the child's
//    height is always exactly `maxExtent - shrinkOffset`. That keeps the
//    pinned header's own geometry honest (no overlap artefacts, no fighting
//    with RefreshIndicator) and means there is never a tall empty band above
//    the first row of products.
//
// The layout is deliberately measured rather than intrinsic: maxExtent has no
// BuildContext, so HomeScreen passes in the device's text scale and whether
// the screen is narrow, and the heights below are derived from those. Every
// height leaves headroom over its content, so a large accessibility text
// scale makes the header taller instead of overflowing it (brief §14/§27).
class _HomeHeaderDelegate extends SliverPersistentHeaderDelegate {
  _HomeHeaderDelegate({
    required this.greeting,
    required this.filtersOpen,
    this.filtersActive = false,
    required this.onToggleFilters,
    required this.onOpenSearch,
    required this.narrow,
    required this.textScale,
  });

  final String greeting;
  final bool filtersOpen;

  /// A filter is narrowing the feed - shown as a dot on the filter button
  /// even while the panel is closed.
  final bool filtersActive;
  final VoidCallback onToggleFilters;
  final VoidCallback onOpenSearch;

  /// Small-Android layout (< 360dp wide): smaller logo, wordmark and labels.
  final bool narrow;

  /// Already clamped by the caller to 1.0-1.35 - the header grows with the
  /// user's text size, but a 3x accessibility scale can't eat the whole
  /// screen before a single listing is visible.
  final double textScale;

  double get _fieldHeight => (narrow ? 42.0 : 44.0) * textScale;

  /// The sticky part: the search field plus its breathing room. This is what
  /// survives a full scroll, and all that survives it - a marketplace nav bar,
  /// not a second header (brief §1).
  double get _searchRowHeight => _fieldHeight + 12.0;

  /// The part that collapses: brand mark, wordmark, greeting, tagline.
  ///
  /// Polish pass (2026-09-18, brief §1/§2): trimmed from 96/88 to 88/82. The
  /// block carried ~14px of slack over its own contents, which bought nothing
  /// and pushed the first product row down by that much on every phone. What
  /// is left is ~7px of headroom, enough that a font metric rounding up can't
  /// overflow it, and the internal gaps came down with it rather than the
  /// type sizes - the header is tighter, not smaller.
  double get _brandBlockHeight => (narrow ? 82.0 : 88.0) * textScale;

  @override
  double get maxExtent => _brandBlockHeight + _searchRowHeight;

  @override
  double get minExtent => _searchRowHeight;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = maxExtent - minExtent;
    final t = range <= 0 ? 1.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    // The brand is gone by ~70% of the collapse, so the last stretch is a
    // clean slide of the search bar into place rather than a long fade.
    final brandOpacity = (1.0 - t * 1.4).clamp(0.0, 1.0);
    // Brief §1: "Do not allow product cards to visually bleed through a
    // partially transparent collapsing header" AND "keep the constellation
    // background visible while the header is expanded." Those only conflict
    // if the fade is tied to the collapse. It isn't: at scroll offset 0 there
    // is nothing underneath the header to bleed through, so it can be fully
    // transparent and show the constellation; the instant content starts
    // moving under it, it goes opaque. Eighteen pixels of scroll is long
    // enough not to flash and short enough that no card is ever half-visible
    // through it.
    final backdrop = (shrinkOffset / 18.0).clamp(0.0, 1.0);

    return ClipRect(
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Fully opaque once scrolled - a clean dark surface, not glass.
          color: BrokaColors.bg.withOpacity(backdrop),
          border: Border(
            bottom: BorderSide(color: BrokaColors.border.withOpacity(0.7 * backdrop)),
          ),
          // A whisper of a drop shadow so the bar sits above the feed rather
          // than being pasted onto it. Only once it is opaque, or it would
          // smudge the constellation at rest.
          boxShadow: backdrop <= 0
              ? null
              : [BoxShadow(
                  color: Colors.black.withOpacity(0.35 * backdrop),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                )],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Align + heightFactor is what does the moving: the block keeps
            // its full height with its BOTTOM edge pinned, so shrinking the
            // factor slides its top up out of the clip rect. Same read as a
            // header scrolling away, but expressed as layout, so the sliver
            // below it genuinely gains the pixels.
            Align(
              alignment: Alignment.bottomCenter,
              heightFactor: 1.0 - t,
              child: Opacity(
                opacity: brandOpacity,
                child: SizedBox(
                  height: _brandBlockHeight,
                  child: _brandBlock(context),
                ),
              ),
            ),
            SizedBox(height: _searchRowHeight, child: _searchRow(context, t)),
          ],
        ),
      ),
    );
  }

  Widget _brandBlock(BuildContext context) {
    final logo = narrow ? 36.0 : 40.0;
    return Padding(
      // 16 on the left, matching the search bar, the rail, the Zeno CTA, the
      // Fresh heading and the grid - one content edge down the whole screen
      // (brief §16). This was 18 and was the only thing that broke the line.
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            // BROKA brand mark - the same asset, corner radius and glow as
            // auth_screen.dart's _buildLogo(), so the icon that identifies the
            // app at sign-in is the icon at the top of Home.
            Container(
              width: logo,
              height: logo,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(logo * 0.3),
                boxShadow: const [BrokaColors.glowGold],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(logo * 0.3),
                child: Image.asset('assets/images/broka_icon.png', fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(
                        colors: [BrokaColors.gold, BrokaColors.neonBlue]).createShader(b),
                    child: Text('BROKA',
                        maxLines: 1,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: narrow ? 21 : 24,
                            height: 1.0,
                            fontWeight: FontWeight.w900,
                            letterSpacing: narrow ? 1.6 : 2.2)),
                  ),
                  const SizedBox(height: 2),
                  Text('INTELLIGENT COMMERCE',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: BrokaColors.textMid,
                          fontSize: narrow ? 7.5 : 8,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          letterSpacing: narrow ? 1.8 : 2.4)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 5),
          Row(children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: BrokaColors.neonGreen),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(greeting,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: narrow ? 12.5 : 13.5,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2)),
            ),
          ]),
          const SizedBox(height: 1),
          Text('Better deals. Smarter choices.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: BrokaColors.textMid,
                  height: 1.2,
                  fontSize: narrow ? 10.5 : 11.5)),
        ],
      ),
    );
  }

  /// The sticky control. Tapping the field opens ListingSearchScreen -
  /// listings only; traders are searched on the Traders screen. The button
  /// beside it is the filter toggle, with a dot while any filter applies.
  Widget _searchRow(BuildContext context, double t) {
    final h = _lerp(_fieldHeight, _fieldHeight - 6, t);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Row(children: [
        Expanded(
          child: GestureDetector(
            onTap: onOpenSearch,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: h,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard.withOpacity(0.86),
                borderRadius: BorderRadius.circular(h / 2),
                border: Border.all(
                    color: BrokaColors.neonBlue.withOpacity(_lerp(0.35, 0.55, t))),
              ),
              child: Row(children: [
                const Icon(Icons.search_rounded, size: 18, color: BrokaColors.textMid),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    narrow ? 'Search listings…' : 'Search listings - phones, cars, land…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: BrokaColors.textMid, fontSize: narrow ? 12 : 12.5),
                  ),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: onToggleFilters,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: h,
            height: h,
            decoration: BoxDecoration(
              color: filtersOpen
                  ? BrokaColors.gold.withOpacity(0.2)
                  : BrokaColors.bgCard.withOpacity(0.86),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: filtersOpen ? BrokaColors.gold : BrokaColors.border),
            ),
            child: Stack(clipBehavior: Clip.none, children: [
              Center(
                child: Icon(Icons.tune_rounded,
                    color: filtersOpen || filtersActive
                        ? BrokaColors.gold
                        : BrokaColors.textMid,
                    size: 18),
              ),
              if (filtersActive)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    key: const Key('home-filters-active-dot'),
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                        color: BrokaColors.gold, shape: BoxShape.circle),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }

  @override
  bool shouldRebuild(covariant _HomeHeaderDelegate old) =>
      old.greeting != greeting ||
      old.filtersOpen != filtersOpen ||
      old.filtersActive != filtersActive ||
      old.narrow != narrow ||
      old.textScale != textScale ||
      old.onOpenSearch != onOpenSearch ||
      old.onToggleFilters != onToggleFilters;
}

// ── Compact Zeno CTA (brief §6/§7) ───────────────────────────────────────────
//
// One row, ~56px, exactly as the 2026-08-16 redesign left it - not the old
// ~180px promotional card, and not a second Zeno hero on a screen that
// already has Zeno in the bottom nav.
//
// It is its own StatefulWidget purely for the animation budget. Both moving
// parts (a 4-second breathing glow and a message that crossfades every few
// seconds) previously would have had to live on HomeScreen's own
// AnimationController, rebuilding the header, the rail and every product card
// along with them. Scoped here, a frame of Zeno costs one row.
/// "Pay with escrow" beside Home's feed heading: escrow green, glowing,
/// one tap to the escrow services and Zeno's walkthrough.
class _EscrowPill extends StatelessWidget {
  const _EscrowPill();

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Pay with escrow',
        child: GestureDetector(
          key: const Key('home-escrow'),
          onTap: () => openEscrowServices(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: BrokaColors.neonGreen.withOpacity(0.16),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.85)),
              boxShadow: [BoxShadow(color: BrokaColors.neonGreen.withOpacity(0.35), blurRadius: 12)],
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.shield_rounded, size: 14, color: BrokaColors.neonGreen),
              SizedBox(width: 4),
              Text('Pay with escrow', style: TextStyle(
                  color: BrokaColors.neonGreen, fontSize: 11.5, fontWeight: FontWeight.w900)),
            ]),
          ),
        ),
      );
}

class _ZenoCompactCta extends StatefulWidget {
  const _ZenoCompactCta({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_ZenoCompactCta> createState() => _ZenoCompactCtaState();
}

class _ZenoCompactCtaState extends State<_ZenoCompactCta>
    with SingleTickerProviderStateMixin {
  // Written as Zeno offering to help, never as a claim about what Zeno has
  // already found - it hasn't been asked anything yet at this point.
  static const _messages = <String>[
    'Need my help?',
    'Let me search for you',
    "Tell me what you're looking for",
    'I can find the deal',
  ];

  late final AnimationController _glow = AnimationController(
      vsync: this, duration: const Duration(seconds: 4))
    ..repeat(reverse: true);
  Timer? _rotate;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Brief §7: subtle. A message every 5 seconds with a slow crossfade,
    // rather than anything that pulses for attention.
    _rotate = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) setState(() => _index = (_index + 1) % _messages.length);
    });
  }

  @override
  void dispose() {
    _rotate?.cancel();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 360;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        // RepaintBoundary so the glow's repaint stops here instead of
        // travelling out into the scroll view it sits in.
        child: RepaintBoundary(
          // A glint crosses the row once every six seconds, as the message
          // changes - a single pass of light that then rests, not a pulse:
          // the brief's worry above was movement that never stops.
          child: AgentShine(
            child: AnimatedBuilder(
              animation: _glow,
              // `child` is built once and handed back on every frame - the row
              // below never rebuilds, only the decoration around it repaints.
              builder: (context, child) {
                // Polish pass (2026-09-18, brief §4): 0.12-0.22 -> 0.09-0.15.
                // A 10-point swing on a shadow next to a feed of product photos
                // was a light pulsing in the corner of the eye while someone
                // was trying to read prices. Zeno should earn attention by
                // looking considered, not by moving.
                final glow = 0.09 + 0.06 * _glow.value;
                return Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: narrow ? 12 : 14, vertical: 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1A1040), Color(0xFF0E1B3D)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.40)),
                    boxShadow: [
                      BoxShadow(
                          color: BrokaColors.neonBlue.withOpacity(glow),
                          blurRadius: 16,
                          spreadRadius: 1),
                    ],
                  ),
                  child: child,
                );
              },
              child: Row(children: [
                // Flies into the Buying Agent's header as it opens.
                const Hero(
                  tag: kBuyingAgentHeroTag,
                  child: ZenoAvatar(size: 30, glow: true),
                ),
                SizedBox(width: narrow ? 8 : 11),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 520),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    // Plain crossfade. A slide or a scale on a 56px row that
                    // changes every five seconds is movement in the corner of
                    // the eye while someone is trying to read listings.
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: Column(
                      key: ValueKey<int>(_index),
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_messages[_index],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: BrokaColors.textHigh,
                                fontSize: narrow ? 13 : 14,
                                height: 1.2,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 1),
                        Text('Ask Zeno to find and negotiate it',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: BrokaColors.textMid,
                                fontSize: narrow ? 10.5 : 11,
                                height: 1.2)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                        colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
                  ),
                  child: const Icon(Icons.arrow_forward_rounded,
                      color: Colors.white, size: 15),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
