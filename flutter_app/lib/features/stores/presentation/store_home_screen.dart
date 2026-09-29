// A store's home in the app - the "mini Jumia" a buyer lands on from a
// shared link, a product's store badge, or the store directory.
//
//   header    logo, name (with a tick for a verified seller), category and
//             location, and "More details". Nothing else: no cover photo
//             behind the name (it fought with the text and pushed the
//             products below the fold), and no row of record chips
//   products  search, category pills built like Home's category rail
//             (same registry, same ring-and-emoji shape, only this store's
//             categories, with how many products each has), sort, and the
//             store's products as ProductCards
//
// "More details" and the info button in the bar open Store details
// (widgets/store_details_view.dart): the seller's record - deals done,
// rating, the year they joined - the shop's photos, about, location,
// contact, store info and how paying through BROKA protects the buyer.
//
// Opened with arguments {storeId} or {slug}, plus an optional {via} (the
// shared link's source tag) and {view: 'details'} to open Store details
// straight away (a /store/<name>/about link), on route '/store-view'. The
// cart arrives with checkout (Online Stores phase 4).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../../../services/api_service.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../../categories/domain/category_visual.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/stores_repository.dart';
import '../data/store_share.dart';
import '../domain/models/store.dart';
import 'my_store_screen.dart' show StoreLogo;
import 'widgets/store_details_view.dart';

class StoreHomeScreen extends StatefulWidget {
  const StoreHomeScreen({
    super.key,
    this.storeId,
    this.slug,
    this.via,
    this.openDetails = false,
    this.repository,
    this.share,
    this.animateBackground = true,
  });

  /// Either the store's id or its link name. Read from the route's
  /// arguments when both are null.
  final String? storeId;
  final String? slug;

  /// Where the visitor came from (a shared link's ?via= tag).
  final String? via;

  /// Open Store details on top once the store has loaded (route argument
  /// {view: 'details'}), so Back from them lands on the store's products.
  final bool openDetails;
  final StoresRepository? repository;
  final StoreShare? share;
  final bool animateBackground;

  @override
  State<StoreHomeScreen> createState() => _StoreHomeScreenState();
}

class _StoreHomeScreenState extends State<StoreHomeScreen> {
  StoresRepository get _repo => widget.repository ?? storesRepository;

  String? _storeId;
  String? _slug;
  String? _via;
  bool _started = false;

  Store? _store;
  bool _loading = true;
  String? _error;
  bool _notFound = false;
  bool _isOwner = false;

  late bool _openDetails = widget.openDetails;

  /// The store's name moves into the bar once the header has scrolled
  /// away - not before, or it would sit right above itself.
  final _scroll = ScrollController();
  bool _showTitle = false;

