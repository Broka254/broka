// lib/features/categories/presentation/category_zone_screen.dart
// Category Zone: subcategory rail + filter button + dense grid scoped to
// one category (Design Journal Volume 6, Ch.3/Ch.24). Pushed from
// home_screen.dart's category carousel with a zero-duration
// PageRouteBuilder transition — Chapter 3's explicit requirement, so
// tapping a category feels instant rather than like a screen change.
//
// Category-alignment pass (2026-09-18): the Zone was functionally correct but
// looked like a different application from Home - its own flat radial wash
// instead of the constellation, a search field so dark it disappeared, a
// 22px glowing title that overpowered long category names, and a generic 📦
// in the empty state whatever category you were in. It now shares Home's
// visual system end to end: ConstellationBackground, one CustomScrollView
// with a collapsing pinned header, Home's search/filter control language, a
// 16px content edge, and the same CategoryVisuals resolver for its icon,
// gradient and empty state. The data layer below is untouched - same
// repository calls, same filters, same pagination, same routes.
import 'dart:async';
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../domain/category_search.dart';
import '../domain/category_visual.dart';
import '../../../core/utils/result.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/categories_repository.dart';
import '../domain/models/category.dart';
import 'filter_bottom_sheet.dart';

class CategoryZoneScreen extends StatefulWidget {
  final String categoryId;
  final String? categoryName;
  const CategoryZoneScreen({super.key, required this.categoryId, this.categoryName});

  @override
  State<CategoryZoneScreen> createState() => _CategoryZoneScreenState();
}

class _CategoryZoneScreenState extends State<CategoryZoneScreen> {
  static const _sortOptions = {
    'newest': 'Most Recent',
    'price_low': 'Price: Low to High',
    'price_high': 'Price: High to Low',
  };

  List<Category> _subcategories = [];
  List<CategoryFilterField> _filterFields = [];
  String? _subcategoryId;
  Map<String, dynamic> _appliedFilters = {};
  bool _loadingSubcategories = true;
  String _sort = 'newest';
  int? _resultCount;

  final _searchCtrl = TextEditingController();
  String _search = '';
  Timer? _searchDebounce;

  // One vertical scroll owner for the whole Zone, exactly like Home: the
  // header, search, subcategory rail and sort row share the grid's viewport
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

