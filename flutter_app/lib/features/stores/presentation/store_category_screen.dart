// BROKA — stores in one category: the directory's category cards land here,
// the way Home's category cards land on a Category Zone. Scoped to one
// category, with its own search, so tapping "Electronics" shows only the
// shops that sell Electronics - including wholesalers whose main category
// is something else but who stock Electronics (the backend matches both;
// a store's single category is only where it is listed).
//
// Opened with a zero-duration transition (openStoreCategory), the same
// rule as category_navigation.dart: choosing a category should feel like
// the page changing in place, not a screen sliding over it.
//
// Filters (2026-10-22): the same county/area/distance row the directory
// has, so "Electronics" can mean "Electronics within 5 km" without going
// back to Stores and losing the category. The distance control offers the
// presets and a typed radius (widgets/distance_filter.dart); both it and
// the place filters hide the nearby rail while on, the directory's rule - a
// shelf of unfiltered shops cannot sit above a filtered result set.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../widgets/broka_search_field.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../categories/domain/category_visual.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import '../domain/store_categories.dart';
import '../domain/store_locator.dart';
import 'store_home_screen.dart';
import 'store_map_screen.dart';
import 'widgets/store_card.dart';
import 'widgets/store_details_view.dart' show showStoreDetails;
import 'widgets/store_location_filter.dart';

/// Opens the one-category store screen, with no transition.
void openStoreCategory(BuildContext context, String categoryName) {
  Navigator.push(
    context,
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => StoreCategoryScreen(categoryName: categoryName),
    ),
  );
}

class StoreCategoryScreen extends StatefulWidget {
  const StoreCategoryScreen({
    super.key,
    required this.categoryName,
    this.repository,
    this.locate,
    this.animateBackground = true,
  });
  final String categoryName;

  /// Injectable for tests; the app uses the shared repository.
  final StoresRepository? repository;

  /// Injectable for tests; the app asks the device. See StoreLocator.
  final StoreLocator? locate;

  /// False in tests: the constellation's repeating animation otherwise
  /// keeps scheduling frames, so pumpAndSettle never reaches an idle state.
  final bool animateBackground;

  @override
  State<StoreCategoryScreen> createState() => _StoreCategoryScreenState();
}

class _StoreCategoryScreenState extends State<StoreCategoryScreen> {
  StoresRepository get _repo => widget.repository ?? storesRepository;

  final List<Store> _stores = [];
  bool _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();
  /// Search-as-you-type: the same 400 ms rule the store page and the
  /// directory use now, so typing narrows the list instead of waiting for
  /// a Search key this field never showed.
  Timer? _searchDebounce;
  final _scrollController = ScrollController();
  final List<Store> _nearby = [];
  double? _userLat;
  double? _userLng;
  String? _county;
  String? _subcounty;
  double? _maxDistanceKm;

  CategoryVisual get _visual => StoreCategories.visualFor(widget.categoryName);

  /// True while the user is narrowing the list. The nearby rail is a
  /// shortcut, not a second catalogue - see [nearbyRail].
  bool get _filtersActive =>
      _searchCtrl.text.trim().isNotEmpty ||
      _county != null ||
      _subcounty != null ||
      _maxDistanceKm != null;

  /// A radius needs a centre: until a live fix arrives, the distance control
  /// is hidden rather than offering a filter that cannot mean anything.
  bool get _canUseDistance => _userLat != null && _userLng != null;

  /// The shops in the 'Stores near you' rail. Hidden while a filter is
  /// active, so a shelf of unfiltered shops cannot sit above a filtered
  /// result set.
  List<Store> get nearbyRail => _filtersActive ? const [] : _nearby.take(5).toList();

