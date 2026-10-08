// lib/features/categories/presentation/category_zone_screen.dart
// Category Zone: the category's types of item + filter button + dense grid
// scoped to one category (Design Journal Volume 6, Ch.3/Ch.24). Pushed from
// Home's category row with a zero-duration transition (category_navigation
// .dart) — Chapter 3's explicit requirement, so tapping a category feels
// instant rather than like a screen change.
//
// Category-alignment pass (2026-09-18): the Zone shares Home's visual system
// end to end: ConstellationBackground, one CustomScrollView with a collapsing
// pinned header, Home's search/filter control language, a 16px content edge,
// and the same CategoryVisuals resolver for its icon, gradient and empty
// state.
//
// Types of item get screens of their own (2026-10-08). The Zone used to be
// the only screen a category had, with its types as a row of chips filtering
// one grid - so "Phones" was a chip among thirteen in Electronics, and there
// was nowhere to filter phones by brand. The chips are now the website's
// photo cards, each opening its own SubcategoryScreen (brand filters, its own
// details in the filter sheet); "See all" lays every type out at once. The
// header is the category's picture, collapsing to the bar it always was. The
// grid below stays the whole category, for someone who came to browse it.
import 'dart:async';
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../widgets/artwork_hero_header.dart';
import '../../../widgets/broka_search_field.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../domain/category_search.dart';
import '../domain/category_visual.dart';
import '../domain/subcategory_visual.dart';
import '../../../core/utils/result.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/categories_repository.dart';
import '../domain/models/category.dart';
import 'category_navigation.dart';
import 'filter_bottom_sheet.dart';
import 'widgets/category_art_card.dart';
import 'widgets/feed_sort_row.dart';

class CategoryZoneScreen extends StatefulWidget {
  final String categoryId;
  final String? categoryName;
  const CategoryZoneScreen({super.key, required this.categoryId, this.categoryName});

  @override
  State<CategoryZoneScreen> createState() => _CategoryZoneScreenState();
}

class _CategoryZoneScreenState extends State<CategoryZoneScreen> {
  List<Category> _subcategories = [];
  List<CategoryFilterField> _filterFields = [];
  Map<String, dynamic> _appliedFilters = {};
  bool _loadingSubcategories = true;
  String _sort = 'newest';
  int? _resultCount;

  final _searchCtrl = TextEditingController();
  String _search = '';
  Timer? _searchDebounce;

  // One vertical scroll owner for the whole Zone, exactly like Home: the
  // header, search, types of item and sort row share the grid's viewport
  // instead of squeezing it into an Expanded that never grows.
  final _scrollController = ScrollController();
  final _gridController = ProductGridController();

