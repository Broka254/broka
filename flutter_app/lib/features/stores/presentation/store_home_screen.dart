// A store's home in the app - the "mini Jumia" a buyer lands on from a
// shared link, a product's store badge, or the store directory.
//
//   header    cover, logo, name, category and location, and the owner's
//             real seller record (verified, completed deals, rating)
//   search    within this store's products
//   category  pills built like Home's category rail (same registry, same
//             ring-and-emoji shape), only this store's categories, with
//             how many products each has
//   sort      recommended, newest, price low/high
//   grid      the store's products, as ProductCards
//
// Opened with arguments {storeId} or {slug}, plus an optional {via} (the
// shared link's source tag), on route '/store-view'. The cart arrives with
// checkout (Online Stores phase 4).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../../../services/api_service.dart';
import '../../../widgets/broka_image.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../../categories/domain/category_visual.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/stores_repository.dart';
import '../data/store_share.dart';
import '../domain/models/store.dart';
import 'my_store_screen.dart' show StoreLogo;

class StoreHomeScreen extends StatefulWidget {
  const StoreHomeScreen({
    super.key,
    this.storeId,
    this.slug,
    this.via,
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

  List<StoreCategoryCount> _categories = const [];
  String? _category;
  String _search = '';
  StoreSort _sort = StoreSort.featured;
  Timer? _searchDebounce;
  final _searchCtrl = TextEditingController();
  final _grid = ProductGridController();

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
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
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
        child: CustomScrollView(slivers: [
          _StoreHeader(
            store: store,
            isOwner: _isOwner,
            onShare: () => _share(store),
          ),
          SliverToBoxAdapter(child: _intro(store)),
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

  Widget _intro(Store store) {
    final description = store.description?.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!store.isActive)
          Container(
            key: const Key('store-paused-banner'),
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 12),
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
        if (description.isNotEmpty) _Description(description),
        if (store.businessEmail != null && store.businessEmailVerified)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              const Icon(Icons.alternate_email_rounded, size: 15, color: BrokaColors.textMid),
              const SizedBox(width: 6),
              Flexible(child: Text(store.businessEmail!,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5))),
            ]),
          ),
      ]),
    );
  }

  Widget _searchAndSort() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
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
                prefixIcon: const Icon(Icons.search_rounded, color: BrokaColors.textLow),
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

class _StoreHeader extends StatelessWidget {
  const _StoreHeader({required this.store, required this.isOwner, required this.onShare});
  final Store store;
  final bool isOwner;
  final VoidCallback onShare;

  static const _expanded = 268.0;

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: _expanded,
      backgroundColor: BrokaColors.bg.withOpacity(0.94),
      iconTheme: const IconThemeData(color: Colors.white),
      actions: [
        IconButton(
          tooltip: 'Share store',
          icon: const Icon(Icons.ios_share_rounded),
          onPressed: onShare,
        ),
        if (isOwner)
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed('/store-manage'),
            child: const Text('Manage', style: TextStyle(color: BrokaColors.gold,
                fontWeight: FontWeight.w700)),
          ),
      ],
      flexibleSpace: LayoutBuilder(builder: (context, constraints) {
        final top = MediaQuery.of(context).padding.top;
        final collapsedHeight = kToolbarHeight + top;
        final t = ((constraints.maxHeight - collapsedHeight) / (_expanded - kToolbarHeight))
            .clamp(0.0, 1.0);
        return Stack(fit: StackFit.expand, children: [
          FlexibleSpaceBar(
            collapseMode: CollapseMode.parallax,
            background: _HeaderBackground(store: store),
          ),
          // The store name moves into the bar once the header has scrolled away.
          Positioned(
            left: 56, right: 110, top: top, height: kToolbarHeight,
            child: IgnorePointer(
              child: Opacity(
                opacity: (1 - t * 3).clamp(0.0, 1.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                          fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ),
        ]);
      }),
    );
  }
}

class _HeaderBackground extends StatelessWidget {
  const _HeaderBackground({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    final cover = store.coverSource;
    final owner = store.owner;
    final place = [store.category, store.locationLine]
        .whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final trust = <(IconData, String)>[
      if (owner?.verified ?? false) (Icons.verified_rounded, 'Verified seller'),
      if ((owner?.completedDeals ?? 0) > 0)
        (Icons.handshake_outlined,
            '${owner!.completedDeals} deal${owner.completedDeals == 1 ? '' : 's'} done'),
      if ((owner?.completedDeals ?? 0) > 0 && owner?.rating != null)
        (Icons.star_rounded, owner!.rating!.toStringAsFixed(1)),
      if (owner?.memberSince != null)
        (Icons.calendar_month_outlined, 'Since ${owner!.memberSince!.year}'),
    ];
    return Stack(fit: StackFit.expand, children: [
      if (cover != null)
        BrokaImage(cover, fit: BoxFit.cover)
      else
        DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: CategoryVisuals.gradientFor(store.category)
              .map((c) => c.withOpacity(0.55)).toList(),
        ))),
      const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0x8003040A), Color(0x0003040A), Color(0xF203040A)],
        stops: [0, 0.35, 1],
      ))),
      Positioned(
        left: 16, right: 16, bottom: 14,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            StoreLogo(store: store, size: 64),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min, children: [
              Text(store.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 21,
                      fontWeight: FontWeight.w800, height: 1.15)),
              if (place.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(place, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFFD7D2EA), fontSize: 12.5)),
              ],
            ])),
          ]),
          if (trust.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (icon, label) in trust)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.18)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 13, color: icon == Icons.verified_rounded
                        ? BrokaColors.success
                        : (icon == Icons.star_rounded ? const Color(0xFFFBBF24) : Colors.white70)),
                    const SizedBox(width: 4),
                    Text(label, style: const TextStyle(color: Colors.white, fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
                  ]),
                ),
            ]),
          ],
        ]),
      ),
    ]);
  }
}

class _Description extends StatefulWidget {
  const _Description(this.text);
  final String text;

  @override
  State<_Description> createState() => _DescriptionState();
}

class _DescriptionState extends State<_Description> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: BrokaColors.textMid, fontSize: 13.5, height: 1.45);
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        maxLines: 3,
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final long = painter.didExceedMaxLines;
      return GestureDetector(
        onTap: long ? () => setState(() => _open = !_open) : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.text, style: style,
              maxLines: _open ? null : 3,
              overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis),
          if (long)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(_open ? 'Less' : 'More',
                  style: const TextStyle(color: BrokaColors.gold, fontSize: 12.5,
                      fontWeight: FontWeight.w700)),
            ),
        ]),
      );
    });
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
