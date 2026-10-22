// BROKA — Stores near you
//
// The store directory (Image 3's Stores screen) scoped to where you are
// standing: shops within 25 km of a live GPS fix, nearest first, with
// the same search, category rail and place filters as the directory -
// picking "Electronics" here shows only nearby electronics shops.
//
// The position is a live GPS fix, never the saved signup point - near
// you from a stale point is worse than no list at all. No fix, no list:
// the screen asks for location instead of guessing. A shop's distance
// comes from its own pin when it has one (setup wizard), else its
// owner's point - see backend _store_distance_km.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../widgets/broka_search_field.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import '../domain/store_categories.dart';
import 'store_home_screen.dart';
import 'store_map_screen.dart';
import 'widgets/distance_filter.dart';
import 'widgets/store_card.dart';
import 'widgets/store_details_view.dart' show showStoreDetails;
import 'widgets/store_location_filter.dart';

class NearbyStoresScreen extends StatefulWidget {
  const NearbyStoresScreen({super.key, this.repository});

  final StoresRepository? repository;

  @override
  State<NearbyStoresScreen> createState() => _NearbyStoresScreenState();
}

enum _Stage { locating, needsLocation, ready, loadFailed }

class _NearbyStoresScreenState extends State<NearbyStoresScreen> {
  StoresRepository get _repo => widget.repository ?? storesRepository;

  _Stage _stage = _Stage.locating;
  final List<Store> _stores = [];

  /// The nearest shops overall, shown only when none is within 25 km:
  /// an honest "nearest to you" beats a dead end (the shops exist - they
  /// are just further away, or their distance is not known yet).
  final List<Store> _nearest = [];
  bool _nearestLoading = false;
  final _scrollController = ScrollController();
  final _searchCtrl = TextEditingController();
  /// Search-as-you-type, on the store page's 400 ms. Filtering by place
  /// also runs through here, so a typed or cleared search never leaves
  /// the list showing the previous query's shops.
  Timer? _searchDebounce;

  double? _userLat;
  double? _userLng;
  String? _category;
  String? _county;
  String? _subcounty;

  /// How far still counts as near. 25 km by default; a buyer in a dense town
  /// can pull it to 5, or widen it to 50 - null is "any distance", which is
  /// the directory's list with the closest first.
  double? _radiusKm = Store.nearRadiusKm;
  bool _fetching = false;

