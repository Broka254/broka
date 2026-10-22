// BROKA — Store discovery (spec §12/§21, Phase 4)
// A single-column directory of wide cards: each row shows the shop's
// picture on the left with its facts beside it, via StoreCard's opt-in wide
// presentation. The taller one-column card remains the default for the
// nearby and category screens.
//
// A store card shows the shop itself, its own rating, its distance when
// known, and a way onto the map. The owner's seller record lives in Store
// details, beside the shop's rating rather than instead of it - a shop and
// the person behind it are two different records.
//
// Two lists feed this screen and both must respect one shop, one card: see
// _nearbyRail and _mainList below, which is where the duplicate-shop bug
// was fixed.
//
// Destination-alignment pass (2026-09-18): restyled onto the same system as
// Home and the Category Zones - ConstellationBackground, one CustomScrollView
// with the shared collapsing header, and Home's search control in place of a
// filled TextField whose textLow placeholder was effectively unreadable on a
// bgCard surface. The search now scrolls away with the rest of the header
// content instead of sitting in a fixed band above an Expanded list. Same
// repository call, same routes.
//
// Category-card pass (2026-10-16): the category chips that filtered this
// list in place are gone. Home's rule - a category is a card that opens a
// screen of its own - now applies to shops too: the rail is the same
// CategoryArtCard (category_visual artwork, 21 categories), and tapping one
// opens StoreCategoryScreen, scoped to that category. The search stays
// here for every store; a category screen has its own.
//
// Directory pass (2026-10-19): the page now follows the Stores reference -
// search and filter on one row, the artwork rail, county/area/distance
// filters, a nearby section, then All stores with working sort and filter
// controls. Both sections use the same card, and the two lists still
// share one id set so a nearby shop is never drawn twice.
//
// Wide-card pass (2026-10-22): the two-column grid is gone. Two cards across
// a phone halved every line, so names and places wrapped and the picture
// shrank to a thumbnail; one shop per row (the wide card) gives the picture
// the size of a shopfront and every fact its own line.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../../../widgets/broka_search_field.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../categories/presentation/widgets/category_art_card.dart';
import '../../discovery/domain/destination_visual.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import '../domain/store_categories.dart';
import '../domain/store_locator.dart';
import 'nearby_stores_screen.dart';
import 'store_category_screen.dart';
import 'store_home_screen.dart';
import 'store_map_screen.dart';
import 'widgets/store_card.dart';
import 'widgets/store_details_view.dart' show showStoreDetails;
import 'widgets/store_location_filter.dart';

enum _StoreOrder {
  recommended('Recommended'),
  nearest('Nearest');

  const _StoreOrder(this.label);
  final String label;
}

class StoreListScreen extends StatefulWidget {
  const StoreListScreen({
    super.key,
    this.repository,
    this.locate,
    this.animateBackground = true,
  });

  /// Injectable for tests; the app uses the shared repository. Same pattern
  /// as NearbyStoresScreen, so a directory test never touches the network.
  final StoresRepository? repository;

  /// Injectable for tests; the app asks the device.
  final StoreLocator? locate;

  /// False in tests: the constellation's repeating animation otherwise
  /// keeps scheduling frames, so pumpAndSettle never reaches an idle state.
  final bool animateBackground;

  @override
  State<StoreListScreen> createState() => _StoreListScreenState();
}

class _StoreListScreenState extends State<StoreListScreen> {
  StoresRepository get _repo => widget.repository ?? storesRepository;

  final List<Store> _stores = [];
  bool _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();

  /// Search-as-you-type, on the same 400 ms the store page uses: this
  /// screen used to search only when the keyboard's Search key was
  /// pressed, and the shared field has no visible button, so typing
  /// looked like it did nothing at all.
  Timer? _searchDebounce;
  final List<Store> _nearby = [];
  double? _userLat;
  double? _userLng;
  String? _county;
  String? _subcounty;
  String? _category;
  double? _maxDistanceKm;
  _StoreOrder _order = _StoreOrder.recommended;

