// lib/features/categories/presentation/subcategory_screen.dart
//
// One type of item - "Phones" in Electronics - on a screen of its own
// (2026-10-08). Before this a type was a chip on its category's Zone, and
// nothing narrowed a type further: a buyer after a Samsung scrolled every
// phone, laptop and charger in Electronics, and a seller of phones competed
// with all of them. Here the type's own picture heads the screen, its brands
// lead as one-tap filters (the makes, for vehicles), and the filter sheet
// holds the type's own details - storage, RAM, mileage - rather than the
// category's.
//
// Which filter leads: the type's brand or make field, which carries the
// brands sellers list most (backend seed.py BRAND_SUGGESTIONS); a type
// without brands (Houses, Land, Mtumba) leads with its first closed list of
// choices instead (title deed, grade), and one with neither has no row. The
// brand a seller typed is filed under these same spellings by the server, so
// "Samsung" finds "samsung galaxy a54" too.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../widgets/artwork_hero_header.dart';
import '../../../widgets/broka_search_field.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/categories_repository.dart';
import '../domain/models/category.dart';
import '../domain/subcategory_visual.dart';
import 'category_zone_screen.dart' show ZoneFeedFailure, filterAttributes;
import 'filter_bottom_sheet.dart';
import 'widgets/feed_sort_row.dart';

class SubcategoryScreen extends StatefulWidget {
  const SubcategoryScreen({
    super.key,
    required this.parentId,
    required this.parentName,
    required this.subcategory,
  });

  final String parentId;
  final String? parentName;
  final Category subcategory;

  /// The field a type's buyers filter by first, from its filter fields:
  /// its brand or make when it has brands to offer, else its first closed
  /// list of choices, else none.
  static CategoryFilterField? leadingFacet(List<CategoryFilterField> fields) {
    bool offers(CategoryFilterField f) => (f.options ?? const []).isNotEmpty;
    for (final name in const ['make', 'brand']) {
      final field = fields.where((f) => f.fieldName == name && offers(f)).firstOrNull;
      if (field != null) return field;
    }
    return fields.where((f) => f.fieldType == 'select' && offers(f)).firstOrNull;
  }

  @override
  State<SubcategoryScreen> createState() => _SubcategoryScreenState();
}

class _SubcategoryScreenState extends State<SubcategoryScreen> {
  List<CategoryFilterField> _fields = [];
  bool _loadingFields = true;

  /// The leading facet's chosen value ("Samsung"), or null for all of them.
  String? _facetValue;
  Map<String, dynamic> _appliedFilters = {};
  String _sort = 'newest';
  int? _resultCount;

  final _searchCtrl = TextEditingController();
  String _search = '';
  Timer? _searchDebounce;

  final _scrollController = ScrollController();
  final _gridController = ProductGridController();

  Category get _sub => widget.subcategory;
  bool get _narrow => MediaQuery.sizeOf(context).width < 360;

  CategoryFilterField? get _facet => SubcategoryScreen.leadingFacet(_fields);

  /// Everything but the leading facet goes in the filter sheet: the facet has
  /// its own row, and two controls for one value would disagree.
  List<CategoryFilterField> get _sheetFields =>
      _fields.where((f) => f.fieldName != _facet?.fieldName).toList();

  bool get _hasActiveFilters => _appliedFilters.values.any((v) => v != null && v != '');

