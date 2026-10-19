// BROKA — Store discovery (spec §12/§21, Phase 4)
// 1-column list, modeled directly on trader_list_screen.dart - same
// reasoning applies: ProductGridView is a fixed 2-column grid shared by
// four other screens, so a list layout for this one screen is a smaller,
// safer duplication than adding a layout mode to a shared component.
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
    setState(() { _loading = _stores.isEmpty; _error = null; });
    final query = _searchCtrl.text.trim();
    final result = await _repo.listStores(
        search: query.isEmpty ? null : query,
        county: _county,
        subcounty: _subcounty,
        lat: _userLat,
        lng: _userLng);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _stores..clear()..addAll(data);
        _loading = false;
      }),
      onFailure: (msg, __) => setState(() { _error = msg; _loading = false; }),
    );
  }

  /// True while the user is narrowing the list. The nearby rail is a
  /// shortcut, not a second catalogue: a shelf of unfiltered shops above a
  /// filtered result set contradicts what was asked for, so it is hidden
  /// for the duration.
  bool get _filtersActive =>
      _searchCtrl.text.trim().isNotEmpty || _county != null || _subcounty != null;

  /// The shops shown in the 'Stores near you' rail, and therefore excluded
  /// from 'All stores' below it.
  ///
  /// This is the duplicate fix. The two lists are fetched independently -
  /// one with a 25 km radius, one without - and nothing used to remove the
  /// nearby ids from the main list, so every shop within 25 km was drawn
  /// twice on one screen: once in the rail, once under 'All stores'. The
  /// rail is the same shops, presented earlier, so the main list continues
  /// below it rather than repeating it.
  List<Store> get _nearbyRail => _filtersActive ? const [] : _nearby.take(5).toList();

  /// Every store in the main list except the ones already in the rail.
  List<Store> get _mainList {
    final shown = {for (final s in _nearbyRail) s.id};
    return [for (final s in _stores) if (!shown.contains(s.id)) s];
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
        lat: lat, lng: lng,
        maxDistanceKm: Store.nearRadiusKm,
        nearestFirst: true, limit: 10);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _nearby..clear()..addAll(data.take(5));
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
                _visual.gradient.first.withOpacity(0.15),
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

  /// Every rail entry as Home draws one (CategoryArtCard), so a directory
  /// of many shops narrows the way products do: pick the kind of shop and
  /// its screen opens with only those stores. Online stores browse by the
  /// goods rail only - Property, Automobiles, Land, Services and Other are
  /// dealer/agent trades, not online-store listing categories.
  Widget _categoryRail() {
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final cardWidth = narrow ? 112.0 : 122.0;
    final cardHeight = (narrow ? 84.0 : 88.0) + 24 * (MediaQuery.textScalerOf(context)
        .scale(1.0)
        .clamp(1.0, 1.3) - 1);
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

  Widget _listHeading() => const Padding(
        padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Text('All stores',
            style: TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.1)),
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
                  : _visual.emptyHeadline,
              body: searching
                  ? 'Try a shorter or different search'
                  : _visual.emptyBody,
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
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