  List<StoreCategoryCount> _categories = const [];
  String? _category;
  String _search = '';
  StoreSort _sort = StoreSort.featured;
  Timer? _searchDebounce;
  final _searchCtrl = TextEditingController();
  final _grid = ProductGridController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final show = _scroll.hasClients && _scroll.offset > 72;
      if (show != _showTitle) setState(() => _showTitle = show);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    final map = args is Map ? args : const {};
    _storeId = widget.storeId ?? map['storeId'] as String?;
    _slug = widget.slug ?? map['slug'] as String?;
    _via = widget.via ?? map['via'] as String?;
    if (map['view'] == 'details') _openDetails = true;
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_storeId == null && _slug == null) {
      setState(() { _loading = false; _notFound = true; });
      return;
    }
    setState(() { _loading = true; _error = null; _notFound = false; });
    final result = _storeId != null
        ? await _repo.getStore(_storeId!)
        : await _repo.getStoreBySlug(_slug!);
    if (!mounted) return;
    switch (result) {
      case Failure(:final message, :final statusCode):
        setState(() {
          _loading = false;
          _notFound = statusCode == 404;
          _error = message;
        });
        return;
      case Success(:final data):
        setState(() { _store = data; _storeId = data.id; _loading = false; });
        if (_openDetails) {
          _openDetails = false;
          // After this frame, so the store's home is under the details.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              showStoreDetails(context, data, animateBackground: widget.animateBackground);
            }
          });
        }
    }
    await Future.wait([_loadCategories(), _checkOwnerAndCountVisit()]);
  }

  Future<void> _loadCategories() async {
    final id = _storeId;
    if (id == null) return;
    final result = await _repo.getStoreCategories(id);
    if (!mounted) return;
    if (result case Success(:final data)) {
      setState(() {
        _categories = data;
        if (_category != null && !data.any((c) => c.name == _category)) _category = null;
      });
    }
  }

  Future<void> _checkOwnerAndCountVisit() async {
    final id = _storeId!;
    var isOwner = false;
    if (ApiService.currentUserId != null) {
      final mine = await _repo.getMyStore();
      if (!mounted) return;
      isOwner = mine.fold(onSuccess: (s) => s?.id == id, onFailure: (_, __) => false);
      if (isOwner) setState(() => _isOwner = true);
    }
    // The owner looking at their own store isn't a visit (the backend
    // checks too).
    if (!isOwner) _repo.recordVisit(id, via: _via ?? 'direct');
  }

  Future<void> _refresh() async {
    final id = _storeId;
    if (id == null) return _load();
    final result = await _repo.getStore(id);
    if (!mounted) return;
    if (result case Success(:final data)) setState(() => _store = data);
    await Future.wait([_loadCategories(), _grid.refresh()]);
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || value.trim() == _search) return;
      setState(() => _search = value.trim());
    });
  }

  Future<void> _chooseSort() async {
    final picked = await showModalBottomSheet<StoreSort>(
      context: context,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Sort products', style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 17, fontWeight: FontWeight.w800)),
            ),
          ),
          for (final s in StoreSort.values)
            ListTile(
              title: Text(s.label, style: TextStyle(
                  color: s == _sort ? BrokaColors.gold : BrokaColors.textHigh,
                  fontWeight: s == _sort ? FontWeight.w700 : FontWeight.w500)),
              trailing: s == _sort
                  ? const Icon(Icons.check_rounded, color: BrokaColors.gold)
                  : null,
              onTap: () => Navigator.pop(sheet, s),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked != null && picked != _sort) setState(() => _sort = picked);
  }

  Future<void> _share(Store store) async {
    final outcome = await (widget.share ?? StoreShare()).share(store, ShareDestination.more);
    if (!mounted || outcome == ShareOutcome.shared) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Store link copied')));
  }

  Future<List<dynamic>> _fetchPage(int page) async {
    final result = await _repo.getStoreListings(
      _storeId!,
      limit: 20,
      offset: page * 20,
      search: _search,
      category: _category,
      sort: _sort,
    );
    return switch (result) {
      Success(:final data) => data,
      // Thrown so the grid shows its retry state, not "no products".
      Failure(:final message) => throw Exception(message),
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
    } else if (store == null) {
      body = _ErrorState(
        notFound: _notFound,
        message: _error,
        onRetry: _notFound ? null : _load,
      );
    } else {
      body = RefreshIndicator(
        color: BrokaColors.gold,
        backgroundColor: BrokaColors.bgCard,
        onRefresh: _refresh,
        child: CustomScrollView(controller: _scroll, slivers: [
          _StoreBar(
            store: store,
            isOwner: _isOwner,
            showTitle: _showTitle,
            onShare: () => _share(store),
            onDetails: () => showStoreDetails(context, store,
                animateBackground: widget.animateBackground),
          ),
          SliverToBoxAdapter(child: _StoreIdentity(
            store: store,
            onDetails: () => showStoreDetails(context, store,
                animateBackground: widget.animateBackground),
          )),
          if (store.isActive) ...[
            SliverToBoxAdapter(child: _searchAndSort()),
            if (_categories.isNotEmpty)
              SliverToBoxAdapter(child: _CategoryPills(
                categories: _categories,
                total: store.listingCount,
                selected: _category,
                onSelected: (c) => setState(() => _category = c),
              )),
            ProductGridView(
              key: ValueKey('${_category ?? ''}|$_search|${_sort.value}'),
              sliver: true,
              controller: _grid,
              fetchPage: _fetchPage,
              onTapItem: (item) => Navigator.of(context).pushNamed('/product',
                  arguments: {'listingId': (item as BrokaListing).id}),
              emptyStateBuilder: (_) => _EmptyCatalogue(
                filtered: _search.isNotEmpty || _category != null,
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ]),
      );
    }

    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: store == null
            ? SafeArea(child: Stack(children: [
                body,
                Positioned(
                  top: 4, left: 4,
                  child: IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back_rounded, color: BrokaColors.textMid),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ]))
            : body,
      ),
    );
  }

  Widget _searchAndSort() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              key: const Key('store-search'),
              controller: _searchCtrl,
              onChanged: (v) {
                _onSearchChanged(v);
                setState(() {});
              },
              textInputAction: TextInputAction.search,
              onSubmitted: (v) {
                _searchDebounce?.cancel();
                setState(() => _search = v.trim());
              },
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: InputDecoration(
                hintText: 'Search this store',
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, color: BrokaColors.textMid),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          _searchDebounce?.cancel();
                          setState(() => _search = '');
                        },
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: BrokaColors.border)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: BrokaColors.border)),
                fillColor: BrokaColors.bgCard.withOpacity(0.7),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Material(
            color: BrokaColors.bgCard.withOpacity(0.7),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              key: const Key('store-sort'),
              borderRadius: BorderRadius.circular(14),
              onTap: _chooseSort,
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _sort == StoreSort.featured
                      ? BrokaColors.border : BrokaColors.gold),
                ),
                child: Row(children: [
                  Icon(Icons.swap_vert_rounded,
                      color: _sort == StoreSort.featured ? BrokaColors.textMid : BrokaColors.gold),
                  const SizedBox(width: 4),
                  const Text('Sort', style: TextStyle(color: BrokaColors.textHigh,
                      fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ]),
      );
}