  /// The category list minus anything already drawn in the rail.
  ///
  /// The two lists are fetched independently - one within 25 km, one
  /// without - and nothing used to remove the nearby ids from the main
  /// list, so every shop close to the viewer appeared twice on one screen.
  /// The rail shows those shops first; the list continues below them.
  List<Store> get mainList {
    final shown = {for (final s in nearbyRail) s.id};
    return [for (final s in _stores) if (!shown.contains(s.id)) s];
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadNearby();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    // A spinner only on the first load: a search keystroke must not
    // replace the list being narrowed with a full-screen spinner.
    setState(() { _loading = _stores.isEmpty; _error = null; });
    final query = _searchCtrl.text.trim();
    final result = await _repo.listStores(
      search: query.isEmpty ? null : query,
      category: widget.categoryName,
      county: _county,
      subcounty: _subcounty,
      lat: _userLat,
      lng: _userLng,
      maxDistanceKm: _canUseDistance ? _maxDistanceKm : null,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _stores..clear()..addAll(data);
        _loading = false;
      }),
      onFailure: (msg, __) => setState(() { _error = msg; _loading = false; }),
    );
  }

  /// 'Stores near you' scoped to this category: same live-GPS-first rule as
  /// the general directory, filtered to shops selling this category.
  Future<void> _loadNearby() async {
    // Live GPS only - the saved session point can be tens of km stale.
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
    if (!mounted || lat == null || lng == null) return;
    setState(() {
      _userLat = lat;
      _userLng = lng;
    });
    final result = await _repo.listStores(
        category: widget.categoryName,
        lat: lat,
        lng: lng,
        maxDistanceKm: Store.nearRadiusKm,
        nearestFirst: true,
        limit: 10);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _nearby..clear()..addAll(data.take(5));
      }),
      onFailure: (_, __) {},
    );
    if (_userLat != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final visual = _visual;
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
                visual.gradient.first.withOpacity(0.15),
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
                      title: widget.categoryName,
                      emoji: visual.emoji,
                      gradient: visual.gradient,
                      onBack: () => Navigator.pop(context),
                      narrow: media.size.width < 360,
                      textScale: media.textScaler
                          .scale(1.0)
                          .clamp(1.0, 1.35)
                          .toDouble(),
                    ),
                  ),
                  SliverToBoxAdapter(child: _searchBar()),
                  SliverToBoxAdapter(child: _locationFilters()),
                  ..._nearbySlivers(),
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

  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
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
      );

  /// County, area and distance, scoped to this category - the row the
  /// directory has (image 1), so the category screen can be narrowed the
  /// same way instead of only by typing.
  Widget _locationFilters() => StoreLocationFilter(
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
      );

  List<Widget> _nearbySlivers() {
    final rail = nearbyRail;
    if (rail.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.near_me_rounded, size: 16, color: BrokaColors.gold),
              SizedBox(width: 6),
              Text('Stores near you',
                  style: TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 15,
                      height: 1.2,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.1)),
            ]),
            const SizedBox(height: 2),
            Text('${rail.length} within 25 km of you',
                style: const TextStyle(color: BrokaColors.gold, fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => StoreCard(
              key: Key('nearby-store-${rail[i].id}'),
              store: rail[i],
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => StoreHomeScreen(storeId: rail[i].id))),
              onDetails: () => showStoreDetails(context, rail[i],
                  repository: _repo),
              onMap: () => openStoreMap(context, rail[i],
                  viewerLat: _userLat, viewerLng: _userLng),
            ),
            childCount: rail.length,
          ),
        ),
      ),
    ];
  }

  List<Widget> _bodySlivers() {
    final visual = _visual;
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
              gradient: visual.gradient,
              headline: "Couldn't load stores",
              body: _error!,
              action: OutlinedButton(
                  onPressed: () {
                    _load();
                    _loadNearby();
                  },
                  child: const Text('Retry')),
            ),
          ),
        ),
      ];
    }
    final main = mainList;
    if (_stores.isEmpty || main.isEmpty) {
      final searching = _searchCtrl.text.trim().isNotEmpty;
      final wholesale = StoreCategories.isWholesaleFacet(widget.categoryName);
      final narrowedByPlace = _county != null || _maxDistanceKm != null;
      // With only a handful of shops, every one can already be in the rail
      // above - but an empty category still says so.
      if (_stores.isNotEmpty && main.isEmpty && !_loading && _error == null) {
        return const [SliverToBoxAdapter(child: SizedBox(height: 8))];
      }
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: BrokaEmptyState(
              emoji: visual.emoji,
              gradient: visual.gradient,
              headline: searching
                  ? 'No stores match "${_searchCtrl.text.trim()}"'
                  : narrowedByPlace
                      ? 'No ${widget.categoryName} stores match those filters'
                      : wholesale
                          ? 'No wholesale stores yet'
                          : 'No ${widget.categoryName} stores yet',
              body: searching
                  ? 'Try a shorter or different search'
                  : narrowedByPlace
                      ? 'Try a different county, area or distance.'
                      : wholesale
                          ? 'Shops selling across several categories will show up here.'
                          : 'Shops selling ${widget.categoryName} will show up here.',
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => StoreCard(
              store: main[i],
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => StoreHomeScreen(storeId: main[i].id))),
              onDetails: () => showStoreDetails(context, main[i],
                  repository: _repo),
              onMap: () => openStoreMap(context, main[i],
                  viewerLat: _userLat, viewerLng: _userLng),
            ),
            childCount: main.length,
          ),
        ),
      ),
    ];
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
