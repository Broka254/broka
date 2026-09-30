// A store's home in the app - the "mini Jumia" a buyer lands on from a
// shared link, a product's store badge, or the store directory. Laid out as
// a shop, not a profile:
//
//   bar       back, the name once the hero has scrolled away, More, share,
//             and the cart with how many items are in it
//   hero      the store's name, big, on moving colour - no logo square
//             (the old rounded-square logo read as a profile picture, and
//             its initial as a placeholder). Whether the owner is online,
//             the seller's record, and the More button for everything else
//   perks     what buying here means: escrow, M-Pesa, delivery or pickup
//   products  Home's search pill and filter button (sort, condition,
//             price), the category rail, and the catalogue as shop cards
//             with Add to cart
//   cart bar  once something is in the cart: items, total, View cart
//
// More (and the bar's More button) opens Store details
// (widgets/store_details_view.dart): the seller's record, the shop's photos,
// about, location, contact, store info and how paying through BROKA
// protects the buyer.
//
// Opened with arguments {storeId} or {slug}, plus an optional {via} (the
// shared link's source tag) and {view: 'details'} to open Store details
// straight away (a /store/<name>/about link), or {view: 'cart', items:
// {listingId: quantity}} to put products in the cart and open it (a
// /store/<name>/cart link: the web storefront's "check out in the app"),
// on route '/store-view'.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../../../services/api_service.dart';
import '../../../utils/price_format.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../../categories/domain/category_visual.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/stores_repository.dart';
import '../data/store_cart.dart';
import '../data/store_share.dart';
import '../domain/models/store.dart';
import 'store_cart_screen.dart';
import 'widgets/store_details_view.dart';
import 'widgets/store_product_card.dart';

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

  /// Also stills the hero's colours (tests, and anyone who asked for less
  /// motion gets a still hero regardless).
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
  StoreCart? _cart;

  late bool _openDetails = widget.openDetails;

  /// Products to put in the cart once the store has loaded, from a cart
  /// link; the cart opens after.
  Map<String, int>? _importCart;

  /// The store's name moves into the bar once the hero has scrolled away -
  /// not before, or it would sit right above itself.
  final _scroll = ScrollController();
  bool _showTitle = false;

  List<StoreCategoryCount> _categories = const [];
  String? _category;
  String _search = '';
  StoreSort _sort = StoreSort.featured;
  String? _condition;
  StorePriceBand? _price;
  bool _filtersOpen = false;
  Timer? _searchDebounce;
  final _searchCtrl = TextEditingController();
  final _grid = ProductGridController();

  bool get _filtersActive => _sort != StoreSort.featured || _condition != null || _price != null;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final show = _scroll.hasClients && _scroll.offset > 150;
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
    if (map['view'] == 'cart') {
      final items = map['items'];
      _importCart = items is Map
          ? {for (final e in items.entries) if (e.key is String && e.value is int) e.key as String: e.value as int}
          : const {};
    }
    _load();
  }

  @override
  void dispose() {
    _cart?.removeListener(_cartChanged);
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _cartChanged() {
    if (mounted) setState(() {});
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
        _cart ??= StoreCart.of(data.id)..addListener(_cartChanged);
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
    final toImport = _importCart;
    if (toImport != null) {
      _importCart = null;
      await _fillCart(toImport);
      if (mounted && _store != null) _openCart(_store!);
    }
    await Future.wait([_loadCategories(), _checkOwnerAndCountVisit()]);
  }

  /// Puts a cart link's products in this store's cart, reading each one
  /// again: the link says which and how many, never the price, and only
  /// this store's products that are still for sale go in.
  Future<void> _fillCart(Map<String, int> items) async {
    final cart = _cart;
    final storeId = _storeId;
    if (cart == null || storeId == null) return;
    await cart.load();
    final results = await Future.wait(items.keys.map(_repo.getListing));
    for (final result in results) {
      if (result case Success(:final data)) {
        if (data.storeId != storeId || data.status != 'active' || data.listingType == 'auction') {
          continue;
        }
        final item = CartItem.fromListing(data);
        final wanted = items[data.id] ?? 1;
        for (var have = cart.quantityOf(data.id); have < wanted; have++) {
          if (!cart.add(item)) break;
        }
      }
    }
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

  void _resetFilters() => setState(() {
        _sort = StoreSort.featured;
        _condition = null;
        _price = null;
      });

  Future<void> _share(Store store) async {
    final outcome = await (widget.share ?? StoreShare()).share(store, ShareDestination.more);
    if (!mounted || outcome == ShareOutcome.shared) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Store link copied')));
  }

  void _details(Store store) =>
      showStoreDetails(context, store, animateBackground: widget.animateBackground);

  void _openCart(Store store) => openStoreCart(context,
      storeId: store.id, storeName: store.name, animateBackground: widget.animateBackground);

  Future<List<dynamic>> _fetchPage(int page) async {
    final result = await _repo.getStoreListings(
      _storeId!,
      limit: 20,
      offset: page * 20,
      search: _search,
      category: _category,
      sort: _sort,
      condition: _condition,
      price: _price,
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
    final cart = _cart;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
    } else if (store == null || cart == null) {
      body = _ErrorState(
        notFound: _notFound,
        message: _error,
        onRetry: _notFound ? null : _load,
      );
    } else {
      final filtered = _search.isNotEmpty || _filtersActive;
      body = RefreshIndicator(
        color: BrokaColors.gold,
        backgroundColor: BrokaColors.bgCard,
        onRefresh: _refresh,
        child: CustomScrollView(controller: _scroll, slivers: [
          _StoreBar(
            store: store,
            isOwner: _isOwner,
            showTitle: _showTitle,
            cartCount: cart.count,
            onShare: () => _share(store),
            onDetails: () => _details(store),
            onCart: () => _openCart(store),
          ),
          SliverToBoxAdapter(child: _StoreHero(
            store: store,
            animate: widget.animateBackground,
            onMore: () => _details(store),
          )),
          if (store.isActive) ...[
            const SliverToBoxAdapter(child: _Perks()),
            SliverToBoxAdapter(child: _searchRow(store)),
            if (_filtersOpen) SliverToBoxAdapter(child: _filterPanel()),
            if (_categories.isNotEmpty)
              SliverToBoxAdapter(child: _CategoryPills(
                categories: _categories,
                total: store.listingCount,
                selected: _category,
                onSelected: (c) => setState(() => _category = c),
              )),
            SliverToBoxAdapter(child: _CatalogueHeading(
              title: _category ?? 'All products',
              count: filtered
                  ? null
                  : _category == null
                      ? store.listingCount
                      : _categories.where((c) => c.name == _category).firstOrNull?.count,
              sort: _sort,
            )),
            ProductGridView(
              key: ValueKey('${_category ?? ''}|$_search|${_sort.value}|${_condition ?? ''}|'
                  '${_price?.name ?? ''}'),
              sliver: true,
              controller: _grid,
              fetchPage: _fetchPage,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              itemTextBlock: StoreProductCard.textBlock,
              itemBuilder: (_, item) => StoreProductCard(
                listing: item as BrokaListing,
                cart: cart,
                onTap: () => Navigator.of(context).pushNamed('/product',
                    arguments: {'listingId': item.id}),
                onAddBlocked: _isOwner
                    ? () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('This is your own store - buyers add to cart here.')))
                    : null,
              ),
              emptyStateBuilder: (_) => _EmptyCatalogue(
                filtered: filtered || _category != null,
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
      bottomNavigationBar: store != null && cart != null && !cart.isEmpty && store.isActive
          ? _CartBar(cart: cart, onOpen: () => _openCart(store))
          : null,
    );
  }

  /// Home's search control (home_screen.dart, _searchRow): the same pill,
  /// border and filter button with its dot - here the field types in place,
  /// searching this store only.
  Widget _searchRow(Store store) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Row(children: [
          Expanded(
            child: Container(
              height: 44,
              padding: const EdgeInsets.only(left: 14, right: 4),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard.withOpacity(0.86),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.35)),
              ),
              child: Row(children: [
                const Icon(Icons.search_rounded, size: 18, color: BrokaColors.textMid),
                const SizedBox(width: 9),
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
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
                    cursorColor: BrokaColors.gold,
                    decoration: InputDecoration.collapsed(
                      hintText: 'Search ${store.name}',
                      hintStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5),
                    ),
                  ),
                ),
                if (_searchCtrl.text.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 18),
                    onPressed: () {
                      _searchCtrl.clear();
                      _searchDebounce?.cancel();
                      setState(() => _search = '');
                    },
                  ),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: 'Filters',
            child: GestureDetector(
              key: const Key('store-filter'),
              onTap: () => setState(() => _filtersOpen = !_filtersOpen),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _filtersOpen
                      ? BrokaColors.gold.withOpacity(0.2)
                      : BrokaColors.bgCard.withOpacity(0.86),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _filtersOpen ? BrokaColors.gold : BrokaColors.border),
                ),
                child: Stack(clipBehavior: Clip.none, children: [
                  Center(
                    child: Icon(Icons.tune_rounded,
                        color: _filtersOpen || _filtersActive ? BrokaColors.gold : BrokaColors.textMid,
                        size: 18),
                  ),
                  if (_filtersActive)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        key: const Key('store-filters-active-dot'),
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                            color: BrokaColors.gold, shape: BoxShape.circle),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ]),
      );

  /// Home's filter panel, for one store: sort, condition and a price band.
  Widget _filterPanel() {
    Widget label(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12,
                fontWeight: FontWeight.w600)),
          ]),
        );
    return Container(
      key: const Key('store-filter-panel'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid.withOpacity(0.96),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        label(Icons.sort_rounded, BrokaColors.neonBlue, 'Sort'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in StoreSort.values)
            _FilterChip(
              key: Key('filter-sort-${s.value}'),
              label: s.label,
              selected: _sort == s,
              onTap: () => setState(() => _sort = s),
            ),
        ]),
        const SizedBox(height: 12),
        label(Icons.tune_rounded, BrokaColors.gold, 'Condition'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (value, text) in const [
            (null, 'Any'), ('new', 'New'), ('used', 'Used'), ('refurbished', 'Refurbished'),
          ])
            _FilterChip(
              key: Key('filter-condition-${value ?? 'any'}'),
              label: text,
              selected: _condition == value,
              onTap: () => setState(() => _condition = value),
            ),
        ]),
        const SizedBox(height: 12),
        label(Icons.payments_outlined, BrokaColors.neonGreen, 'Price (KES)'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _FilterChip(
            key: const Key('filter-price-any'),
            label: 'Any price',
            selected: _price == null,
            onTap: () => setState(() => _price = null),
          ),
          for (final band in StorePriceBand.values)
            _FilterChip(
              key: Key('filter-price-${band.name}'),
              label: band.label,
              selected: _price == band,
              onTap: () => setState(() => _price = band),
            ),
        ]),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _filtersActive ? _resetFilters : null,
            icon: const Icon(Icons.restart_alt_rounded, size: 16),
            style: TextButton.styleFrom(foregroundColor: BrokaColors.gold),
            label: const Text('Reset filters',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }
}

