// A store's home in the app - the "mini Jumia" a buyer lands on from a
// shared link, a product's store badge, or the store directory. Laid out as
// a shop, not a profile:
//
//   bar       back, the name once the hero has scrolled away, More, share,
//             and the cart with how many items are in it
//   hero      the shop itself: its cover photo (else a shop photo, else
//             what the store sells - the category's own artwork - else
//             moving colour), its sign, its name big, whether the owner
//             is online, the seller's record, and what to do next:
//             Message Store and Follow
//   perks     what buying here means: see it before you pay, M-Pesa,
//             delivery or pickup
//   products  Home's search pill and filter button (sort, condition,
//             price), Shop by Category (the types of item on each shelf,
//             with their pictures), the Featured rail, and the catalogue
//             as shop cards with save hearts, stock and Add to cart
//   cart bar  once something is in the cart: items, total, View cart
//
// The bar's More button opens Store details
// (widgets/store_details_view.dart): the seller's record, the shop's
// photos, about, location, contact, store info and how to pay the store
// safely.
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
import '../../../theme/motion.dart';
import '../../../utils/auth_gate.dart';
import '../../../utils/price_format.dart';
import '../../../widgets/broka_search_field.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../../categories/domain/category_visual.dart';
import '../../categories/domain/subcategory_visual.dart';
import '../../categories/presentation/widgets/category_art_card.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/store_categories.dart';
import '../data/store_cart.dart';
import '../data/store_share.dart';
import '../domain/models/store.dart';
import 'store_cart_screen.dart';
import 'store_media_image.dart';
import 'widgets/broka_default_logo.dart';
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
    this.listings,
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

  /// The save hearts' repository. Injectable for tests; the app uses the
  /// shared one.
  final ListingsRepository? listings;
  final StoreShare? share;

  /// Also stills the hero's colours (tests, and anyone who asked for less
  /// motion gets a still hero regardless).
  final bool animateBackground;

  @override
  State<StoreHomeScreen> createState() => _StoreHomeScreenState();
}

class _StoreHomeScreenState extends State<StoreHomeScreen> {
  StoresRepository get _repo => widget.repository ?? storesRepository;
  ListingsRepository get _listings => widget.listings ?? listingsRepository;

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

  /// Whether this viewer follows the store, and how many do - from the
  /// store read, then moved by the Follow button without re-reading.
  bool _following = false;
  int _followerCount = 0;
  bool _followBusy = false;

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
  /// The Shop by Category tile in force: a type of item, which implies
  /// its parent - so setting one clears [_category], and vice versa.
  String? _subcategoryId;
  String? _subcategoryName;
  String _search = '';
  StoreSort _sort = StoreSort.featured;
  String? _condition;
  StorePriceBand? _price;
  bool _filtersOpen = false;
  Timer? _searchDebounce;
  final _searchCtrl = TextEditingController();
  final _grid = ProductGridController();

  /// The Featured rail: the store's featured products, read once with
  /// the categories. Null until the read lands; empty hides the rail.
  List<BrokaListing>? _featured;

  bool get _filtersActive => _sort != StoreSort.featured || _condition != null || _price != null;