  @override
  void initState() {
    super.initState();
    _loadSubcategories();
    _loadFilters();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Pull-to-refresh, matching Home. Refetches the feed and the types of
  /// item, since a newly-seeded subcategory is exactly the kind of thing a
  /// user pulls to look for.
  Future<void> _onRefresh() async {
    await Future.wait([
      _gridController.refresh(),
      _loadSubcategories(),
    ]);
  }

  /// Small-Android breakpoint, the same 360dp Home uses so both screens step
  /// their type down together.
  bool get _narrow => MediaQuery.sizeOf(context).width < 360;

  bool get _hasActiveFilters => _appliedFilters.values.any((v) => v != null);

  Future<void> _loadSubcategories() async {
    final result = await categoriesRepository.getSubcategories(widget.categoryId);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _subcategories = data;
        _loadingSubcategories = false;
      }),
      onFailure: (_, __) => setState(() => _loadingSubcategories = false),
    );
  }

  Future<void> _loadFilters() async {
    final result = await categoriesRepository.getFilters(widget.categoryId);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() => _filterFields = data),
      onFailure: (_, __) {},
    );
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => FilterBottomSheet(
        categoryId: widget.categoryId,
        fields: _filterFields,
        initial: _appliedFilters,
      ),
    );
    if (result != null && mounted) setState(() { _appliedFilters = result; _resultCount = null; });
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 450), () => _applySearch(value));
  }

  /// Pressing search, or clearing the field, shouldn't wait out the debounce.
  void _applySearch(String value) {
    _searchDebounce?.cancel();
    if (!mounted || value.trim() == _search) return;
    setState(() { _search = value.trim(); _resultCount = null; });
  }

  void _openType(Category sub) => openSubcategory(context,
      parentId: widget.categoryId, parentName: widget.categoryName, subcategory: sub);

  /// Everything the feed depends on. The grid is keyed on it, and a page only
  /// updates the result count if it is still the feed on screen - otherwise a
  /// slow answer for "sam" could label the results for "samsung".
  String get _feedKey =>
      '${widget.categoryId}|$_search|$_sort|${_appliedFilters['condition']}|${_appliedFilters['minPrice']}|${_appliedFilters['maxPrice']}|${filterAttributes(_appliedFilters).toString()}';

  Future<List<dynamic>> _fetchPage(int page) async {
    final feed = _feedKey;
    final result = await listingsRepository.getListingsPage(
      categoryId: widget.categoryId,
      condition: _appliedFilters['condition'] as String?,
      minPrice: (_appliedFilters['minPrice'] as num?)?.toDouble(),
      maxPrice: (_appliedFilters['maxPrice'] as num?)?.toDouble(),
      search: _search.isEmpty ? null : _search,
      sort: _sort,
      attributes: filterAttributes(_appliedFilters),
      limit: 20,
      offset: page * 20,
    );
    // A failure is thrown, not turned into an empty page: as an empty page a
    // dropped connection read "No Electronics listings yet - try adjusting
    // your filters", and ended pagination for good. ProductGridView shows a
    // thrown error with a Retry button.
    switch (result) {
      case Success(:final data):
        if (mounted && feed == _feedKey && _resultCount != data.total) {
          setState(() => _resultCount = data.total);
        }
        return data.items;
      case Failure(:final message):
        throw ZoneFeedFailure(message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visual = CategoryVisuals.resolve(widget.categoryName);
    final zoneColors = visual.gradient;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // Same constellation field as Home and the auth screens. The Zone is a
      // deeper screen inside BROKA, not a place with its own backdrop.
      body: ConstellationBackground(
        child: DecoratedBox(
          // The category's personality, as a wash OVER the constellation
          // rather than instead of it.
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.25,
              colors: [
                zoneColors.first.withOpacity(0.15),
                Colors.transparent,
              ],
              stops: const [0.0, 0.62],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: RefreshIndicator(
              onRefresh: _onRefresh,
              color: BrokaColors.gold,
              backgroundColor: BrokaColors.bgCard,
              displacement: 72,
              child: CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: ArtworkHeroHeader(
                      title: '${widget.categoryName ?? 'Category'} Zone',
                      emoji: visual.emoji,
                      gradient: zoneColors,
                      assetPath: visual.assetPath,
                      onBack: () => Navigator.pop(context),
                      narrow: _narrow,
                      textScale: MediaQuery.textScalerOf(context)
                          .scale(1.0)
                          .clamp(1.0, 1.35)
                          .toDouble(),
                      trailingKey: _hasActiveFilters,
                      trailing: BrokaHeaderButton(
                        icon: Icons.tune_rounded,
                        onTap: _openFilters,
                        active: _hasActiveFilters,
                        dotGradient: zoneColors,
                        tooltip: 'Filters',
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(child: _buildSearchBar()),
                  SliverToBoxAdapter(child: _buildTypes(visual)),
                  if (_subcategories.isNotEmpty)
                    SliverToBoxAdapter(child: _buildFeedHeading()),
                  SliverToBoxAdapter(
                    child: FeedSortRow(
                      sort: _sort,
                      resultCount: _resultCount,
                      narrow: _narrow,
                      onSortChanged: (v) => setState(() { _sort = v; _resultCount = null; }),
                    ),
                  ),
                  ProductGridView(
                    // ProductGridView loads once in initState with no public
                    // reload method, so re-key on everything that should
                    // trigger a refetch (same approach as home_screen.dart).
                    key: ValueKey(_feedKey),
                    sliver: true,
                    controller: _gridController,
                    // The same 16px page gutter as the header, search, cards
                    // and sort row above it.
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    fetchPage: _fetchPage,
                    onTapItem: (item) => Navigator.pushNamed(
                      context,
                      '/product',
                      // BrokaListing isn't recognised by ProductScreen's
                      // `args is Listing` check (that's the older model from
                      // lib/models/listing.dart) - the {'listingId': ...} form
                      // makes it fetch fresh instead, same as a relaunch.
                      arguments: {'listingId': (item as BrokaListing).id},
                    ),
                    onViewStore: (storeId, storeSlug) => Navigator.pushNamed(
                        context, '/store-view', arguments: {'storeId': storeId}),
                    emptyStateBuilder: (_) => BrokaEmptyState(
                      emoji: visual.emoji,
                      gradient: zoneColors,
                      headline:
                          'No ${widget.categoryName ?? 'listings'} listings yet',
                      body: 'Try adjusting your filters',
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The Zone's search box. BrokaSearchField rather than a copy of Home's
  /// header pill: at 42px with 13px text the pill was too small to read back
  /// what had been typed. The placeholder still names the category the user
  /// is in.
  Widget _buildSearchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: BrokaSearchField(
          controller: _searchCtrl,
          hintText: 'Search in ${widget.categoryName ?? 'this category'}...',
          onChanged: _onSearchChanged,
          onSubmitted: _applySearch,
          onCleared: () => _applySearch(''),
        ),
      );

  double get _typeCardHeight =>
      (_narrow ? 92.0 : 98.0) + 24 * (MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3) - 1);

  /// The category's types of item, as photo cards in the backend's curated
  /// order (the ones sellers use most first - Mtumba leads Fashion), each
  /// opening its own screen. "Other" genuinely has none (see seed.py), so
  /// the section isn't there at all rather than a heading over nothing.
  Widget _buildTypes(CategoryVisual visual) {
    final heading = 13 * 1.2 * MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3) + 8;
    if (_loadingSubcategories) return SizedBox(height: _typeCardHeight + heading + 22);
    if (_subcategories.isEmpty) return const SizedBox(height: 4);
    final name = widget.categoryName ?? 'this category';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Expanded(
              child: Text('Shop $name by type',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w800)),
            ),
            GestureDetector(
              key: const Key('zone-types-see-all'),
              behavior: HitTestBehavior.opaque,
              onTap: () => openAllSubcategories(context,
                  parentId: widget.categoryId,
                  parentName: widget.categoryName,
                  subcategories: _subcategories),
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text('See all ${_subcategories.length} ›',
                    style: const TextStyle(
                        color: BrokaColors.gold,
                        fontSize: 12.5,
                        height: 1.2,
                        fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ),
        SizedBox(
          height: _typeCardHeight + 6,
          child: ListView.builder(
            key: const Key('zone-types'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 6, 6),
            itemCount: _subcategories.length,
            itemBuilder: (_, i) {
              final sub = _subcategories[i];
              final highlight = SubcategoryHighlights.of(sub.name);
              return Padding(
                padding: const EdgeInsets.only(right: 10),
                child: CategoryArtCard(
                  key: Key('zone-type-${sub.name}'),
                  label: sub.name,
                  emoji: highlight?.emoji ?? visual.emoji,
                  gradient: visual.gradient,
                  assetPath: SubcategoryVisuals.resolve(widget.categoryName, sub.name).assetPath,
                  caption: highlight?.label,
                  width: _narrow ? 128 : 140,
                  height: _typeCardHeight,
                  labelSize: _narrow ? 12 : 12.5,
                  onTap: () => _openType(sub),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }

  /// Says the grid below is the whole category, not the type last looked at.
  Widget _buildFeedHeading() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
        child: Text('Everything in ${widget.categoryName ?? 'this category'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w800)),
      );
}

/// FilterBottomSheet stores everything (condition, price, and every
/// category-specific field) in one flat map for its own UI state. The
/// backend wants condition/price as their own real params and only the
/// remaining category-specific picks as the generic `attributes` map
/// (spec §7/§19 — same CategoryFilterField definitions, sent as the
/// values a listing must match). number_range fields arrive here as a
/// Flutter RangeValues, which isn't JSON-encodable, so those become a
/// plain {min,max} map first.
Map<String, dynamic> filterAttributes(Map<String, dynamic> applied) {
  const reserved = {'condition', 'minPrice', 'maxPrice'};
  final out = <String, dynamic>{};
  for (final entry in applied.entries) {
    if (reserved.contains(entry.key) || entry.value == null) continue;
    final v = entry.value;
    if (v is String && v.trim().isEmpty) continue;
    out[entry.key] = v is RangeValues ? {'min': v.start, 'max': v.end} : v;
  }
  return out;
}

/// A Zone feed page that failed to load, thrown so ProductGridView shows its
/// retry state rather than the empty state.
class ZoneFeedFailure implements Exception {
  ZoneFeedFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