// ── Header ───────────────────────────────────────────────────────────────────

class _StoreBar extends StatelessWidget {
  const _StoreBar({
    required this.store,
    required this.isOwner,
    required this.showTitle,
    required this.cartCount,
    required this.onShare,
    required this.onDetails,
    required this.onCart,
  });
  final Store store;
  final bool isOwner;
  final bool showTitle;
  final int cartCount;
  final VoidCallback onShare;
  final VoidCallback onDetails;
  final VoidCallback onCart;

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      // Opaque: the products scroll up under it.
      backgroundColor: BrokaColors.bg,
      surfaceTintColor: Colors.transparent,
      iconTheme: const IconThemeData(color: BrokaColors.textHigh),
      titleSpacing: 0,
      title: AnimatedOpacity(
        opacity: showTitle ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                fontWeight: FontWeight.w800)),
      ),
      actions: [
        // Store details from anywhere in the catalogue: the bar stays
        // pinned once the hero's More has scrolled away.
        IconButton(
          key: const Key('store-details-button'),
          tooltip: 'More about this store',
          icon: const Icon(Icons.info_outline_rounded),
          onPressed: onDetails,
        ),
        IconButton(
          tooltip: 'Share store',
          icon: const Icon(Icons.ios_share_rounded),
          onPressed: onShare,
        ),
        if (store.isActive)
          IconButton(
            key: const Key('store-cart-button'),
            tooltip: cartCount == 0 ? 'Cart' : 'Cart, $cartCount item${cartCount == 1 ? '' : 's'}',
            onPressed: onCart,
            icon: Badge(
              isLabelVisible: cartCount > 0,
              backgroundColor: BrokaColors.neonPink,
              label: Text('$cartCount', key: const Key('store-cart-count')),
              child: const Icon(Icons.shopping_cart_outlined),
            ),
          ),
        if (isOwner)
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed('/store-manage'),
            child: const Text('Manage', style: TextStyle(color: _accent,
                fontWeight: FontWeight.w700)),
          ),
        const SizedBox(width: 4),
      ],
    );
  }
}