  /// Nothing narrows the catalogue: the Featured rail and the full
  /// heading show, and one product owns the catalogue width.
  bool get _unfiltered =>
      _search.isEmpty && !_filtersActive && _category == null && _subcategoryId == null;

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
        setState(() {
          _store = data;
          _storeId = data.id;
          _loading = false;
          _following = data.viewerFollowing;
          _followerCount = data.followerCount;
        });
        if (_openDetails) {
          _openDetails = false;
          // After this frame, so the store's home is under the details.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              showStoreDetails(context, data, animateBackground: widget.animateBackground,
                  repository: _repo);
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
    await Future.wait([_loadCategories(), _loadFeatured(), _checkOwnerAndCountVisit()]);
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
      // Online stores never browse by Property, Automobiles, Land, Services
      // or Other - the backend already filters goods rails, this keeps older
      // backends and cached rows consistent on the client too.
      final visible = data
          .where((c) => StoreCategories.isOnlineListingCategory(c.name))
          .toList(growable: false);
      setState(() {
        _categories = visible;
        if (_category != null && !visible.any((c) => c.name == _category)) _category = null;
        if (_subcategoryId != null &&
            !visible.any((c) => c.subcategories.any((s) => s.id == _subcategoryId))) {
          _subcategoryId = null;
          _subcategoryName = null;
        }
      });
    }
  }

  /// The Featured rail's products: the catalogue's own first page,
  /// unfiltered, keeping the featured ones. The backend's featured
  /// sort puts them first, so one page is the whole rail. A paused
  /// store has no catalogue showing, so the rail never reads either.
  Future<void> _loadFeatured() async {
    final id = _storeId;
    if (id == null) return;
    if (!(_store?.isActive ?? false)) return;
    final result = await _repo.getStoreListings(id, limit: 20);
    if (!mounted) return;
    if (result case Success(:final data)) {
      setState(() => _featured =
          data.where((l) => l.isFeatured).take(8).toList(growable: false));
    }
    // A failed rail read stays hidden: the rail is the catalogue's
    // highlight, and the catalogue's own retry is the one that matters.
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
    if (result case Success(:final data)) {
      setState(() {
        _store = data;
        _following = data.viewerFollowing;
        _followerCount = data.followerCount;
      });
    }
    await Future.wait([_loadCategories(), _loadFeatured(), _grid.refresh()]);
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
      showStoreDetails(context, store, animateBackground: widget.animateBackground,
          repository: _repo);

  void _openCart(Store store) => openStoreCart(context,
      storeId: store.id, storeName: store.name, animateBackground: widget.animateBackground);

  /// Message the store: straight into the store-general chat with the
  /// owner, no Zeno and no product in between. The thread is keyed by the
  /// store itself, so it stays in the Inbox whatever happens to any one
  /// listing - and a store with nothing live can still be talked to.
  Future<void> _messageStore(Store store) async {
    if (!await requireAuth(context, reason: 'to message this store')) return;
    if (!mounted) return;
    Navigator.pushNamed(context, '/direct-chat', arguments: {
      'storeId': store.id,
      'storeName': store.name,
      'role': 'buyer',
    });
  }

  /// Follows the store, or takes the follow back. Shown at once; put
  /// back, with a word, if the server says no.
  Future<void> _toggleFollow(Store store) async {
    if (_followBusy) return;
    if (!await requireAuth(context, reason: 'to follow stores')) return;
    if (!mounted) return;
    final next = !_following;
    setState(() {
      _following = next;
      _followerCount += next ? 1 : -1;
      _followBusy = true;
    });
    final result =
        next ? await _repo.followStore(store.id) : await _repo.unfollowStore(store.id);
    if (!mounted) return;
    setState(() => _followBusy = false);
    switch (result) {
      case Success(:final data):
        setState(() {
          _following = data.following;
          _followerCount = data.followerCount;
        });
      case Failure(:final message):
        setState(() {
          _following = !next;
          _followerCount += next ? -1 : 1;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Tapping the selected tile again clears it: the rail has no All
  /// tile, so this is how a shelf is closed.
  void _selectCategory(String? name) => setState(() {
        _category = _category == name ? null : name;
        _subcategoryId = null;
        _subcategoryName = null;
      });

  void _selectSubcategory(String id, String name) => setState(() {
        if (_subcategoryId == id) {
          _subcategoryId = null;
          _subcategoryName = null;
        } else {
          _subcategoryId = id;
          _subcategoryName = name;
          _category = null;
        }
      });

  /// The catalogue heading scrolls into view: what "See all" does after
  /// clearing a shelf.
  final _catalogueKey = GlobalKey();

  void _seeAll() {
    setState(() {
      _category = null;
      _subcategoryId = null;
      _subcategoryName = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _catalogueKey.currentContext;
      if (target != null) Scrollable.ensureVisible(target, duration: BrokaMotion.quick);
    });
  }

  /// The Shop by Category rail's tiles: one per type of item where the
  /// store filed them, else one per category. A shelf with filed types
  /// shows only those - the unfiled remainder stays in the catalogue
  /// and under the sheet's "All in …" row, never as a tile whose count
  /// would disagree with what tapping it shows.
  List<_RailTile> get _railTiles => [
        for (final c in _categories)
          if (c.subcategories.isNotEmpty)
            for (final s in c.subcategories)
              _RailTile.subcategory(parent: c.name, sub: s)
          else
            _RailTile.category(c),
      ];

  int? _subcategoryCount(String id) {
    for (final c in _categories) {
      for (final s in c.subcategories) {
        if (s.id == id) return s.count;
      }
    }
    return null;
  }

  Future<List<dynamic>> _fetchPage(int page) async {
    final result = await _repo.getStoreListings(
      _storeId!,
      limit: 20,
      offset: page * 20,
      search: _search,
      category: _category,
      subcategoryId: _subcategoryId,
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
      final featured = _featured;
      final showFeatured =
          _unfiltered && featured != null && featured.isNotEmpty;
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
            isOwner: _isOwner,
            following: _following,
            followerCount: _followerCount,
            followBusy: _followBusy,
            onMessage: () => _messageStore(store),
            onFollow: () => _toggleFollow(store),
          )),
          if (store.isActive) ...[
            const SliverToBoxAdapter(child: _Perks()),
            SliverToBoxAdapter(child: _searchRow(store)),
            if (_filtersOpen) SliverToBoxAdapter(child: _filterPanel()),
            if (_railTiles.length > 1)
              SliverToBoxAdapter(child: _CategoryRail(
                categories: _categories,
                selectedCategory: _category,
                selectedSubcategory: _subcategoryId,
                onSelectCategory: _selectCategory,
                onSelectSubcategory: _selectSubcategory,
                onViewAll: () => _CategorySheet.show(
                  context,
                  categories: _categories,
                  selectedCategory: _category,
                  selectedSubcategory: _subcategoryId,
                  onSelectCategory: _selectCategory,
                  onSelectSubcategory: _selectSubcategory,
                ),
              )),
            if (showFeatured)
              SliverToBoxAdapter(child: _FeaturedRail(
                featured: featured,
                cart: cart,
                isOwner: _isOwner,
                listings: _listings,
                onOpen: (id) => Navigator.of(context).pushNamed('/product',
                    arguments: {'listingId': id}),
                onAddBlocked: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text(
                        'This is your own store - buyers add to cart here.'))),
                onSeeAll: _seeAll,
              )),
            SliverToBoxAdapter(child: _CatalogueHeading(
              key: _catalogueKey,
              title: _subcategoryName ?? _category ?? 'All products',
              count: filtered
                  ? null
                  : _subcategoryId != null
                      ? _subcategoryCount(_subcategoryId!)
                      : _category == null
                          ? store.listingCount
                          : _categories.where((c) => c.name == _category).firstOrNull?.count,
              sort: _sort,
            )),
            ProductGridView(
              key: ValueKey('${_category ?? ''}|${_subcategoryId ?? ''}|$_search|'
                  '${_sort.value}|${_condition ?? ''}|${_price?.name ?? ''}'),
              sliver: true,
              controller: _grid,
              // The catalogue owns the row only when the store itself
              // holds one product and nothing narrows it: a search or
              // filter that happens to leave one hit keeps the normal
              // grid, so one result never blows up into a giant card.
              // Other screens keep the fixed two-column marketplace grid.
              adaptToItemCount: _unfiltered,
              fetchPage: _fetchPage,
              // The same 12dp sides as Home's feed: a store's shelf shows
              // the same tile as the marketplace.
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              itemTextBlock: StoreProductCard.textBlock,
              itemImageShare: StoreProductCard.imageShare,
              itemBuilder: (_, item) => StoreProductCard(
                listing: item as BrokaListing,
                cart: cart,
                showSave: !_isOwner,
                listings: _listings,
                onTap: () => Navigator.of(context).pushNamed('/product',
                    arguments: {'listingId': item.id}),
                onAddBlocked: _isOwner
                    ? () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('This is your own store - buyers add to cart here.')))
                    : null,
              ),
              emptyStateBuilder: (_) => _EmptyCatalogue(
                filtered: filtered || _category != null || _subcategoryId != null,
              ),
            ),
          ],
          const SliverToBoxAdapter(child: _PoweredFooter()),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ]),
      );
    }

    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        // A calmed sky behind the catalogue: the constellation stays
        // strongest around the store's identity (the hero keeps its own
        // aurora) instead of competing with product photography.
        intensity: 0.35,
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

  /// The search box every other screen with one inside it uses
  /// (widgets/broka_search_field.dart), searching this store only, and the
  /// filter button beside it at the same height.
  ///
  /// This was the last copy of Home's old 44px header pill - 14px typed text
  /// under a 12.5px dim hint, small enough that people couldn't read back
  /// what they had typed (the reason the Zones, Traders and Stores moved to
  /// the shared field), with its own colours.
  Widget _searchRow(Store store) {
    final height = BrokaSearchField.heightFor(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(children: [
        Expanded(
          child: BrokaSearchField(
            fieldKey: const Key('store-search'),
            controller: _searchCtrl,
            hintText: 'Search ${store.name}',
            onChanged: _onSearchChanged,
            onSubmitted: (v) {
              _searchDebounce?.cancel();
              setState(() => _search = v.trim());
            },
            onCleared: () {
              _searchDebounce?.cancel();
              setState(() => _search = '');
            },
          ),
        ),
        const SizedBox(width: 10),
        Semantics(
          button: true,
          label: 'Filters',
          child: GestureDetector(
            key: const Key('store-filter'),
            onTap: () => setState(() => _filtersOpen = !_filtersOpen),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: height,
              height: height,
              decoration: BoxDecoration(
                color: _filtersOpen
                    ? BrokaColors.gold.withOpacity(0.2)
                    : BrokaColors.bgCard.withOpacity(0.92),
                borderRadius: BorderRadius.circular(height / 2),
                // Quiet at rest, violet while open or filtering — the gold
                // dot beside it says a filter is actually applied.
                border: Border.all(
                  color: _filtersOpen || _filtersActive
                      ? BrokaColors.gold
                      : BrokaColors.border,
                  width: 1,
                ),
              ),
              child: Stack(clipBehavior: Clip.none, children: [
                Center(
                  child: Icon(Icons.tune_rounded,
                      color: _filtersOpen || _filtersActive ? _accent : BrokaColors.textMid,
                      size: 22),
                ),
                if (_filtersActive)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      key: const Key('store-filters-active-dot'),
                      width: 8,
                      height: 8,
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
  }

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
        // pinned, so this is always one tap away.
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
              backgroundColor: BrokaColors.gold,
              label: Text('$cartCount', key: const Key('store-cart-count'),
                  style: const TextStyle(color: Colors.white)),
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

/// The top of the store: its sign beside its name in solid white over a
/// photo of the shop - the store's sign over its own door. Under the
/// name: what and where, one facts row (presence, the seller's
/// record, deals, followers), and what to do next: Message Store and
/// Follow.
class _StoreHero extends StatefulWidget {
  const _StoreHero({
    required this.store,
    required this.animate,
    required this.isOwner,
    required this.following,
    required this.followerCount,
    required this.followBusy,
    required this.onMessage,
    required this.onFollow,
  });
  final Store store;
  final bool animate;
  final bool isOwner;
  final bool following;
  final int followerCount;
  final bool followBusy;
  final VoidCallback onMessage;
  final VoidCallback onFollow;

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
    final place = [
      if (store.categories.isNotEmpty) store.categories.join(', '),
      store.locationLine,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final verified = owner?.verified ?? false;
    final rating = owner?.shownRating;
    final reviews = owner?.reviewCount ?? 0;
    final deals = owner?.completedDeals ?? 0;
    // What the hero stands on, best first: a photo of the shop, else
    // what the store sells (its primary category's own artwork), else
    // the moving aurora - which is then the only thing behind the
    // words, as before.
    final photo = store.coverSource;
    final art = photo == null
        ? CategoryVisuals.resolve(
            store.category ?? store.categories.firstOrNull).assetPath
        : null;

    return Padding(
      key: const Key('store-identity'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            // One soft drop shadow: the card sits on the surface instead of
            // glowing over it, so the products below stay the brightest
            // thing on screen.
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 18,
                  offset: const Offset(0, 8)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(children: [
              // The aurora is always underneath: it fills the edges while
              // a photo loads, and is the whole background when there is
              // nothing else to show.
              Positioned.fill(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _t,
                    builder: (_, __) => CustomPaint(
                      painter: _AuroraPainter(t: _t.value),
                    ),
                  ),
                ),
              ),
              if (photo != null)
                Positioned.fill(
                  child: StoreMediaImage(
                    key: const Key('store-hero-photo'),
                    dataUri: photo,
                    fit: BoxFit.cover,
                  ),
                )
              else if (art != null)
                Positioned.fill(
                  child: Image.asset(
                    art,
                    key: const Key('store-hero-photo'),
                    fit: BoxFit.cover,
                    alignment: const Alignment(0.45, 0),
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              // What keeps white words readable over any photo: a dark
              // wash, deepest where the words sit.
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xD6000000), Color(0x66000000), Color(0x22000000)],
                      stops: [0.0, 0.6, 1.0],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.10)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // The shop's sign beside its name: its own logo, or
                  // BROKA's mark when the owner uploaded none - the same
                  // sign the store card hangs over its picture. Round and
                  // in BROKA's ring, not the old rounded square that read
                  // as a profile photo. The name sits next to it in solid
                  // white (the old shimmer ran through the letters and
                  // competed with the aurora behind them); verification is
                  // a tick on the name, and presence, rating and deals
                  // share one facts row below.
                  Row(children: [
                    _HeroLogo(store: store, size: 60),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(children: [
                              Flexible(
                                child: Text(
                                  store.name,
                                  key: const Key('store-hero-name'),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: store.name.length > 18 ? 22 : 26,
                                    fontWeight: FontWeight.w800,
                                    height: 1.1,
                                    letterSpacing: -0.4,
                                    shadows: [
                                      Shadow(color: Colors.black.withOpacity(0.5),
                                          blurRadius: 6),
                                    ],
                                  ),
                                ),
                              ),
                              if (verified) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.verified_rounded,
                                    color: BrokaColors.success, size: 18),
                              ],
                            ]),
                            if (place.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(place,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.75),
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500)),
                            ],
                          ]),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    if (owner != null && (owner.online || owner.lastActive != null))
                      _PresenceChip(online: owner.online, label: owner.lastActive),
                    _GlassChip(
                      key: const Key('hero-rating'),
                      icon: Icons.star_rounded,
                      iconColor: BrokaColors.zoneAmber,
                      // The seller's buyer-review average, on its own
                      // /5 scale and with the count behind it. Deals
                      // alone used to produce a rating here (the 5.0
                      // default), and a bare number read as the shop's
                      // 0-10 score.
                      label: rating != null
                          ? '${rating.toStringAsFixed(1)}/5 · '
                              '${reviews == 1 ? '1 review' : '$reviews reviews'}'
                          : 'No reviews yet',
                      semantics: rating != null
                          ? 'Seller rating ${rating.toStringAsFixed(1)} out of 5 '
                              'from $reviews reviews'
                          : 'Seller has no reviews yet',
                    ),
                    _GlassChip(
                      key: const Key('hero-deals'),
                      icon: Icons.handshake_outlined,
                      iconColor: BrokaColors.neonCyan,
                      label: '$deals deal${deals == 1 ? '' : 's'}',
                    ),
                    // Followers only once there are some: "0 followers"
                    // on a new shop is honest but bleak, and the Follow
                    // button below already invites the first one.
                    if (widget.followerCount > 0)
                      _GlassChip(
                        key: const Key('hero-followers'),
                        icon: Icons.people_outline_rounded,
                        iconColor: BrokaColors.neonPink,
                        label: '${widget.followerCount} follower'
                            '${widget.followerCount == 1 ? '' : 's'}',
                      ),
                  ]),
                  // What to do next. The owner gets no buttons here -
                  // Manage in the bar is theirs - and a paused store
                  // offers nothing until it is back.
                  if (!widget.isOwner && store.isActive) ...[
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: _HeroAction(
                          key: const Key('store-message-button'),
                          icon: Icons.chat_bubble_outline_rounded,
                          label: 'Message Store',
                          primary: true,
                          onTap: widget.onMessage,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _HeroAction(
                          key: const Key('store-follow-button'),
                          icon: widget.following
                              ? Icons.check_rounded
                              : Icons.person_add_outlined,
                          label: widget.following ? 'Following' : 'Follow',
                          primary: false,
                          busy: widget.followBusy,
                          onTap: widget.onFollow,
                        ),
                      ),
                    ]),
                  ],
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

/// Moving aurora: soft blobs of BROKA's own violet, blue and cyan (the
/// splash logo's gradient) drifting under a field of twinkling stars, with
/// a sheen sweeping across. [t] runs 0 to 1 and loops seamlessly.
///
/// Was tinted by the store's category - amber for food, green for farming,
/// with pink through every one - so a store's first screen was the one
/// place in the app that didn't look like BROKA. The category still shows,
/// in words under the name and on the category rail.
class _AuroraPainter extends CustomPainter {
  _AuroraPainter({required this.t});
  final double t;

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
    canvas.drawRect(Offset.zero & size, Paint()..color = BrokaColors.bgMid);
    final a = t * 2 * math.pi;
    final blobs = [
      (BrokaColors.gold, 0.15, 0.25, 0.70),
      (BrokaColors.goldDim, 0.85, 0.15, 0.75),
      (BrokaColors.neonBlue, 0.70, 0.95, 0.65),
      (BrokaColors.neonCyan, 0.05, 1.00, 0.55),
      (BrokaColors.neonPurple, 0.50, 0.50, 0.40),
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
          color.withOpacity(i == 4 ? 0.22 : 0.42),
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
            (i.isEven ? BrokaColors.neonCyan : BrokaColors.neonBlue).withOpacity(0.28),
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
      star.color = Colors.white.withOpacity(0.08 + 0.35 * twinkle);
      canvas.drawCircle(Offset(s.x * w, s.y * h), s.r, star);
    }
    // The sheen: a faint diagonal band crossing once per loop.
    final x = (t * 2.4 - 0.7) * w;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.transparent, Colors.white.withOpacity(0.04), Colors.transparent],
          stops: const [0.0, 0.5, 1.0],
          transform: const GradientRotation(-0.5),
        ).createShader(Rect.fromLTWH(x, 0, w * 0.35, h)),
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t;
}