// ── Header ───────────────────────────────────────────────────────────────────

class _StoreBar extends StatelessWidget {
  const _StoreBar({
    required this.store,
    required this.isOwner,
    required this.showTitle,
    required this.onShare,
    required this.onDetails,
  });
  final Store store;
  final bool isOwner;
  final bool showTitle;
  final VoidCallback onShare;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      // Opaque: the products scroll up under it.
      backgroundColor: BrokaColors.bg,
      surfaceTintColor: Colors.transparent,
      iconTheme: const IconThemeData(color: BrokaColors.textHigh),
      title: AnimatedOpacity(
        opacity: showTitle ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                fontWeight: FontWeight.w800)),
      ),
      actions: [
        // Store details from anywhere in the catalogue: the bar stays
        // pinned once "More details" under the name has scrolled away.
        IconButton(
          key: const Key('store-details-button'),
          tooltip: 'Store details',
          icon: const Icon(Icons.info_outline_rounded),
          onPressed: onDetails,
        ),
        IconButton(
          tooltip: 'Share store',
          icon: const Icon(Icons.ios_share_rounded),
          onPressed: onShare,
        ),
        if (isOwner)
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed('/store-manage'),
            child: const Text('Manage', style: TextStyle(color: _accent,
                fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }
}

// BrokaColors.gold is under 4:1 on the dark background; this lighter
// violet reads at 7:1.
const _accent = Color(0xFFB69CFF);

/// Who the store is, at a glance: logo, name, what and where, and the way
/// to everything else about it. The seller's record (deals done, rating,
/// the year they joined) is under Store details: as a row of chips here it
/// wrapped onto a second line and pushed the products down.
class _StoreIdentity extends StatelessWidget {
  const _StoreIdentity({required this.store, required this.onDetails});
  final Store store;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final place = [store.category, store.locationLine]
        .whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final glow = CategoryVisuals.gradientFor(store.category);
    final verified = store.owner?.verified ?? false;

    return Padding(
      key: const Key('store-identity'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              boxShadow: [BoxShadow(color: glow.first.withOpacity(0.45), blurRadius: 24)],
            ),
            child: StoreLogo(store: store, size: 72),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text.rich(
              TextSpan(children: [
                TextSpan(text: store.name),
                // A tick beside the name, the way people know it from
                // other apps; what it means is spelled out in the details.
                if (verified)
                  const WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.verified_rounded, size: 19, color: BrokaColors.success,
                          semanticLabel: 'Verified seller'),
                    ),
                  ),
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 22,
                  fontWeight: FontWeight.w800, height: 1.15, letterSpacing: -0.2),
            ),
            if (place.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(place, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
            ],
            const SizedBox(height: 4),
            InkWell(
              key: const Key('store-more-details'),
              onTap: onDetails,
              borderRadius: BorderRadius.circular(10),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: _accent),
                  SizedBox(width: 5),
                  // Flexible: beside a 72dp logo on a 320dp phone with large
                  // text, the row is wider than the space left.
                  Flexible(child: Text('More details', maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _accent, fontSize: 13.5,
                          fontWeight: FontWeight.w700))),
                  Icon(Icons.chevron_right_rounded, size: 18, color: _accent),
                ]),
              ),
            ),
          ])),
        ]),
        if (!store.isActive)
          Container(
            key: const Key('store-paused-banner'),
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(top: 12),
            decoration: BoxDecoration(
              color: BrokaColors.warning.withOpacity(0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.warning.withOpacity(0.4)),
            ),
            child: const Row(children: [
              Icon(Icons.pause_circle_outline_rounded, color: BrokaColors.warning),
              SizedBox(width: 10),
              Expanded(child: Text(
                  'This store is taking a break. Its products will be back soon.',
                  style: TextStyle(color: BrokaColors.textHigh, fontSize: 13))),
            ]),
          ),
      ]),
    );
  }
}