// BrokaColors.gold is under 4:1 on the dark background; this lighter
// violet reads at 7:1.
const _accent = Color(0xFFB69CFF);

/// The top of the store: its name, large, on moving aurora colours with a
/// shimmer running through the letters - the store's sign over the door.
/// Under it what and where, whether the owner is online, the seller's
/// record, and More.
class _StoreHero extends StatefulWidget {
  const _StoreHero({required this.store, required this.animate, required this.onMore});
  final Store store;
  final bool animate;
  final VoidCallback onMore;

  @override
  State<_StoreHero> createState() => _StoreHeroState();
}

class _StoreHeroState extends State<_StoreHero> with SingleTickerProviderStateMixin {
  late final AnimationController _t =
      AnimationController(vsync: this, duration: const Duration(seconds: 12));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _StoreHero old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final moving = widget.animate && !MediaQuery.disableAnimationsOf(context);
    if (moving && !_t.isAnimating) {
      _t.repeat();
    } else if (!moving && _t.isAnimating) {
      _t.stop();
    }
    // A still hero is drawn at a fixed point where every colour shows.
    if (!moving) _t.value = 0.3;
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final owner = store.owner;
    final colors = CategoryVisuals.gradientFor(store.category);
    final place = [store.category, store.locationLine]
        .whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final verified = owner?.verified ?? false;
    final rating = owner?.shownRating;
    final deals = owner?.completedDeals ?? 0;