/// The shop's sign on the hero: the store's own logo, or BROKA's mark when
/// none was uploaded. Round, in BROKA's gradient ring - the store card's
/// sign, carried onto the first screen a buyer sees.
class _HeroLogo extends StatelessWidget {
  const _HeroLogo({required this.store, required this.size});
  final Store store;
  final double size;

  @override
  Widget build(BuildContext context) {
    final source = store.logoSource;
    return Container(
      key: const Key('store-hero-logo'),
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(colors: BrokaColors.brandGradient),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 10)],
      ),
      child: Container(
        decoration: const BoxDecoration(shape: BoxShape.circle, color: BrokaColors.bgMid),
        clipBehavior: Clip.antiAlias,
        child: source == null
            ? const BrokaDefaultLogo()
            : StoreMediaImage(
                dataUri: source,
                fit: BoxFit.cover,
                placeholderBuilder: (_) => const BrokaDefaultLogo(),
              ),
      ),
    );
  }
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.30),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.14)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: iconColor, semanticLabel: semantics),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11.5,
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
/// One of the hero's two actions: Message Store (the loud gradient, the
/// first thing a buyer does here) or Follow (a quiet outline - it is the
/// second thing). Both full-width halves of the same row, 48dp tall.
class _HeroAction extends StatelessWidget {
  const _HeroAction({
    super.key,
    required this.icon,
    required this.label,
    required this.primary,
    required this.onTap,
    this.busy = false,
  });
  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: primary
                  ? const LinearGradient(
                      colors: [BrokaColors.gold, BrokaColors.neonBlue])
                  : null,
              color: primary ? null : Colors.black.withOpacity(0.35),
              border: primary
                  ? null
                  : Border.all(color: BrokaColors.gold.withOpacity(0.65)),
              boxShadow: primary
                  ? [BoxShadow(color: BrokaColors.gold.withOpacity(0.4), blurRadius: 14)]
                  : null,
            ),
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2,
                        color: Colors.white),
                  )
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 19, color: Colors.white),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 14.5,
                              fontWeight: FontWeight.w800)),
                    ),
                  ]),
          ),
        ),
      );
}

