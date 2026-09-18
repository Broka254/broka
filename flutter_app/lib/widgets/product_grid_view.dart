// Reusable 2-column paginated grid used by the home feed, category zones,
// search results, and Trending "See All" (Design Journal Volume 6, Ch.11).
// Owns pagination, pull-to-refresh, skeleton loading, and the empty state;
// callers only supply a page fetcher.
//
// Home collapsing-scroll pass (2026-09-18, brief §3): this can now render
// either as a self-contained scrollable (the original behaviour, unchanged
// and still the default) or as a SLIVER inside a caller's own
// CustomScrollView (`sliver: true`). The sliver mode exists because Home
// needs one - and only one - vertical scroll owner: its header, discovery
// rail and Zeno CTA scroll away into the same viewport the grid lives in,
// which is impossible while the grid runs its own ScrollController inside
// an Expanded. Every existing caller (trending_screen, category_zone_screen,
// trader_profile_screen, store_view_screen) passes nothing new and keeps the
// exact widget tree it had before.
//
// The two modes differ in three places, all of them consequences of "who
// owns the scrollable":
//   - scroll ownership: box mode keeps its own ScrollController and the
//     400px look-ahead listener; sliver mode has no controller at all and
//     triggers the next page from the item builder instead (see
//     _maybeLoadMore) - the parent's controller is none of this widget's
//     business.
//   - pull-to-refresh: box mode keeps its own RefreshIndicator; in sliver
//     mode the parent wraps the whole CustomScrollView in one, and reaches
//     this state through [ProductGridController].
//   - empty/skeleton states: returned as slivers rather than boxes, since a
//     CustomScrollView can only accept slivers.
import 'package:flutter/material.dart';
import 'product_card.dart';

/// Handle that lets a parent refetch a grid it does not own the scrollable
/// for. Only needed in `sliver: true` mode, where the parent's own
/// RefreshIndicator has to drive this widget's reload and await it.
///
/// Deliberately not a ChangeNotifier and not disposable: it holds a single
/// weak-ish back-reference that the grid attaches on mount and clears on
/// dispose, so a controller outliving its grid is inert rather than a leak.
class ProductGridController {
  _ProductGridViewState? _state;

  void _attach(_ProductGridViewState state) => _state = state;
  void _detach(_ProductGridViewState state) {
    if (identical(_state, state)) _state = null;
  }

  /// True once a grid is mounted and listening.
  bool get isAttached => _state != null;

  /// Refetches from page 0. Completes when the first page has landed, so it
  /// can be returned straight from `RefreshIndicator.onRefresh`.
  Future<void> refresh() async => _state?.reload() ?? Future<void>.value();
}

class ProductGridView extends StatefulWidget {
  final Future<List<dynamic>> Function(int page) fetchPage;
  final void Function(dynamic item)? onTapItem;
  final Widget Function(BuildContext context)? emptyStateBuilder;
  // Store feature (spec §13) - passed straight through to each ProductCard.
  // Optional and additive: a screen that doesn't pass this simply renders
  // cards with no store tap target, exactly like before this existed.
  final void Function(String storeId, String storeSlug)? onViewStore;

  /// Render as a sliver for a caller-owned CustomScrollView instead of as a
  /// self-scrolling box. Defaults to false - the original behaviour.
  ///
  /// When true the caller MUST place the result in a CustomScrollView's
  /// `slivers:` list and owns both the ScrollController and the
  /// RefreshIndicator (see [controller]).
  final bool sliver;

  /// Only meaningful with `sliver: true` - lets the parent's pull-to-refresh
  /// drive this grid. Ignored in box mode, which still owns its own
  /// RefreshIndicator.
  final ProductGridController? controller;

  /// Padding around the grid itself. Defaults to the 12px gutter every
  /// existing caller already got.
  final EdgeInsets padding;

