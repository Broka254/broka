// BROKA — Store discovery (spec §12/§21, Phase 4)
// 1-column list, modeled directly on trader_list_screen.dart - same
// reasoning applies: ProductGridView is a fixed 2-column grid shared by
// four other screens, so a list layout for this one screen is a smaller,
// safer duplication than adding a layout mode to a shared component.
//
// A store card shows its owner's real seller record (rating once there
// are deals behind it, deals done) - never a store rating, which nothing
// computes (spec §7/§19: never fabricate one).
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
import 'nearby_stores_screen.dart';
import 'store_category_screen.dart';
import 'store_home_screen.dart';
import 'widgets/store_card.dart';
import 'widgets/store_details_view.dart' show showStoreDetails;

class StoreListScreen extends StatefulWidget {
  const StoreListScreen({super.key});
  @override
  State<StoreListScreen> createState() => _StoreListScreenState();
}

class _StoreListScreenState extends State<StoreListScreen> {
  final List<Store> _stores = [];
  bool _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();
  final List<Store> _nearby = [];
  double? _userLat;
  double? _userLng;

  @override
  void initState() {
    super.initState();
    _load();
    _loadNearby();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final query = _searchCtrl.text.trim();
    final result = await storesRepository.listStores(
        search: query.isEmpty ? null : query,
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

  /// 'Stores near you' for the general directory: live GPS first, the
  /// saved session point as fallback - never a stale zero. A missing fix
  /// leaves the section hidden, not a 0 km list.
  Future<void> _loadNearby() async {
    // Live GPS only. The saved session point (ApiService.currentUserLat/Lng)
    // is the signup fix and can be tens of km stale - near you from a stale
    // point is worse than no near you at all.
    double? lat;
    double? lng;
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
    if (!mounted) return;
    if (lat == null || lng == null) return;
    setState(() {
      _userLat = lat;
      _userLng = lng;
    });
    final result = await storesRepository.listStores(
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
          hintText: 'Search stores',
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _load(),
          onCleared: _load,
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
  List<Widget> _nearbySlivers() {
    if (_nearby.isEmpty) return const [];
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
            Text('${_nearby.length} within 25 km of you',
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
              store: _nearby[i],
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => StoreHomeScreen(storeId: _nearby[i].id))),
              onDetails: () => showStoreDetails(context, _nearby[i],
                  repository: storesRepository),
            ),
            childCount: _nearby.length,
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
    if (_stores.isEmpty) {
      final searching = _searchCtrl.text.trim().isNotEmpty;
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
              store: _stores[i],
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => StoreHomeScreen(storeId: _stores[i].id))),
              onDetails: () => showStoreDetails(context, _stores[i],
                  repository: storesRepository),
            ),
            childCount: _stores.length,
          ),
        ),
      ),
    ];
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