  /// Pull-to-refresh, matching Home. Refetches the feed and the subcategory
  /// rail, since a newly-seeded subcategory is exactly the kind of thing a
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
    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() { _search = value.trim(); _resultCount = null; });
    });
  }

  /// FilterBottomSheet stores everything (condition, price, and every
  /// category-specific field) in one flat map for its own UI state. The
  /// backend wants condition/price as their own real params and only the
  /// remaining category-specific picks as the generic `attributes` map
  /// (spec §7/§19 — same CategoryFilterField definitions, sent as the
  /// values a listing must match). number_range fields arrive here as a
  /// Flutter RangeValues, which isn't JSON-encodable, so those become a
  /// plain {min,max} map first.
  Map<String, dynamic> get _categoryAttributes {
    const reserved = {'condition', 'minPrice', 'maxPrice'};
    final out = <String, dynamic>{};
    for (final entry in _appliedFilters.entries) {
      if (reserved.contains(entry.key) || entry.value == null) continue;
      final v = entry.value;
      out[entry.key] = v is RangeValues ? {'min': v.start, 'max': v.end} : v;
    }
    return out;
  }

  Future<List<dynamic>> _fetchPage(int page) async {
    final result = await listingsRepository.getListingsPage(
      categoryId: widget.categoryId,
      subcategoryId: _subcategoryId,
      condition: _appliedFilters['condition'] as String?,
      minPrice: (_appliedFilters['minPrice'] as num?)?.toDouble(),
      maxPrice: (_appliedFilters['maxPrice'] as num?)?.toDouble(),
      search: _search.isEmpty ? null : _search,
      sort: _sort,
      attributes: _categoryAttributes,
      limit: 20,
      offset: page * 20,
    );
    return result.fold<List<BrokaListing>>(
      onSuccess: (data) {
        if (mounted && _resultCount != data.total) {
          setState(() => _resultCount = data.total);
        }
        return data.items;
      },
      onFailure: (_, __) => <BrokaListing>[],
    );
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
          // rather than instead of it - it fades to transparent, not to
          // BrokaColors.bg, which is what the previous version did and why
          // the Zone could never have shown a starfield underneath.
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
                    // _ZoneHeaderDelegate moved to
                    // widgets/collapsing_screen_header.dart when Trending,
                    // Auctions, Traders and Stores needed the same header -
                    // four more copies of it is how the category tables went
                    // wrong. The Zone's only difference is the filter button
                    // it hands to `trailing`.
                    delegate: CollapsingScreenHeader(
                      title: '${widget.categoryName ?? 'Category'} Zone',
                      emoji: visual.emoji,
                      gradient: zoneColors,
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
                  SliverToBoxAdapter(child: _buildSubcategoryRail(zoneColors)),
                  SliverToBoxAdapter(child: _buildSortRow()),
                  ProductGridView(
                    // ProductGridView loads once in initState with no public
                    // reload method, so re-key on everything that should
                    // trigger a refetch (same approach as home_screen.dart).
                    key: ValueKey(
                        '${widget.categoryId}|$_subcategoryId|$_search|$_sort|${_appliedFilters['condition']}|${_appliedFilters['minPrice']}|${_appliedFilters['maxPrice']}|${_categoryAttributes.toString()}'),
                    sliver: true,
                    controller: _gridController,
                    // The same 16px page gutter as the header, search, rail
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

  /// Home's search control, with the Zone's own placeholder. The previous
  /// version used BrokaColors.textLow for the hint on a bgCard field, which
  /// is roughly 1.4:1 - the placeholder was the one piece of text telling the
  /// user what the field searched, and it was invisible.
  Widget _buildSearchBar() {
    final narrow = _narrow;
    final height = narrow ? 42.0 : 44.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.86),
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.35)),
        ),
        child: Row(children: [
          const Icon(Icons.search_rounded, size: 18, color: BrokaColors.textMid),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              style: TextStyle(
                  color: BrokaColors.textHigh, fontSize: narrow ? 12.5 : 13),
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search in ${widget.categoryName ?? 'this category'}...',
                hintStyle: TextStyle(
                    color: BrokaColors.textMid, fontSize: narrow ? 12 : 12.5),
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_searchCtrl.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchCtrl.clear();
                _onSearchChanged('');
                setState(() {});
              },
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.close_rounded,
                    color: BrokaColors.textMid, size: 17),
              ),
            ),
        ]),
      ),
    );
  }

  /// Readable but secondary (brief §9). Was textLow on both halves, which put
  /// the result count - the one number telling you whether your filters found
  /// anything - below the legibility floor.
  Widget _buildSortRow() {
    final narrow = _narrow;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _resultCount == null
                  ? ' '
                  : '$_resultCount result${_resultCount == 1 ? '' : 's'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: BrokaColors.textMid,
                  fontSize: narrow ? 12 : 12.5,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          // A bare DropdownButton lays itself out to its WIDEST menu item, not
          // to the one that is selected - so "Most Recent" reserved the width
          // of "Price: High to Low" and this Row overflowed on a 320dp phone
          // (and on a 390dp one at a large accessibility text scale). Bounding
          // it and letting it expand inside that bound means the control is
          // sized by the space available, and the selected label ellipsises
          // instead of pushing the result count off the screen.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: narrow ? 140 : 168),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _sort,
                isDense: true,
                isExpanded: true,
                alignment: Alignment.centerRight,
                dropdownColor: BrokaColors.bgCard,
                icon: const Icon(Icons.expand_more_rounded,
                    color: BrokaColors.textMid, size: 18),
                style: TextStyle(
                    color: BrokaColors.textMid,
                    fontSize: narrow ? 12 : 12.5,
                    fontWeight: FontWeight.w600),
                // The closed button renders these; the menu renders `items`.
                selectedItemBuilder: (_) => _sortOptions.values
                    .map((label) => Align(
                          alignment: Alignment.centerRight,
                          child: Text(label,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                items: _sortOptions.entries
                    .map((e) => DropdownMenuItem(
                        value: e.key,
                        child: Text(e.value, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() { _sort = v; _resultCount = null; });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubcategoryRail(List<Color> zoneColors) {
    if (_loadingSubcategories) return const SizedBox(height: 46);
    // "Other" genuinely has no subcategories (see seed.py) - an empty rail is
    // correct there, not a bug, so it collapses rather than showing a lone
    // "All" chip that filters nothing.
    if (_subcategories.isEmpty) return const SizedBox(height: 4);
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        // 12 here + each chip's own 4px margin puts the first chip's edge at
        // 16, the same content edge as everything above and below it.
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          _chip('All', _subcategoryId == null,
              () => setState(() { _subcategoryId = null; _resultCount = null; }),
              zoneColors),
          // Subcategories arrive in the backend's curated order, so the
          // ones sellers use most lead - Mtumba first in Fashion - and a
          // highlighted one (SubcategoryHighlights) carries its emoji and a
          // glow even when it isn't selected.
          ..._subcategories.map((sub) => _chip(
                sub.name,
                _subcategoryId == sub.id,
                () => setState(() { _subcategoryId = sub.id; _resultCount = null; }),
                zoneColors,
                highlight: SubcategoryHighlights.of(sub.name),
              )),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap,
          List<Color> zoneColors, {({String emoji, String label})? highlight}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              gradient: selected ? LinearGradient(colors: zoneColors) : null,
              color: selected ? null : BrokaColors.bgCard.withOpacity(0.86),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : (highlight != null ? zoneColors.first.withOpacity(0.8) : BrokaColors.border)),
              boxShadow: selected || highlight != null
                  ? [BoxShadow(
                      color: zoneColors.first.withOpacity(selected ? 0.38 : 0.22), blurRadius: 12)]
                  : null,
            ),
            child: Center(
              widthFactor: 1,
              child: Text(highlight == null ? label : '${highlight.emoji} $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? Colors.white : BrokaColors.textMid,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: _narrow ? 12 : 12.5,
                  )),
            ),
          ),
        ),
      );
}