  @override
  void initState() {
    super.initState();
    _loadFields();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadFields() async {
    final result = await categoriesRepository.getFilters(_sub.id);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _fields = data;
        _loadingFields = false;
      }),
      onFailure: (_, __) => setState(() => _loadingFields = false),
    );
  }

  Future<void> _onRefresh() async {
    await Future.wait([_gridController.refresh(), _loadFields()]);
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => FilterBottomSheet(
        categoryId: _sub.id,
        fields: _sheetFields,
        initial: _appliedFilters,
      ),
    );
    if (result != null && mounted) setState(() { _appliedFilters = result; _resultCount = null; });
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 450), () => _applySearch(value));
  }

  void _applySearch(String value) {
    _searchDebounce?.cancel();
    if (!mounted || value.trim() == _search) return;
    setState(() { _search = value.trim(); _resultCount = null; });
  }

  void _pickFacet(String? value) {
    if (value == _facetValue) return;
    setState(() { _facetValue = value; _resultCount = null; });
  }

  Map<String, dynamic> get _attributes => {
        ...filterAttributes(_appliedFilters),
        if (_facet != null && _facetValue != null) _facet!.fieldName: _facetValue,
      };

  String get _feedKey =>
      '${_sub.id}|$_search|$_sort|${_appliedFilters['condition']}|${_appliedFilters['minPrice']}|${_appliedFilters['maxPrice']}|${_attributes.toString()}';

  Future<List<dynamic>> _fetchPage(int page) async {
    final feed = _feedKey;
    final result = await listingsRepository.getListingsPage(
      // The most specific filter wins on the server; the type is all this
      // screen is about.
      subcategoryId: _sub.id,
      condition: _appliedFilters['condition'] as String?,
      minPrice: (_appliedFilters['minPrice'] as num?)?.toDouble(),
      maxPrice: (_appliedFilters['maxPrice'] as num?)?.toDouble(),
      search: _search.isEmpty ? null : _search,
      sort: _sort,
      attributes: _attributes,
      limit: 20,
      offset: page * 20,
    );
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
    final visual = SubcategoryVisuals.resolve(widget.parentName, _sub.name);
    final colors = visual.gradient;
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.35).toDouble();
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.25,
              colors: [colors.first.withOpacity(0.15), Colors.transparent],
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
                      title: _sub.name,
                      eyebrow: widget.parentName,
                      emoji: visual.emoji,
                      gradient: colors,
                      assetPath: visual.assetPath,
                      onBack: () => Navigator.pop(context),
                      narrow: _narrow,
                      textScale: textScale,
                      trailingKey: _hasActiveFilters,
                      trailing: BrokaHeaderButton(
                        icon: Icons.tune_rounded,
                        onTap: _openFilters,
                        active: _hasActiveFilters,
                        dotGradient: colors,
                        tooltip: 'Filters',
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(child: _buildSearchBar()),
                  SliverToBoxAdapter(child: _buildFacetRow(colors)),
                  SliverToBoxAdapter(
                    child: FeedSortRow(
                      sort: _sort,
                      resultCount: _resultCount,
                      narrow: _narrow,
                      onSortChanged: (v) => setState(() { _sort = v; _resultCount = null; }),
                    ),
                  ),
                  ProductGridView(
                    key: ValueKey(_feedKey),
                    sliver: true,
                    controller: _gridController,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    fetchPage: _fetchPage,
                    onTapItem: (item) => Navigator.pushNamed(context, '/product',
                        arguments: {'listingId': (item as BrokaListing).id}),
                    onViewStore: (storeId, storeSlug) => Navigator.pushNamed(
                        context, '/store-view', arguments: {'storeId': storeId}),
                    emptyStateBuilder: (_) => _emptyState(visual.emoji, colors),
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

  Widget _emptyState(String emoji, List<Color> colors) {
    final facetValue = _facetValue;
    if (facetValue == null) {
      return BrokaEmptyState(
        emoji: emoji,
        gradient: colors,
        headline: 'No ${_sub.name} listings yet',
        body: _hasActiveFilters || _search.isNotEmpty
            ? 'Try adjusting your filters'
            : 'New ${_sub.name.toLowerCase()} will show here as sellers list them.',
      );
    }
    return BrokaEmptyState(
      emoji: emoji,
      gradient: colors,
      headline: 'No $facetValue in ${_sub.name} yet',
      body: 'Try another ${_facetLabel.toLowerCase()}, or see every one.',
      action: TextButton(
        key: const Key('subcategory-facet-clear'),
        onPressed: () => _pickFacet(null),
        child: Text('All ${_facetPlural.toLowerCase()}',
            style: const TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w800)),
      ),
    );
  }

  Widget _buildSearchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: BrokaSearchField(
          controller: _searchCtrl,
          hintText: 'Search in ${_sub.name}...',
          onChanged: _onSearchChanged,
          onSubmitted: _applySearch,
          onCleared: () => _applySearch(''),
        ),
      );

  String get _facetLabel {
    final name = _facet?.fieldName ?? '';
    final words = name.replaceAll('_', ' ');
    return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
  }

  String get _facetPlural {
    final label = _facetLabel;
    if (label.toLowerCase() == 'brand') return 'Brands';
    if (label.toLowerCase() == 'make') return 'Makes';
    return label;
  }

  /// "Shop by brand": All, then each brand, one tap each.
  Widget _buildFacetRow(List<Color> colors) {
    if (_loadingFields) return const SizedBox(height: 72);
    final facet = _facet;
    if (facet == null) return const SizedBox(height: 4);
    final options = facet.options!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Shop by ${_facetLabel.toLowerCase()}',
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 13, height: 1.2, fontWeight: FontWeight.w800)),
        ),
        SizedBox(
          height: 40 * MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3),
          child: ListView(
            key: const Key('subcategory-facets'),
            scrollDirection: Axis.horizontal,
            // 12 here + each chip's own 4px margin puts the first chip's edge
            // at 16, the same content edge as everything above and below it.
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _chip('All ${_facetPlural.toLowerCase()}', _facetValue == null, () => _pickFacet(null), colors,
                  key: const Key('subcategory-facet-all')),
              for (final option in options)
                _chip(option, _facetValue == option, () => _pickFacet(option), colors,
                    key: Key('subcategory-facet-$option')),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap, List<Color> colors, {Key? key}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Semantics(
          button: true,
          selected: selected,
          child: GestureDetector(
            key: key,
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                gradient: selected ? LinearGradient(colors: colors) : null,
                color: selected ? null : BrokaColors.bgCard.withOpacity(0.86),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: selected ? Colors.transparent : BrokaColors.border),
                boxShadow: selected
                    ? [BoxShadow(color: colors.first.withOpacity(0.38), blurRadius: 12)]
                    : null,
              ),
              child: Center(
                widthFactor: 1,
                child: Text(label,
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
        ),
      );
}