    return Padding(
      key: const Key('store-identity'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(color: colors.first.withOpacity(0.35), blurRadius: 30, spreadRadius: -4),
              BoxShadow(color: BrokaColors.gold.withOpacity(0.25), blurRadius: 40,
                  offset: const Offset(0, 12), spreadRadius: -10),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: Stack(children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _t,
                    builder: (_, __) => CustomPaint(
                      painter: _AuroraPainter(t: _t.value, accent: colors),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: Colors.white.withOpacity(0.12)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    _GlassChip(
                      icon: verified ? Icons.verified_rounded : Icons.storefront_rounded,
                      iconColor: verified ? BrokaColors.success : _accent,
                      label: verified ? 'Verified store' : 'BROKA store',
                      semantics: verified ? 'Verified seller' : null,
                    ),
                    if (owner != null && (owner.online || owner.lastActive != null))
                      _PresenceChip(online: owner.online, label: owner.lastActive),
                  ]),
                  const SizedBox(height: 10),
                  AnimatedBuilder(
                    animation: _t,
                    builder: (_, child) => ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (rect) => LinearGradient(
                        begin: Alignment(-3 + 4 * _t.value, -0.2),
                        end: Alignment(-1 + 4 * _t.value, 0.2),
                        tileMode: TileMode.mirror,
                        colors: const [
                          Colors.white, Color(0xFFE2D4FF), Color(0xFF9ED8FF), Colors.white,
                        ],
                      ).createShader(rect),
                      child: child,
                    ),
                    child: Text(
                      store.name,
                      key: const Key('store-hero-name'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: store.name.length > 18 ? 28 : 34,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                        letterSpacing: -0.6,
                        shadows: [Shadow(color: BrokaColors.gold.withOpacity(0.7), blurRadius: 22)],
                      ),
                    ),
                  ),
                  if (place.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(place, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withOpacity(0.82), fontSize: 13.5,
                            fontWeight: FontWeight.w500)),
                  ],
                  const SizedBox(height: 12),
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Wrap(spacing: 6, runSpacing: 6, children: [
                        _GlassChip(
                          key: const Key('hero-rating'),
                          icon: Icons.star_rounded,
                          iconColor: BrokaColors.zoneAmber,
                          label: rating != null ? rating.toStringAsFixed(1) : 'New seller',
                        ),
                        _GlassChip(
                          key: const Key('hero-deals'),
                          icon: Icons.handshake_outlined,
                          iconColor: BrokaColors.neonCyan,
                          label: '$deals deal${deals == 1 ? '' : 's'}',
                        ),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    _MoreButton(onTap: widget.onMore),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
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

/// Moving aurora: soft blobs of the store's category colours and BROKA's
/// violet and blue drifting under a field of twinkling stars, with a sheen
/// sweeping across. [t] runs 0 to 1 and loops seamlessly.
class _AuroraPainter extends CustomPainter {
  _AuroraPainter({required this.t, required this.accent});
  final double t;
  final List<Color> accent;

  static final _stars = () {
    final rnd = math.Random(11);
    return [
      for (var i = 0; i < 34; i++)
        (x: rnd.nextDouble(), y: rnd.nextDouble(), r: 0.5 + rnd.nextDouble() * 1.3,
            phase: rnd.nextDouble()),
    ];
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0B0820));
    final a = t * 2 * math.pi;
    final blobs = [
      (accent.first, 0.15, 0.25, 0.70),
      (BrokaColors.neonPurple, 0.85, 0.15, 0.75),
      (BrokaColors.neonBlue, 0.70, 0.95, 0.65),
      (accent.last, 0.05, 1.00, 0.55),
      (BrokaColors.neonPink, 0.50, 0.50, 0.40),
    ];
    for (var i = 0; i < blobs.length; i++) {
      final (color, x, y, r) = blobs[i];
      final phase = a + i * 1.9;
      final center = Offset(
        (x + 0.14 * math.sin(phase)) * w,
        (y + 0.18 * math.cos(phase * (i.isEven ? 1 : -1) + i)) * h,
      );
      final radius = r * math.max(w, h) * 0.55 * (0.9 + 0.1 * math.sin(phase * 2));
      final paint = Paint()
        ..shader = RadialGradient(colors: [
          color.withOpacity(i == 4 ? 0.38 : 0.72),
          color.withOpacity(0),
        ]).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }
    // Two orbit rings turning slowly around the top right, like the
    // constellation's lines drawn large.
    for (var i = 0; i < 2; i++) {
      canvas.save();
      canvas.translate(w * 0.82, h * 0.18);
      canvas.rotate(a * (i.isEven ? 1 : -1) * 0.5 + i * 0.9);
      final ring = Rect.fromCenter(center: Offset.zero, width: w * (0.9 + i * 0.35),
          height: h * (0.55 + i * 0.25));
      canvas.drawOval(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = SweepGradient(colors: [
            Colors.white.withOpacity(0),
            (i.isEven ? BrokaColors.neonCyan : BrokaColors.neonPink).withOpacity(0.55),
            Colors.white.withOpacity(0),
          ], transform: GradientRotation(a * 2)).createShader(ring),
      );
      canvas.restore();
    }
    // A dark wash at the bottom-left, where the words sit.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Colors.black.withOpacity(0.45), Colors.transparent],
        ).createShader(Offset.zero & size),
    );
    final star = Paint();
    for (final s in _stars) {
      final twinkle = 0.5 + 0.5 * math.sin(2 * math.pi * (t * 3 + s.phase));
      star.color = Colors.white.withOpacity(0.15 + 0.6 * twinkle);
      canvas.drawCircle(Offset(s.x * w, s.y * h), s.r, star);
    }
    // The sheen: a bright diagonal band crossing once per loop.
    final x = (t * 2.4 - 0.7) * w;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.transparent, Colors.white.withOpacity(0.07), Colors.transparent],
          stops: const [0.0, 0.5, 1.0],
          transform: const GradientRotation(-0.5),
        ).createShader(Rect.fromLTWH(x, 0, w * 0.35, h)),
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t || old.accent != accent;
}