/// What buying from a store on BROKA means, in the strip shops put under
/// their banner. Every word is true of every store: the buyer sees the item
/// before paying the store, it's by M-Pesa, and delivery (or pickup) is
/// agreed in the deal. It said "Escrow" while BROKA held payments; it holds
/// none now, and a strip promising escrow is what a fraudster quotes when
/// asking for money "into BROKA escrow".
class _Perks extends StatelessWidget {
  const _Perks();

  @override
  Widget build(BuildContext context) {
    const perks = [
      (Icons.visibility_outlined, BrokaColors.success, 'See, then pay'),
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
  const _CatalogueHeading(
      {super.key, required this.title, required this.count, required this.sort});
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
                  gradient: BrokaColors.cardGradient,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: BrokaColors.gold.withOpacity(0.6)),
                  boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.3), blurRadius: 18)],
                ),
                child: Row(children: [
                  Badge(
                    backgroundColor: BrokaColors.neonBlue,
                    label: Text('${cart.count}', style: const TextStyle(color: Colors.white)),
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

/// One tile of the Shop by Category rail: a type of item where the store
/// filed them ("Phones", with the phones picture), else a whole category.
/// Whole-category tiles keep the old pill keys, so tapping "Gaming" is
/// the same tap it always was.
class _RailTile {
  _RailTile.subcategory({required this.parent, required StoreSubcategoryCount sub})
      : id = sub.id,
        name = sub.name,
        count = sub.count,
        isSubcategory = true;
  _RailTile.category(StoreCategoryCount c)
      : parent = c.name,
        id = null,
        name = c.name,
        count = c.count,
        isSubcategory = false;

  /// The category the tile belongs to: what its picture falls back to,
  /// and the catalogue filter for a whole-category tile.
  final String parent;

  /// The catalogue filter for a type-of-item tile; null for a whole
  /// category, which filters by [name] instead.
  final String? id;
  final String name;
  final int count;
  final bool isSubcategory;

  Key get key => Key(isSubcategory ? 'store-subcategory-$id' : 'category-pill-$name');
}

/// Shop by Category: the store's shelves as picture tiles in the same
/// frames Home's categories use, so "Phones" shows the phones picture -
/// never a category's picture under a type of item's name. A selected
/// tile wears the gold ring; tapping it again clears it. View all opens
/// every shelf at once.
class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.categories,
    required this.selectedCategory,
    required this.selectedSubcategory,
    required this.onSelectCategory,
    required this.onSelectSubcategory,
    required this.onViewAll,
  });

  final List<StoreCategoryCount> categories;
  final String? selectedCategory;
  final String? selectedSubcategory;
  final ValueChanged<String?> onSelectCategory;
  final void Function(String id, String name) onSelectSubcategory;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final tiles = <_RailTile>[
      for (final c in categories)
        if (c.subcategories.isNotEmpty)
          for (final s in c.subcategories) _RailTile.subcategory(parent: c.name, sub: s)
        else
          _RailTile.category(c),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Row(children: [
          const Expanded(
            child: Text('Shop by Category',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                    fontWeight: FontWeight.w800)),
          ),
          TextButton(
            key: const Key('store-categories-view-all'),
            onPressed: onViewAll,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Text('View all', style: TextStyle(color: _accent, fontSize: 13,
                  fontWeight: FontWeight.w700)),
              Icon(Icons.arrow_forward_rounded, color: _accent, size: 16),
            ]),
          ),
        ]),
      ),
      SizedBox(
        height: 128,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          itemCount: tiles.length,
          itemBuilder: (_, i) {
            final tile = tiles[i];
            final isSelected = tile.isSubcategory
                ? tile.id == selectedSubcategory
                : tile.name == selectedCategory;
            final visual = tile.isSubcategory
                ? SubcategoryVisuals.resolve(tile.parent, tile.name)
                : null;
            final parentVisual = CategoryVisuals.resolve(tile.parent);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Semantics(
                button: true,
                selected: isSelected,
                label: '${tile.name}, ${tile.count} product${tile.count == 1 ? '' : 's'}',
                child: GestureDetector(
                  key: tile.key,
                  onTap: () => tile.isSubcategory
                      ? onSelectSubcategory(tile.id!, tile.name)
                      : onSelectCategory(tile.name),
                  child: Container(
                    width: 104,
                    padding: EdgeInsets.all(isSelected ? 2 : 0),
                    decoration: isSelected
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: BrokaColors.gold, width: 2),
                            boxShadow: [BoxShadow(
                                color: BrokaColors.gold.withOpacity(0.35),
                                blurRadius: 8)],
                          )
                        : null,
                    child: CategoryArtCard(
                      label: tile.name,
                      caption: '${tile.count} item${tile.count == 1 ? '' : 's'}',
                      emoji: visual?.emoji ?? parentVisual.emoji,
                      gradient: visual?.gradient ?? parentVisual.gradient,
                      assetPath: visual?.assetPath ?? parentVisual.assetPath,
                      onTap: () => tile.isSubcategory
                          ? onSelectSubcategory(tile.id!, tile.name)
                          : onSelectCategory(tile.name),
                      labelSize: 11.5,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ── States ───────────────────────────────────────────────────────────────────

/// Featured Products: the store's featured products as shop cards in a
/// sideways rail - the same cards the catalogue uses, with their save
/// hearts, stock and Add to cart, so anything done here shows there.
/// Only while nothing narrows the catalogue; See all drops to it.
class _FeaturedRail extends StatelessWidget {
  const _FeaturedRail({
    required this.featured,
    required this.cart,
    required this.isOwner,
    required this.listings,
    required this.onOpen,
    required this.onAddBlocked,
    required this.onSeeAll,
  });

  final List<BrokaListing> featured;
  final StoreCart cart;
  final bool isOwner;
  final ListingsRepository listings;
  final ValueChanged<String> onOpen;
  final VoidCallback onAddBlocked;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    // A card is as wide as a catalogue column is narrow: the rail shows
    // one and a peek of the next, inviting the sideways scroll.
    final width = math.min(MediaQuery.sizeOf(context).width * 0.52, 240.0);
    // The photo over the card's text block, as the catalogue sizes it.
    final height =
        width * StoreProductCard.imageShare + StoreProductCard.textBlock + 8;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Row(children: [
          const Expanded(
            child: Text('🔥 Featured Products',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                    fontWeight: FontWeight.w800)),
          ),
          TextButton(
            key: const Key('store-featured-see-all'),
            onPressed: onSeeAll,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Text('See all', style: TextStyle(color: _accent, fontSize: 13,
                  fontWeight: FontWeight.w700)),
              Icon(Icons.arrow_forward_rounded, color: _accent, size: 16),
            ]),
          ),
        ]),
      ),
      SizedBox(
        height: height,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          itemCount: featured.length,
          itemBuilder: (_, i) {
            final listing = featured[i];
            return SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: StoreProductCard(
                  listing: listing,
                  cart: cart,
                  showSave: !isOwner,
                  listings: listings,
                  onTap: () => onOpen(listing.id),
                  onAddBlocked: isOwner ? onAddBlocked : null,
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

/// Every shelf at once: the Shop by Category View-all sheet. Each
/// category keeps its "All in …" row (the whole shelf, filed or not)
/// over its types of item, each with its picture and count. Picking
/// one filters the catalogue and closes the sheet.
class _CategorySheet extends StatelessWidget {
  const _CategorySheet({
    required this.categories,
    required this.selectedCategory,
    required this.selectedSubcategory,
    required this.onSelectCategory,
    required this.onSelectSubcategory,
  });

  final List<StoreCategoryCount> categories;
  final String? selectedCategory;
  final String? selectedSubcategory;
  final ValueChanged<String?> onSelectCategory;
  final void Function(String id, String name) onSelectSubcategory;

  static Future<void> show(
    BuildContext context, {
    required List<StoreCategoryCount> categories,
    required String? selectedCategory,
    required String? selectedSubcategory,
    required ValueChanged<String?> onSelectCategory,
    required void Function(String id, String name) onSelectSubcategory,
  }) =>
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withOpacity(0.62),
        isScrollControlled: true,
        builder: (_) => _CategorySheet(
          categories: categories,
          selectedCategory: selectedCategory,
          selectedSubcategory: selectedSubcategory,
          onSelectCategory: onSelectCategory,
          onSelectSubcategory: onSelectSubcategory,
        ),
      );

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: BrokaColors.textMid.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Text('Shop by Category',
                  style: TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                      fontWeight: FontWeight.w800)),
            ),
            Expanded(
              child: ListView.builder(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                itemCount: categories.length,
                itemBuilder: (_, i) {
                  final c = categories[i];
                  final parentVisual = CategoryVisuals.resolve(c.name);
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SheetRow(
                          rowKey: Key('store-category-all-$i'),
                          title: 'All in ${c.name}',
                          count: c.count,
                          assetPath: parentVisual.assetPath,
                          emoji: parentVisual.emoji,
                          gradient: parentVisual.gradient,
                          selected: c.name == selectedCategory,
                          onTap: () {
                            onSelectCategory(c.name);
                            Navigator.of(context).pop();
                          },
                        ),
                        for (final s in c.subcategories)
                          Builder(builder: (_) {
                            final visual =
                                SubcategoryVisuals.resolve(c.name, s.name);
                            final selected = s.id == selectedSubcategory;
                            return Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: _SheetRow(
                                rowKey: Key('store-subcategory-row-${s.id}'),
                                title: s.name,
                                count: s.count,
                                assetPath:
                                    visual.assetPath ?? parentVisual.assetPath,
                                emoji: visual.emoji,
                                gradient: visual.gradient,
                                selected: selected,
                                onTap: () {
                                  onSelectSubcategory(s.id, s.name);
                                  Navigator.of(context).pop();
                                },
                              ),
                            );
                          }),
                      ]);
                },
              ),
            ),
          ]),
        ),
      );
}

