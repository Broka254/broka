// lib/features/categories/presentation/category_zone_screen.dart
// Category Zone: subcategory rail + filter button + dense grid scoped to
// one category (Design Journal Volume 6, Ch.3/Ch.24). Pushed from
// home_screen.dart's category carousel with a zero-duration
// PageRouteBuilder transition — Chapter 3's explicit requirement, so
// tapping a category feels instant rather than like a screen change.
import 'dart:async';
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../widgets/product_grid_view.dart';
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
    super.dispose();
  }

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
    final zoneColors = BrokaColors.zoneGradientFor(widget.categoryName);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: DecoratedBox(
        // Subtle themed wash, not a full colour swap - per the founder's
        // own note on Gemini's proposal: "BROKA identity stays consistent,
        // while each Zone gets its own personality." A radial tint from
        // the zone's own gradient, fading fast into the standard bg, reads
        // as "this Zone" without turning into a five-apps-in-one-app feel.
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.3,
            colors: [
              zoneColors.first.withOpacity(0.16),
              BrokaColors.bg,
            ],
            stops: const [0.0, 0.6],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(zoneColors),
              _buildSearchBar(),
              _buildSubcategoryRail(zoneColors),
              _buildSortRow(),
              Expanded(
                child: ProductGridView(
                  // ProductGridView loads once in initState with no public
                  // reload method, so re-key on everything that should
                  // trigger a refetch (same approach as home_screen.dart).
                  key: ValueKey(
                      '${widget.categoryId}|$_subcategoryId|$_search|$_sort|${_appliedFilters['condition']}|${_appliedFilters['minPrice']}|${_appliedFilters['maxPrice']}|${_categoryAttributes.toString()}'),
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
                  emptyStateBuilder: (_) => _emptyState(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Container(
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.border),
        ),
        child: TextField(
          controller: _searchCtrl,
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            hintText: 'Search in ${widget.categoryName ?? 'this category'}...',
            hintStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 14),
            prefixIcon: const Icon(Icons.search_rounded, color: BrokaColors.textLow, size: 20),
            suffixIcon: _searchCtrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, color: BrokaColors.textLow, size: 18),
                    onPressed: () {
                      _searchCtrl.clear();
                      _onSearchChanged('');
                      setState(() {});
                    },
                  ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }

  Widget _buildSortRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _resultCount == null ? ' ' : '$_resultCount result${_resultCount == 1 ? '' : 's'}',
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 12.5),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _sort,
              dropdownColor: BrokaColors.bgCard,
              icon: const Icon(Icons.expand_more_rounded, color: BrokaColors.textLow, size: 18),
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5),
              items: _sortOptions.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() { _sort = v; _resultCount = null; });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(List<Color> zoneColors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: BrokaColors.textHigh, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        Expanded(
          child: ZoneGlowText(
            '${widget.categoryName ?? 'Category'} Zone',
            gradient: zoneColors,
            fontSize: 22,
          ),
        ),
        Stack(clipBehavior: Clip.none, children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: zoneColors.first.withOpacity(0.35), blurRadius: 16)],
            ),
            child: IconButton(
              icon: const Icon(Icons.tune_rounded, color: BrokaColors.textHigh),
              onPressed: _openFilters,
            ),
          ),
          if (_appliedFilters.values.any((v) => v != null))
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: zoneColors),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ]),
      ]),
    );
  }

  Widget _buildSubcategoryRail(List<Color> zoneColors) {
    if (_loadingSubcategories) return const SizedBox(height: 44);
    if (_subcategories.isEmpty) return const SizedBox(height: 8);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _chip('All', _subcategoryId == null, () => setState(() { _subcategoryId = null; _resultCount = null; }), zoneColors),
          ..._subcategories.map((sub) => _chip(
                sub.name,
                _subcategoryId == sub.id,
                () => setState(() { _subcategoryId = sub.id; _resultCount = null; }),
                zoneColors,
              )),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap, List<Color> zoneColors) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              gradient: selected ? LinearGradient(colors: zoneColors) : null,
              color: selected ? null : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? Colors.transparent : BrokaColors.border),
              boxShadow: selected
                  ? [BoxShadow(color: zoneColors.first.withOpacity(0.45), blurRadius: 12)]
                  : null,
            ),
            child: Text(label, style: TextStyle(
              color: selected ? Colors.white : BrokaColors.textMid,
              fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
              fontSize: 13,
            )),
          ),
        ),
      );

  Widget _emptyState() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('📦', style: TextStyle(fontSize: 48)),
          const SizedBox(height: 12),
          Text('No ${widget.categoryName ?? 'listings'} yet',
              style: const TextStyle(color: BrokaColors.textMid)),
          const SizedBox(height: 4),
          const Text('Try adjusting your filters', style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
        ]),
      );
}