  @override
  void initState() {
    super.initState();
    _load();
    _loadNearby();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _load();
    });
  }

  Future<void> _load() async {
    // A spinner only on the first load: a search keystroke must not
    // replace the list being narrowed with a full-screen spinner.
    setState(() {
      _loading = _stores.isEmpty;
      _error = null;
    });
    final query = _searchCtrl.text.trim();
    final hasFix = _userLat != null && _userLng != null;
    final result = await _repo.listStores(
        search: query.isEmpty ? null : query,
        category: _category,
        county: _county,
        subcounty: _subcounty,
        lat: _userLat,
        lng: _userLng,
        maxDistanceKm: hasFix ? _maxDistanceKm : null,
        nearestFirst: hasFix && _order == _StoreOrder.nearest);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _stores
          ..clear()
          ..addAll(data);
        _loading = false;
      }),
      onFailure: (msg, __) => setState(() {
        _error = msg;
        _loading = false;
      }),
    );
  }

  /// True while the user is narrowing the list. The nearby rail is a
  /// shortcut, not a second catalogue: a shelf of unfiltered shops above a
  /// filtered result set contradicts what was asked for, so it is hidden
  /// for the duration.
  bool get _filtersActive =>
      _searchCtrl.text.trim().isNotEmpty ||
      _category != null ||
      _county != null ||
      _subcounty != null ||
      _maxDistanceKm != null;

  bool get _canUseDistance => _userLat != null && _userLng != null;

  bool get _nonSearchFiltersActive =>
      _category != null ||
      _county != null ||
      _subcounty != null ||
      _maxDistanceKm != null;

  int get _activeFilterCount => [
        _category != null,
        _county != null,
        _maxDistanceKm != null,
      ].where((active) => active).length;

  Future<void> _showFilters() async {
    _searchDebounce?.cancel();
    final result = await showModalBottomSheet<_StoreFilterResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _StoreFilterSheet(
        category: _category,
        maxDistanceKm: _maxDistanceKm,
        locationAvailable: _canUseDistance,
      ),
    );
    if (!mounted || result == null) return;
    if (result.clearAll) {
      _clearFilters();
      return;
    }
    setState(() {
      _category = result.category;
      _maxDistanceKm = result.maxDistanceKm;
    });
    _load();
  }

  Future<void> _showSortSheet() async {
    _searchDebounce?.cancel();
    final picked = await showModalBottomSheet<_StoreOrder>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _StoreSortSheet(
        selected: _order,
        locationAvailable: _canUseDistance,
      ),
    );
    if (!mounted || picked == null || picked == _order) return;
    if (picked == _StoreOrder.nearest && !_canUseDistance) return;
    setState(() => _order = picked);
    _load();
  }

  void _clearFilters() {
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    setState(() {
      _category = null;
      _county = null;
      _subcounty = null;
      _maxDistanceKm = null;
      _order = _StoreOrder.recommended;
    });
    _load();
  }

  /// The shops shown in the 'Stores near you' rail, and therefore excluded
  /// from 'All stores' below it.
  ///
  /// This is the duplicate fix. The two lists are fetched independently -
  /// one with a 25 km radius, one without - and nothing used to remove the
  /// nearby ids from the main list, so every shop within 25 km was drawn
  /// twice on one screen: once in the rail, once under 'All stores'. The
  /// rail is the same shops, presented earlier, so the main list continues
  /// below it rather than repeating it.
  List<Store> get _nearbyRail =>
      _filtersActive ? const [] : _nearby.take(5).toList();

  /// Every store in the main list except the ones already in the rail.
  List<Store> get _mainList {
    final shown = {for (final s in _nearbyRail) s.id};
    return [
      for (final s in _stores)
        if (!shown.contains(s.id)) s
    ];
  }

  /// 'Stores near you' for the general directory: live GPS first, the
  /// saved session point as fallback - never a stale zero. A missing fix
  /// leaves the section hidden, not a 0 km list.
  Future<void> _loadNearby() async {
    // Live GPS only. The saved session point (ApiService.currentUserLat/Lng)
    // is the signup fix and can be tens of km stale - near you from a stale
    // point is worse than no near you at all.
    double? lat;
    double? lng;
    if (widget.locate != null) {
      final fix = await widget.locate!();
      lat = fix?.lat;
      lng = fix?.lng;
    } else {
      try {
        if (await Geolocator.isLocationServiceEnabled()) {
          var perm = await Geolocator.checkPermission();
          if (perm == LocationPermission.denied) {
            perm = await Geolocator.requestPermission();
          }
          if (perm != LocationPermission.denied &&
              perm != LocationPermission.deniedForever) {
            final pos = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.medium,
                timeLimit: Duration(seconds: 10),
              ),
            );
            lat = pos.latitude;
            lng = pos.longitude;
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    if (lat == null || lng == null) return;
    setState(() {
      _userLat = lat;
      _userLng = lng;
    });
    final result = await _repo.listStores(
        lat: lat,
        lng: lng,
        maxDistanceKm: Store.nearRadiusKm,
        nearestFirst: true,
        limit: 10);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _nearby
          ..clear()
          ..addAll(data.take(5));
      }),
      onFailure: (_, __) {},
    );
    // Refresh distances on the main list once the fix is known.
    if (_userLat != null) _load();
  }

  static const _visual = DestinationVisuals.stores;

  final _scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.25,
              colors: [
                _visual.gradient.first.withOpacity(0.10),
                Colors.transparent
              ],
              stops: const [0.0, 0.62],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: RefreshIndicator(
              onRefresh: () async {
                await _load();
                await _loadNearby();
              },
              color: BrokaColors.gold,
              backgroundColor: BrokaColors.bgCard,
              displacement: 72,
              child: CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: CollapsingScreenHeader(
                      title: _visual.title,
                      emoji: _visual.emoji,
                      gradient: _visual.gradient,
                      onBack: () => Navigator.pop(context),
                      narrow: media.size.width < 360,
                      textScale: media.textScaler
                          .scale(1.0)
                          .clamp(1.0, 1.35)
                          .toDouble(),
                    ),
                  ),
                  SliverToBoxAdapter(child: _searchBar()),
                  SliverToBoxAdapter(child: _categoryRail()),
                  SliverToBoxAdapter(
                    child: StoreLocationFilter(
                      county: _county,
                      subcounty: _subcounty,
                      maxDistanceKm: _maxDistanceKm,
                      onClear: () {
                        setState(() {
                          _county = null;
                          _subcounty = null;
                          _maxDistanceKm = null;
                        });
                        _load();
                      },
                      onDistanceChanged: _canUseDistance
                          ? (value) {
                              setState(() => _maxDistanceKm = value);
                              _load();
                            }
                          : null,
                      onChanged: (county, subcounty) {
                        setState(() {
                          _county = county;
                          _subcounty = subcounty;
                        });
                        _load();
                      },
                    ),
                  ),
                  ..._nearbySlivers(),
                  SliverToBoxAdapter(child: _listHeading()),
                  ..._bodySlivers(),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The same search field as the Category Zones and Traders (see
  /// widgets/broka_search_field.dart) - the old 44px pill with 13px text was
  /// too small to read back what had been typed.
  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        child: Row(children: [
          Expanded(
            child: BrokaSearchField(
              controller: _searchCtrl,
              hintText: 'Search stores and their products',
              onChanged: _onSearchChanged,
              onSubmitted: (_) {
                _searchDebounce?.cancel();
                _load();
              },
              onCleared: () {
                _searchDebounce?.cancel();
                _load();
              },
            ),
          ),
          const SizedBox(width: 8),
          _SearchFilterButton(
            key: const Key('store-search-filter'),
            height: BrokaSearchField.heightFor(context),
            active: _nonSearchFiltersActive,
            onTap: _showFilters,
          ),
        ]),
      );

  /// Every rail entry as Home draws one (CategoryArtCard), so a directory
  /// of many shops narrows the way products do: pick the kind of shop and
  /// its screen opens with only those stores. Online stores browse by the
  /// goods rail only - Property, Automobiles, Land, Services and Other are
  /// dealer/agent trades, not online-store listing categories.
  Widget _categoryRail() {
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final cardWidth = narrow ? 112.0 : 122.0;
    final cardHeight = (narrow ? 84.0 : 88.0) +
        24 * (MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3) - 1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('Shop by category',
            style: TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.1)),
      ),
      SizedBox(
        height: cardHeight + 8,
        child: ListView.separated(
          key: const Key('store-category-rail'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          itemCount: StoreCategories.onlineRail.length + 1,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            // Near you first: not a category, but browsable exactly like
            // one - shops within 25 km of where you are standing.
            if (i == 0) {
              return CategoryArtCard(
                key: const Key('store-category-near-you'),
                label: 'Near you',
                emoji: '📍',
                gradient: const [BrokaColors.gold, BrokaColors.neonCyan],
                width: cardWidth,
                height: cardHeight,
                labelSize: narrow ? 11.5 : 12.0,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const NearbyStoresScreen())),
              );
            }
            final name = StoreCategories.onlineRail[i - 1];
            final visual = StoreCategories.visualFor(name);
            return CategoryArtCard(
              key: Key('store-category-$name'),
              label: name,
              emoji: visual.emoji,
              gradient: visual.gradient,
              assetPath: visual.assetPath,
              width: cardWidth,
              height: cardHeight,
              labelSize: narrow ? 11.5 : 12.0,
              onTap: () => openStoreCategory(context, name),
            );
          },
        ),
      ),
    ]);
  }

  Widget _listHeading() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.storefront_outlined, size: 16, color: BrokaColors.gold),
            SizedBox(width: 6),
            Text('All stores',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 15,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.1)),
          ]),
          const SizedBox(height: 2),
          const Text('Explore all available stores in your area',
              style: TextStyle(
                  color: BrokaColors.textMid,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _DirectoryControl(
                key: const Key('store-sort-control'),
                icon: Icons.swap_vert_rounded,
                label: 'Sort: ${_order.label}',
                active: _order != _StoreOrder.recommended,
                onTap: _showSortSheet,
              ),
              const SizedBox(width: 7),
              _DirectoryControl(
                key: const Key('store-category-control'),
                icon: Icons.grid_view_rounded,
                label: 'Category: ${_category ?? 'All'}',
                active: _category != null,
                onTap: _showFilters,
              ),
              const SizedBox(width: 7),
              _DirectoryControl(
                key: const Key('store-filters-control'),
                icon: Icons.tune_rounded,
                label: 'Filters',
                active: _nonSearchFiltersActive,
                badge: _activeFilterCount,
                onTap: _showFilters,
              ),
            ]),
          ),
        ]),
      );

  /// 'Stores near you': nearest first within 25 km, each with its distance.
  /// Hidden until a live fix arrives and something qualifies - no fix or
  /// nothing near means no section, never a guess.
  /// 'Stores near you': nearest first within 25 km, each with its distance.
  /// Hidden until a live fix arrives and something qualifies - no fix or
  /// nothing near means no section, never a guess. Also hidden while a
  /// filter is active: see [_nearbyRail].
  List<Widget> _nearbySlivers() {
    final rail = _nearbyRail;
    if (rail.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 7),
          child: Row(children: [
            const Icon(Icons.near_me_rounded,
                size: 16, color: BrokaColors.gold),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Nearby stores',
                        style: TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 15,
                            height: 1.2,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.1)),
                    const SizedBox(height: 2),
                    Text('${rail.length} within 25 km of you',
                        style: const TextStyle(
                            color: BrokaColors.gold,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700)),
                  ]),
            ),
            TextButton(
              key: const Key('nearby-see-all'),
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          NearbyStoresScreen(repository: widget.repository))),
              style: TextButton.styleFrom(
                foregroundColor: BrokaColors.neonCyan,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(44, 40),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Text('See all',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                SizedBox(width: 3),
                Icon(Icons.arrow_forward_rounded, size: 15),
              ]),
            ),
          ]),
        ),
      ),
      _storeList(rail, keyPrefix: 'nearby-store'),
    ];
  }

  List<Widget> _bodySlivers() {
    if (_loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
              child: Padding(
            padding: EdgeInsets.only(bottom: 80),
            child: CircularProgressIndicator(color: BrokaColors.gold),
          )),
        ),
      ];
    }
    if (_error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: BrokaEmptyState(
              emoji: '📡',
              gradient: _visual.gradient,
              headline: "Couldn't load stores",
              body: _error!,
              action:
                  OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ),
          ),
        ),
      ];
    }
    final main = _mainList;
    if (_stores.isEmpty || main.isEmpty) {
      final searching = _searchCtrl.text.trim().isNotEmpty;
      // The rail can hold every shop when there are only a handful - but
      // only when there ARE shops. An empty directory still says so.
      if (_stores.isNotEmpty && main.isEmpty && !_loading && _error == null) {
        return const [SliverToBoxAdapter(child: SizedBox(height: 8))];
      }
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: BrokaEmptyState(
              emoji: _visual.emoji,
              gradient: _visual.gradient,
              headline: searching
                  ? 'No stores match "${_searchCtrl.text.trim()}"'
                  : _filtersActive
                      ? 'No stores match those filters'
                      : _visual.emptyHeadline,
              body: searching
                  ? 'Try a shorter or different search'
                  : _filtersActive
                      ? 'Try a different category, place or distance.'
                      : _visual.emptyBody,
            ),
          ),
        ),
      ];
    }
    return [_storeList(main, keyPrefix: 'all-store')];
  }

  /// One shop per row, each in the wide card that lays the picture on its
  /// left and the facts beside it. This is the directory's only list shape:
  /// a two-column grid is what halved every line and shrank the picture to
  /// a thumbnail.
  Widget _storeList(List<Store> stores, {required String keyPrefix}) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      sliver: SliverList(
        key: Key('$keyPrefix-list'),
        delegate: SliverChildBuilderDelegate(
          (_, i) => StoreCard(
            key: Key('$keyPrefix-${stores[i].id}'),
            store: stores[i],
            wide: true,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => StoreHomeScreen(storeId: stores[i].id))),
            onDetails: () =>
                showStoreDetails(context, stores[i], repository: _repo),
            onMap: () => openStoreMap(context, stores[i],
                viewerLat: _userLat, viewerLng: _userLng),
          ),
          childCount: stores.length,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class _SearchFilterButton extends StatelessWidget {
  const _SearchFilterButton({
    super.key,
    required this.height,
    required this.active,
    required this.onTap,
  });

  final double height;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Filter stores',
        child: Semantics(
          button: true,
          label: 'Filter stores',
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: height,
              height: height,
              decoration: BoxDecoration(
                color: active
                    ? BrokaColors.gold.withOpacity(0.18)
                    : BrokaColors.bgCard.withOpacity(0.92),
                borderRadius: BorderRadius.circular(height / 2),
                border: Border.all(
                  color: active
                      ? BrokaColors.gold.withOpacity(0.85)
                      : BrokaColors.neonBlue.withOpacity(0.45),
                  width: active ? 1.5 : 1.2,
                ),
              ),
              child: Stack(clipBehavior: Clip.none, children: [
                Center(
                  child: Icon(Icons.tune_rounded,
                      size: 21,
                      color: active ? BrokaColors.gold : BrokaColors.textMid),
                ),
                if (active)
                  Positioned(
                    top: 9,
                    right: 9,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: BrokaColors.neonCyan,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      );
}

class _DirectoryControl extends StatelessWidget {
  const _DirectoryControl({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: active
                  ? BrokaColors.gold.withOpacity(0.14)
                  : BrokaColors.bgCard.withOpacity(0.72),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: active
                    ? BrokaColors.gold.withOpacity(0.72)
                    : BrokaColors.border,
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon,
                  size: 15,
                  color: active ? BrokaColors.gold : BrokaColors.textMid),
              const SizedBox(width: 6),
              Text(label,
                  maxLines: 1,
                  style: TextStyle(
                    color: active ? BrokaColors.textHigh : BrokaColors.textMid,
                    fontSize: 11.5,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  )),
              if (badge > 0) ...[
                const SizedBox(width: 5),
                Container(
                  constraints: const BoxConstraints(minWidth: 16),
                  height: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('$badge',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800)),
                ),
              ],
            ]),
          ),
        ),
      );
}