/// One shelf row of the View-all sheet: its picture, its name, its
/// count - and the gold ring while it filters the catalogue.
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.rowKey,
    required this.title,
    required this.count,
    required this.assetPath,
    required this.emoji,
    required this.gradient,
    required this.selected,
    required this.onTap,
  });

  final Key rowKey;
  final String title;
  final int count;
  final String? assetPath;
  final String emoji;
  final List<Color> gradient;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: '$title, $count product${count == 1 ? '' : 's'}',
        child: GestureDetector(
          key: rowKey,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.gold.withOpacity(0.12)
                  : Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: selected
                      ? BrokaColors.gold.withOpacity(0.7)
                      : Colors.white.withOpacity(0.08)),
            ),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: assetPath != null
                      ? Image.asset(assetPath!,
                          fit: BoxFit.cover,
                          alignment: const Alignment(0.45, 0),
                          errorBuilder: (_, __, ___) =>
                              _SheetEmoji(emoji: emoji, gradient: gradient))
                      : _SheetEmoji(emoji: emoji, gradient: gradient),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: selected ? BrokaColors.gold : BrokaColors.textHigh,
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: gradient.first.withOpacity(0.5)),
                ),
                child: Text('$count',
                    style: const TextStyle(color: BrokaColors.textHigh,
                        fontSize: 12, fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
        ),
      );
}

/// A shelf row with no picture: its colour and its face.
class _SheetEmoji extends StatelessWidget {
  const _SheetEmoji({required this.emoji, required this.gradient});
  final String emoji;
  final List<Color> gradient;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(gradient: LinearGradient(colors: gradient)),
        alignment: Alignment.center,
        child: Text(emoji, style: const TextStyle(fontSize: 22)),
      );
}

/// The sign at the bottom of every store: whose roof this shop trades
/// under.
class _PoweredFooter extends StatelessWidget {
  const _PoweredFooter();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          // A Wrap, not a Row: the whole sign fits on one line on wide
          // phones, and folds onto two on narrow ones instead of
          // overflowing.
          child: const Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Icon(Icons.storefront_outlined, color: _accent, size: 18),
                Text('Powered by BROKA',
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                SizedBox(
                    height: 14,
                    child: VerticalDivider(
                        color: BrokaColors.textMid, thickness: 1, width: 1)),
                Text('Intelligent Commerce',
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5,
                        fontStyle: FontStyle.italic)),
              ]),
        ),
      );
}

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