class _GlassChip extends StatelessWidget {
  const _GlassChip({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.label,
    this.semantics,
  });
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? semantics;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.35),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.16)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: iconColor, semanticLabel: semantics),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
        ]),
      );
}

/// "● Online now" in green, or when the owner was last active.
class _PresenceChip extends StatelessWidget {
  const _PresenceChip({required this.online, required this.label});
  final bool online;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = online ? BrokaColors.success : BrokaColors.textMid;
    return Container(
      key: const Key('store-presence'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(online ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.55)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: online ? [BoxShadow(color: color, blurRadius: 6)] : null,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(online ? 'Online now' : label ?? '', maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: online ? BrokaColors.success : Colors.white70,
                  fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

/// The way to everything else about the store, where the eye lands after
/// the name: a glowing pill at the hero's bottom right, always on the
/// first screen.
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'More about this store',
        excludeSemantics: true,
        child: GestureDetector(
          key: const Key('store-more-details'),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(
                  colors: [BrokaColors.neonPink, BrokaColors.gold, BrokaColors.neonBlue]),
              boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.55), blurRadius: 16)],
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(
                color: const Color(0xFF140E2E).withOpacity(0.92),
                borderRadius: BorderRadius.circular(21),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.grid_view_rounded, size: 15, color: _accent),
                SizedBox(width: 6),
                Text('More', style: TextStyle(color: Colors.white, fontSize: 13.5,
                    fontWeight: FontWeight.w800)),
                Icon(Icons.chevron_right_rounded, size: 18, color: _accent),
              ]),
            ),
          ),
        ),
      );
}