  bool get _filtersActive =>
      _category != null || _county != null || _searchCtrl.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _fetch();
    });
  }

  Future<void> _load() async {
    setState(() => _stage = _Stage.locating);
    double? lat;
    double? lng;
    try {
      var enabled = await Geolocator.isLocationServiceEnabled();
      var perm = enabled ? await Geolocator.checkPermission() : LocationPermission.denied;
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() => _stage = _Stage.needsLocation);
        return;
      }
      if (!enabled) {
        if (!mounted) return;
        setState(() => _stage = _Stage.needsLocation);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {
      if (!mounted) return;
      setState(() => _stage = _Stage.needsLocation);
      return;
    }
    _userLat = lat;
    _userLng = lng;
    await _fetch();
  }

  /// (Re)runs the nearby query with the current filters. Needs the fix
  /// from [_load]; filter changes call this directly.
  Future<void> _fetch() async {
    final lat = _userLat;
    final lng = _userLng;
    if (lat == null || lng == null) return;
    setState(() => _fetching = true);
    final query = _searchCtrl.text.trim();
    final result = await _repo.listStores(
      search: query.isEmpty ? null : query,
      category: _category,
      county: _county,
      subcounty: _subcounty,
      lat: lat,
      lng: lng,
      maxDistanceKm: _radiusKm,
      nearestFirst: true,
      limit: 50,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) {
        setState(() {
          _stores..clear()..addAll(data);
          _stage = _Stage.ready;
          _fetching = false;
          if (data.isNotEmpty || _filtersActive) _nearest.clear();
        });
        // A radius of any distance cannot come back empty on its own: there
        // is no wider list to fall back to.
        if (data.isEmpty && !_filtersActive && _radiusKm != null) _fetchNearest();
      },
      onFailure: (_, __) => setState(() {
        _stage = _Stage.loadFailed;
        _fetching = false;
      }),
    );
  }

  /// Nearest shops at any distance, for the empty-25 km fallback. Same
  /// viewer point, no radius: the server sorts nearest first and shops
  /// with no known distance last.
  Future<void> _fetchNearest() async {
    final lat = _userLat;
    final lng = _userLng;
    if (lat == null || lng == null) return;
    setState(() => _nearestLoading = true);
    final result = await _repo.listStores(
      lat: lat, lng: lng, nearestFirst: true, limit: 10,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _nearest..clear()..addAll(data);
        _nearestLoading = false;
      }),
      onFailure: (_, __) => setState(() => _nearestLoading = false),
    );
  }

  void _clearFilters() {
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    setState(() {
      _category = null;
      _county = null;
      _subcounty = null;
      _radiusKm = Store.nearRadiusKm;
    });
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _load,
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
                    title: 'Near you',
                    emoji: '📍',
                    gradient: const [BrokaColors.gold, BrokaColors.neonCyan],
                    onBack: () => Navigator.pop(context),
                    narrow: media.size.width < 360,
                    textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                  ),
                ),
                if (_stage == _Stage.ready) ...[
                  SliverToBoxAdapter(child: _searchBar()),
                  SliverToBoxAdapter(child: _categoryRail()),
                  SliverToBoxAdapter(
                    child: StoreLocationFilter(
                      county: _county,
                      subcounty: _subcounty,
                      maxDistanceKm: _radiusKm,
                      onClear: _clearFilters,
                      onDistanceChanged: (value) {
                        setState(() => _radiusKm = value);
                        _fetch();
                      },
                      onChanged: (county, subcounty) {
                        setState(() {
                          _county = county;
                          _subcounty = subcounty;
                        });
                        _fetch();
                      },
                    ),
                  ),
                ],
                ..._bodySlivers(),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
        child: BrokaSearchField(
          controller: _searchCtrl,
          hintText: 'Search nearby shops and products',
          onChanged: _onSearchChanged,
          onSubmitted: (_) {
            _searchDebounce?.cancel();
            _fetch();
          },
          onCleared: () {
            _searchDebounce?.cancel();
            _fetch();
          },
        ),
      );

  /// Nearby, by kind of shop: "All" plus the online-store categories.
  Widget _categoryRail() => SizedBox(
        height: 40,
        child: ListView(
          key: const Key('nearby-category-rail'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
          children: [
            _CategoryChip(
              label: 'All',
              selected: _category == null,
              onTap: () {
                setState(() => _category = null);
                _fetch();
              },
            ),
            for (final name in StoreCategories.onlineRail)
              _CategoryChip(
                key: Key('nearby-category-$name'),
                label: '${StoreCategories.visualFor(name).emoji}  $name',
                selected: _category == name,
                onTap: () {
                  setState(() => _category = name);
                  _fetch();
                },
              ),
          ],
        ),
      );

  List<Widget> _bodySlivers() {
    switch (_stage) {
      case _Stage.locating:
        return const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator(color: BrokaColors.gold)),
          ),
        ];
      case _Stage.needsLocation:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.location_off_outlined, size: 44, color: BrokaColors.textMid),
                const SizedBox(height: 14),
                const Text('Turn on location to see stores near you',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text('Near you starts within 25 km of where you are standing - '
                    'you can change the radius once it knows where you are.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
                const SizedBox(height: 18),
                FilledButton.icon(
                  key: const Key('nearby-use-location'),
                  onPressed: () async {
                    await Geolocator.openLocationSettings();
                    _load();
                  },
                  icon: const Icon(Icons.my_location_rounded, size: 18),
                  label: const Text('Use my location'),
                ),
              ]),
            ),
          ),
        ];
      case _Stage.loadFailed:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.cloud_off_outlined, size: 44, color: BrokaColors.textMid),
                const SizedBox(height: 14),
                const Text('Stores near you could not load',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                FilledButton(
                  key: const Key('nearby-retry'),
                  onPressed: _load,
                  child: const Text('Try again'),
                ),
              ]),
            ),
          ),
        ];
      case _Stage.ready:
        if ((_fetching || _nearestLoading) && _stores.isEmpty && _nearest.isEmpty) {
          return const [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator(color: BrokaColors.gold)),
            ),
          ];
        }
        if (_stores.isEmpty && _nearest.isNotEmpty) {
          return [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: Row(children: [
                  const Icon(Icons.storefront_outlined, size: 16, color: BrokaColors.gold),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        'No stores within ${formatDistanceKm(_radiusKm ?? Store.nearRadiusKm)}'
                        ' - nearest to you',
                        key: const Key('nearby-nearest-header'),
                        style: const TextStyle(color: BrokaColors.gold, fontSize: 12,
                            fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => StoreCard(
                    store: _nearest[i],
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => StoreHomeScreen(storeId: _nearest[i].id))),
                    onDetails: () => showStoreDetails(context, _nearest[i],
                        repository: _repo),
                    onMap: () => openStoreMap(context, _nearest[i],
                        viewerLat: _userLat, viewerLng: _userLng),
                  ),
                  childCount: _nearest.length,
                ),
              ),
            ),
          ];
        }
        if (_stores.isEmpty) {
          return [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.storefront_outlined, size: 44, color: BrokaColors.textMid),
                  const SizedBox(height: 14),
                  Text(
                      _filtersActive
                          ? 'No nearby stores match those filters'
                          : 'No stores within '
                              '${formatDistanceKm(_radiusKm ?? Store.nearRadiusKm)} of you',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(
                      _filtersActive
                          ? 'Try a different category or place - or clear the filters.'
                          : 'Shops further away are under Shop by category.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45)),
                  if (_filtersActive) ...[
                    const SizedBox(height: 18),
                    FilledButton(
                      key: const Key('nearby-clear-filters'),
                      onPressed: _clearFilters,
                      child: const Text('Clear filters'),
                    ),
                  ],
                ]),
              ),
            ),
          ];
        }
        return [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Row(children: [
                const Icon(Icons.near_me_rounded, size: 16, color: BrokaColors.gold),
                const SizedBox(width: 6),
                Text(
                    _radiusKm == null
                        ? '${_stores.length} nearest to you'
                        : '${_stores.length} within ${formatDistanceKm(_radiusKm!)} of you',
                    style: const TextStyle(color: BrokaColors.gold, fontSize: 12,
                        fontWeight: FontWeight.w700)),
                if (_fetching) ...[
                  const SizedBox(width: 10),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(color: BrokaColors.gold, strokeWidth: 2),
                  ),
                ],
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => StoreCard(
                  store: _stores[i],
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => StoreHomeScreen(storeId: _stores[i].id))),
                  onDetails: () => showStoreDetails(context, _stores[i],
                      repository: _repo),
                  onMap: () => openStoreMap(context, _stores[i],
                      viewerLat: _userLat, viewerLng: _userLng),
                ),
                childCount: _stores.length,
              ),
            ),
          ),
        ];
    }
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Semantics(
          selected: selected,
          button: true,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? BrokaColors.gold.withOpacity(0.18)
                    : BrokaColors.bgCard.withOpacity(0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? BrokaColors.gold : BrokaColors.border.withOpacity(0.8),
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Text(label,
                  style: TextStyle(
                      color: selected ? BrokaColors.textHigh : BrokaColors.textMid,
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
            ),
          ),
        ),
      );
}