// ── Category pills ───────────────────────────────────────────────────────────

/// The store's categories, drawn like Home's category rail: a gradient ring
/// around the category's emoji, the name under it, and here also the number
/// of products.
class _CategoryPills extends StatelessWidget {
  const _CategoryPills({
    required this.categories,
    required this.total,
    required this.selected,
    required this.onSelected,
  });

  final List<StoreCategoryCount> categories;
  final int total;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3);
    const circle = 52.0;
    const labelSize = 10.5;
    final height = circle + 4 + labelSize * 1.12 * 2 * textScale + 14 + 16;
    final items = <(String?, String, String, List<Color>, int)>[
      (null, 'All', '✨', CategoryVisuals.resolve('Other').gradient, total),
      for (final c in categories)
        (c.name, c.name, CategoryVisuals.emojiFor(c.name), CategoryVisuals.gradientFor(c.name),
            c.count),
    ];
    return SizedBox(
      height: height,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final (value, label, emoji, colors, count) = items[i];
          final isSelected = value == selected;
          return Semantics(
            button: true,
            selected: isSelected,
            label: '$label, $count product${count == 1 ? '' : 's'}',
            child: GestureDetector(
              key: Key('category-pill-${value ?? 'all'}'),
              onTap: () => onSelected(value),
              child: Container(
                width: circle + 24,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Stack(clipBehavior: Clip.none, children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: circle,
                      height: circle,
                      padding: EdgeInsets.all(isSelected ? 3 : 2),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: colors),
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(
                            color: colors.first.withOpacity(isSelected ? 0.6 : 0.3),
                            blurRadius: isSelected ? 14 : 8)],
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Color.alphaBlend(colors.first.withOpacity(0.25), BrokaColors.bgCard)
                              : BrokaColors.bgCard,
                          shape: BoxShape.circle,
                        ),
                        child: Center(child: Text(emoji,
                            style: const TextStyle(fontSize: circle * 0.38))),
                      ),
                    ),
                    Positioned(
                      right: -4, top: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: BrokaColors.bg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: colors.first.withOpacity(0.8)),
                        ),
                        child: Text('$count', style: const TextStyle(color: BrokaColors.textHigh,
                            fontSize: 9.5, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Flexible(
                    child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: isSelected ? BrokaColors.textHigh : BrokaColors.textMid,
                            fontSize: labelSize, height: 1.12,
                            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600)),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── States ───────────────────────────────────────────────────────────────────

class _EmptyCatalogue extends StatelessWidget {
  const _EmptyCatalogue({required this.filtered});
  final bool filtered;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(filtered ? Icons.search_off_rounded : Icons.inventory_2_outlined,
              color: BrokaColors.textMid, size: 38),
          const SizedBox(height: 10),
          Text(filtered ? 'No products match' : 'Nothing listed yet',
              style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(filtered
              ? 'Try another search or category.'
              : 'Check back soon - this store is just getting started.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
        ]),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.notFound, this.message, this.onRetry});
  final bool notFound;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(notFound ? Icons.storefront_outlined : Icons.cloud_off_rounded,
                color: BrokaColors.textMid, size: 44),
            const SizedBox(height: 12),
            Text(notFound ? 'Store not found' : "Couldn't open this store",
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(notFound
                ? 'The link may be mistyped, or the store has closed.'
                : (message ?? 'Check your connection and try again.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textMid)),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(backgroundColor: BrokaColors.gold),
                child: const Text('Try again'),
              ),
            ],
          ]),
        ),
      );
}