/// What buying from a store on BROKA means, in the strip shops put under
/// their banner. Every word is true of every store: payment is held in
/// escrow, it's by M-Pesa, and delivery (or pickup) is agreed in the deal.
class _Perks extends StatelessWidget {
  const _Perks();

  @override
  Widget build(BuildContext context) {
    const perks = [
      (Icons.shield_rounded, BrokaColors.success, 'Escrow'),
      (Icons.phone_iphone_rounded, BrokaColors.neonGreen, 'M-Pesa'),
      (Icons.local_shipping_outlined, BrokaColors.neonCyan, 'Delivery'),
    ];
    return Padding(
      key: const Key('store-perks'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.72),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(children: [
          for (final (i, (icon, color, label)) in perks.indexed) ...[
            if (i > 0) Container(width: 1, height: 18, color: BrokaColors.border),
            Expanded(
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? BrokaColors.gold.withOpacity(0.18) : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? BrokaColors.gold : BrokaColors.border),
            ),
            child: Text(label, style: TextStyle(
                color: selected ? _accent : BrokaColors.textMid,
                fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
          ),
        ),
      );
}

/// "All products · 12" over the grid, and the order they're in.
class _CatalogueHeading extends StatelessWidget {
  const _CatalogueHeading({required this.title, required this.count, required this.sort});
  final String title;

  /// Null when a search or filter makes the total unknown.
  final int? count;
  final StoreSort sort;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Row(children: [
          Flexible(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                    fontWeight: FontWeight.w800)),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: BrokaColors.gold.withOpacity(0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$count', style: const TextStyle(color: _accent, fontSize: 12,
                  fontWeight: FontWeight.w800)),
            ),
          ],
          const Spacer(),
          if (sort != StoreSort.featured)
            Text(sort.label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        ]),
      );
}

/// Once something is in the cart: how many, the total, and View cart -
/// always on screen while shopping, as a shop's cart bar is.
class _CartBar extends StatelessWidget {
  const _CartBar({required this.cart, required this.onOpen});
  final StoreCart cart;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Material(
            key: const Key('store-cart-bar'),
            color: Colors.transparent,
            child: InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(18),
              child: Ink(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFF2A1A5E), Color(0xFF0E1B3D)]),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: BrokaColors.gold.withOpacity(0.6)),
                  boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.3), blurRadius: 18)],
                ),
                child: Row(children: [
                  Badge(
                    backgroundColor: BrokaColors.neonPink,
                    label: Text('${cart.count}'),
                    child: const Icon(Icons.shopping_cart_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min, children: [
                      Text('${cart.count} item${cart.count == 1 ? '' : 's'} in your cart',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(formatKes(cart.subtotal), style: const TextStyle(
                            color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
                      ),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('View cart', style: TextStyle(color: Colors.white,
                          fontWeight: FontWeight.w800, fontSize: 13.5)),
                      Icon(Icons.chevron_right_rounded, color: Colors.white, size: 18),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
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
