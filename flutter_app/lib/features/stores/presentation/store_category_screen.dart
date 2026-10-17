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
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../widgets/broka_search_field.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../categories/domain/category_visual.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import '../domain/store_categories.dart';
import 'store_home_screen.dart';
import 'widgets/store_card.dart';
import 'widgets/store_details_view.dart' show showStoreDetails;

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
  const StoreCategoryScreen({super.key, required this.categoryName});
  final String categoryName;

  @override
  State<StoreCategoryScreen> createState() => _StoreCategoryScreenState();
}

class _StoreCategoryScreenState extends State<StoreCategoryScreen> {
  final List<Store> _stores = [];
  bool _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();
  final _scrollController = ScrollController();
  final List<Store> _nearby = [];
  double? _userLat;
  double? _userLng;

  CategoryVisual get _visual => StoreCategories.visualFor(widget.categoryName);

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
      category: widget.categoryName,
      lat: _userLat,
      lng: _userLng,
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
    double? lat = ApiService.currentUserLat;
    double? lng = ApiService.currentUserLng;
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
    if (!mounted || lat == null || lng == null) return;
    setState(() {
      _userLat = lat;
      _userLng = lng;
    });
    final result = await storesRepository.listStores(
        category: widget.categoryName,
        lat: lat,
        lng: lng,
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
          hintText: 'Search stores',
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _load(),
          onCleared: _load,
        ),
      );

  List<Widget> _nearbySlivers() {
    if (_nearby.isEmpty) return const [];
    return [
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Text('Stores near you',
              style: TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.1)),
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
              action:
                  OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ),
          ),
        ),
      ];
    }
    if (_stores.isEmpty) {
      final searching = _searchCtrl.text.trim().isNotEmpty;
      final wholesale = StoreCategories.isWholesaleFacet(widget.categoryName);
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: BrokaEmptyState(
              emoji: visual.emoji,
              gradient: visual.gradient,
              headline: searching
                  ? 'No stores match "${_searchCtrl.text.trim()}"'
                  : wholesale
                      ? 'No wholesale stores yet'
                      : 'No ${widget.categoryName} stores yet',
              body: searching
                  ? 'Try a shorter or different search'
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
