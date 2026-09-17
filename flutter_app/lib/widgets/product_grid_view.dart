// Reusable 2-column paginated grid used by the home feed, category zones,
// search results, and Trending "See All" (Design Journal Volume 6, Ch.11).
// Owns pagination, pull-to-refresh, skeleton loading, and the empty state;
// callers only supply a page fetcher.
import 'package:flutter/material.dart';
import 'product_card.dart';

class ProductGridView extends StatefulWidget {
  final Future<List<dynamic>> Function(int page) fetchPage;
  final void Function(dynamic item)? onTapItem;
  final Widget Function(BuildContext context)? emptyStateBuilder;
  // Store feature (spec §13) - passed straight through to each ProductCard.
  // Optional and additive: a screen that doesn't pass this simply renders
  // cards with no store tap target, exactly like before this existed.
  final void Function(String storeId, String storeSlug)? onViewStore;

  const ProductGridView({
    super.key,
    required this.fetchPage,
    this.onTapItem,
    this.emptyStateBuilder,
    this.onViewStore,
  });

  @override
  State<ProductGridView> createState() => _ProductGridViewState();
}

class _ProductGridViewState extends State<ProductGridView> {
  final List<dynamic> _items = [];
  final ScrollController _scrollController = ScrollController();
  int _page = 0;
  bool _isLoading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadPage(reset: true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final nearBottom = _scrollController.position.pixels >
        _scrollController.position.maxScrollExtent - 400;
    if (nearBottom && !_isLoading && _hasMore) _loadPage();
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
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
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty && _isLoading) {
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.68),
        itemCount: 6,
        itemBuilder: (_, __) => const ProductCardSkeleton(),
      );
    }
    if (_items.isEmpty && !_isLoading) {
      return widget.emptyStateBuilder?.call(context) ?? const Center(child: Text('No listings found'));
    }
    return RefreshIndicator(
      onRefresh: () => _loadPage(reset: true),
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.68),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Center(
                child: Padding(
                    padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2)));
          }
          final item = _items[index];
          return ProductCard(item: item, onTap: () => widget.onTapItem?.call(item),
              onViewStore: widget.onViewStore);
        },
      ),
    );
  }
}