class _StoreFilterResult {
  const _StoreFilterResult({
    this.category,
    this.maxDistanceKm,
    this.clearAll = false,
  });

  final String? category;
  final double? maxDistanceKm;
  final bool clearAll;
}

class _StoreFilterSheet extends StatefulWidget {
  const _StoreFilterSheet({
    required this.category,
    required this.maxDistanceKm,
    required this.locationAvailable,
  });

  final String? category;
  final double? maxDistanceKm;
  final bool locationAvailable;

  @override
  State<_StoreFilterSheet> createState() => _StoreFilterSheetState();
}

class _StoreFilterSheetState extends State<_StoreFilterSheet> {
  late String? _category = widget.category;
  late double? _maxDistanceKm = widget.maxDistanceKm;

  @override
  Widget build(BuildContext context) {
    final categories = StoreCategories.onlineRail;
    return _SheetSurface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _SheetHandle(),
          const _SheetTitle(title: 'Filter stores'),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SheetLabel('Category'),
                    const SizedBox(height: 8),
                    Wrap(spacing: 7, runSpacing: 7, children: [
                      _SelectChip(
                        key: const Key('store-filter-category-all'),
                        label: 'All categories',
                        selected: _category == null,
                        onTap: () => setState(() => _category = null),
                      ),
                      for (final category in categories)
                        _SelectChip(
                          key: Key('store-filter-category-$category'),
                          label: category,
                          selected: _category == category,
                          onTap: () => setState(() => _category = category),
                        ),
                    ]),
                    if (widget.locationAvailable) ...[
                      const SizedBox(height: 18),
                      const _SheetLabel('Distance'),
                      const SizedBox(height: 8),
                      Wrap(spacing: 7, runSpacing: 7, children: [
                        _SelectChip(
                          key: const Key('store-filter-distance-any'),
                          label: 'Any distance',
                          selected: _maxDistanceKm == null,
                          onTap: () => setState(() => _maxDistanceKm = null),
                        ),
                        _SelectChip(
                          key: const Key('store-filter-distance-25'),
                          label: 'Within ${Store.nearRadiusKm.round()} km',
                          selected: _maxDistanceKm == Store.nearRadiusKm,
                          onTap: () => setState(
                              () => _maxDistanceKm = Store.nearRadiusKm),
                        ),
                      ]),
                    ],
                    const SizedBox(height: 16),
                  ]),
            ),
          ),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('store-filter-reset'),
                onPressed: () => Navigator.pop(
                    context, const _StoreFilterResult(clearAll: true)),
                child: const Text('Reset all'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                key: const Key('store-filter-apply'),
                onPressed: () => Navigator.pop(
                  context,
                  _StoreFilterResult(
                    category: _category,
                    maxDistanceKm: _maxDistanceKm,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: BrokaColors.gold,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Apply filters'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _StoreSortSheet extends StatelessWidget {
  const _StoreSortSheet({
    required this.selected,
    required this.locationAvailable,
  });

  final _StoreOrder selected;
  final bool locationAvailable;

  @override
  Widget build(BuildContext context) => _SheetSurface(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const _SheetHandle(),
            const _SheetTitle(title: 'Sort stores'),
            _SortTile(
              key: const Key('store-sort-recommended'),
              icon: Icons.auto_awesome_rounded,
              label: 'Recommended',
              detail: 'BROKA ranks stores by their shop rating',
              selected: selected == _StoreOrder.recommended,
              onTap: () => Navigator.pop(context, _StoreOrder.recommended),
            ),
            if (locationAvailable) ...[
              const SizedBox(height: 8),
              _SortTile(
                key: const Key('store-sort-nearest'),
                icon: Icons.near_me_rounded,
                label: 'Nearest first',
                detail: 'Closest shops to your live location',
                selected: selected == _StoreOrder.nearest,
                onTap: () => Navigator.pop(context, _StoreOrder.nearest),
              ),
            ] else ...[
              const SizedBox(height: 10),
              const Text(
                'Turn on location to sort stores by distance.',
                style: TextStyle(
                    color: BrokaColors.textMid, fontSize: 12, height: 1.4),
              ),
            ],
          ]),
        ),
      );
}