  const ProductGridView({
    super.key,
    required this.fetchPage,
    this.onTapItem,
    this.emptyStateBuilder,
    this.onViewStore,
    this.sliver = false,
    this.controller,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  State<ProductGridView> createState() => _ProductGridViewState();
}

class _ProductGridViewState extends State<ProductGridView> {
  final List<dynamic> _items = [];
  // Box mode only. Sliver mode scrolls inside the caller's viewport and must
  // not create a second controller for it (brief §15: "do not introduce
  // unnecessary controllers"), so this stays null there.
  ScrollController? _scrollController;
  int _page = 0;
  bool _isLoading = false;
  bool _hasMore = true;
  // Set when a fetch throws. Previously a failure was swallowed entirely,
  // which made a network error on page 0 render as the empty state ("No
  // listings found") - indistinguishable from a genuinely empty marketplace,
  // and with no way to retry but leaving the screen. Brief §17 asks for
  // error handling and retry to survive the sliver migration; they have to
  // exist before they can survive it.
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    if (!widget.sliver) {
      _scrollController = ScrollController()..addListener(_onScroll);
    }
    _loadPage(reset: true);
  }

  @override
  void didUpdateWidget(covariant ProductGridView old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _scrollController?.dispose();
    super.dispose();
  }

  void _onScroll() {
    final position = _scrollController!.position;
    final nearBottom = position.pixels > position.maxScrollExtent - 400;
    if (nearBottom && !_isLoading && _hasMore) _loadPage();
  }

  /// Sliver-mode pagination trigger. A lazily-built SliverGrid only builds
  /// the tiles near the viewport, so "the builder was asked for a tile close
  /// to the end of the list" is the same signal the 400px scroll listener
  /// gives in box mode - without needing to know anything about the parent's
  /// controller. Guarded by _isLoading/_hasMore exactly like _onScroll, and
  /// deferred to after the frame because starting a setState-ing fetch from
  /// inside build() is illegal.
  void _maybeLoadMore(int index) {
    if (!widget.sliver) return; // box mode keeps its own scroll listener
    if (_isLoading || !_hasMore || _error != null) return;
    if (index < _items.length - 4) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadPage();
    });
  }

  /// Public entry point for [ProductGridController.refresh].
  ///
  /// Unlike a plain _loadPage(reset: true) this never no-ops: a pull-to-
  /// refresh that lands while page N is already in flight waits for that
  /// fetch to settle and then resets, rather than returning instantly and
  /// snapping the refresh spinner away with nothing reloaded.
  Future<void> reload() async {
    final pending = _pending;
    if (pending != null) await pending;
    if (!mounted) return;
    return _loadPage(reset: true);
  }

  /// The fetch currently in flight, so [reload] can await it. Cleared in
  /// _runLoad's finally, including on the !mounted path.
  Future<void>? _pending;

  Future<void> _loadPage({bool reset = false}) {
    if (_isLoading) return _pending ?? Future<void>.value();
    // _runLoad marks _isLoading before its first await, so by the time this
    // returns the two are consistent.
    return _pending = _runLoad(reset: reset);
  }

  Future<void> _runLoad({bool reset = false}) async {
    setState(() {
      _isLoading = true;
      _error = null;
      if (reset) {
        _page = 0;
        _items.clear();
        _hasMore = true;
      }
    });
    try {
      final results = await widget.fetchPage(_page);
      if (!mounted) return;
      setState(() {
        _items.addAll(results);
        _hasMore = results.isNotEmpty;
        _page += 1;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e;
        });
      }
    } finally {
      _pending = null;
    }
  }

  // Two columns on every device (brief §4: keep the existing two-column
  // marketplace layout), but a taller tile on a narrow one. The card's photo
  // sits in an Expanded above a text block whose height is fixed by its
  // content, so on a 320px-wide phone a 0.68 ratio leaves the image almost
  // nothing and risks a vertical overflow in the text block itself. Giving
  // narrow screens a taller tile spends the extra pixels on the photo and
  // keeps the price/CTA intact (brief §14/§27). Normal phones (>=360dp, the
  // overwhelming majority) keep the exact 0.68 they had before.
  double _childAspectRatio(double width) {
    if (width < 340) return 0.56;
    if (width < 360) return 0.60;
    if (width < 400) return 0.64;
    return 0.68;
  }

  SliverGridDelegate _gridDelegate(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: _childAspectRatio(width),
    );
  }

  Widget _card(int index) {
    _maybeLoadMore(index);
    final item = _items[index];
    return ProductCard(
      item: item,
      onTap: () => widget.onTapItem?.call(item),
      onViewStore: widget.onViewStore,
    );
  }

  Widget _emptyState(BuildContext context) =>
      widget.emptyStateBuilder?.call(context) ??
      const Center(child: Text('No listings found'));

  // Shown in place of the trailing spinner when a *subsequent* page fails,
  // and in place of the whole grid when the first one does.
  Widget _errorState({required bool firstPage}) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 32, color: Colors.white38),
            const SizedBox(height: 10),
            Text(
              firstPage ? "Couldn't load listings" : "Couldn't load more",
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _loadPage(reset: firstPage),
              child: const Text('Retry'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return widget.sliver ? _buildSliver(context) : _buildBox(context);
  }

  // ── Sliver mode (Home) ────────────────────────────────────────────────────
  // Everything returned from here is a sliver. The caller's CustomScrollView
  // is the single scroll owner: no controller, no RefreshIndicator, no
  // nested Scrollable anywhere in this subtree (brief §3).

  Widget _buildSliver(BuildContext context) {
    if (_items.isEmpty && _isLoading) {
      return SliverPadding(
        padding: widget.padding,
        sliver: SliverGrid(
          gridDelegate: _gridDelegate(context),
          delegate: SliverChildBuilderDelegate(
            (_, __) => const ProductCardSkeleton(),
            childCount: 6,
          ),
        ),
      );
    }
    if (_items.isEmpty && _error != null) {
      // hasScrollBody: false lets this size to its content and still stretch
      // to fill a short viewport, so the parent's pull-to-refresh keeps a
      // full-height target to pull against.
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: _errorState(firstPage: true)),
      );
    }
    if (_items.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: _emptyState(context)),
      );
    }
    return SliverPadding(
      padding: widget.padding,
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverGrid(
            gridDelegate: _gridDelegate(context),
            delegate: SliverChildBuilderDelegate(
              (context, index) => _card(index),
              childCount: _items.length,
            ),
          ),
          // Built through a builder delegate, not a SliverToBoxAdapter: an
          // adapter's child is constructed as soon as this widget builds,
          // which put a forever-ticking CircularProgressIndicator in the tree
          // while the user was still looking at the top of the feed. A
          // builder defers it until the viewport (plus cache extent) actually
          // reaches the end of the grid.
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, _) => _footer(),
              childCount: 1,
            ),
          ),
        ],
      ),
    );
  }

  /// End-of-list affordance shared by both modes: a spinner while the next
  /// page is in flight, a retry when it failed, and a quiet full-stop line
  /// once everything has been loaded.
  Widget _footer() {
    if (_error != null) return _errorState(firstPage: false);
    if (_isLoading || _hasMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Center(
        child: Text("That's everything for now",
            style: TextStyle(color: Colors.white38, fontSize: 12)),
      ),
    );
  }

  // ── Box mode (every pre-existing caller) ─────────────────────────────────

  Widget _buildBox(BuildContext context) {
    if (_items.isEmpty && _isLoading) {
      return GridView.builder(
        padding: widget.padding,
        gridDelegate: _gridDelegate(context),
        itemCount: 6,
        itemBuilder: (_, __) => const ProductCardSkeleton(),
      );
    }
    if (_items.isEmpty && _error != null) {
      return RefreshIndicator(
        onRefresh: () => _loadPage(reset: true),
        child: ListView(children: [_errorState(firstPage: true)]),
      );
    }
    if (_items.isEmpty) return _emptyState(context);
    return RefreshIndicator(
      onRefresh: () => _loadPage(reset: true),
      child: GridView.builder(
        controller: _scrollController,
        padding: widget.padding,
        gridDelegate: _gridDelegate(context),
        // Unchanged from before the sliver split: a trailing cell only
        // while there is more to load (or something to retry), never a
        // permanent end-of-list tile in the middle of a grid row.
        itemCount: _items.length + ((_hasMore || _error != null) ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return _error != null
                ? SingleChildScrollView(child: _errorState(firstPage: false))
                : const Center(
                    child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(strokeWidth: 2)));
          }
          return _card(index);
        },
      ),
    );
  }
}