class _SheetSurface extends StatelessWidget {
  const _SheetSurface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.80),
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF16103A), BrokaColors.bgMid, BrokaColors.bg],
              stops: [0, 0.35, 1],
            ),
            border:
                Border(top: BorderSide(color: BrokaColors.gold, width: 1.1)),
          ),
          child: SafeArea(top: false, child: child),
        ),
      );
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Container(
          width: 42,
          height: 4,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [BrokaColors.gold, BrokaColors.neonBlue]),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded,
                color: BrokaColors.textMid, size: 20),
          ),
        ]),
      );
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: BrokaColors.textHigh,
          fontSize: 13,
          fontWeight: FontWeight.w800));
}

class _SelectChip extends StatelessWidget {
  const _SelectChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.gold.withOpacity(0.18)
                  : BrokaColors.bgCard.withOpacity(0.75),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected
                    ? BrokaColors.gold
                    : BrokaColors.border.withOpacity(0.85),
              ),
            ),
            child: Text(label,
                style: TextStyle(
                  color: selected ? Colors.white : BrokaColors.textMid,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                )),
          ),
        ),
      );
}

class _SortTile extends StatelessWidget {
  const _SortTile({
    super.key,
    required this.icon,
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.gold.withOpacity(0.13)
                  : BrokaColors.bgCard.withOpacity(0.72),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? BrokaColors.gold.withOpacity(0.75)
                    : BrokaColors.border,
              ),
            ),
            child: Row(children: [
              Icon(icon,
                  size: 20,
                  color: selected ? BrokaColors.gold : BrokaColors.textMid),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              color: BrokaColors.textHigh,
                              fontSize: 13,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(detail,
                          style: const TextStyle(
                              color: BrokaColors.textMid,
                              fontSize: 11.5,
                              height: 1.3)),
                    ]),
              ),
              if (selected)
                const Icon(Icons.check_circle_rounded,
                    color: BrokaColors.gold, size: 20),
            ]),
          ),
        ),
      );
}
