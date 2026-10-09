// Saved items: the listings this user has hearted (2026-10-09).
//
// The heart on a listing is new - the wishlists table sat unused, so the
// seller dashboard's chance-of-selling score read a "likes" figure nothing
// could ever raise. A save is also a buyer's own shortlist, and this is
// where they find it again. Only listings still on sale are shown.
import 'package:flutter/material.dart';

import '../core/utils/result.dart';
import '../features/listings/data/repositories/listings_repository.dart';
import '../main.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/product_grid_view.dart';

class SavedListingsScreen extends StatefulWidget {
  const SavedListingsScreen({super.key, this.repository, this.animateBackground = true});

  final ListingsRepository? repository;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<SavedListingsScreen> createState() => _SavedListingsScreenState();
}

class _SavedListingsScreenState extends State<SavedListingsScreen> {
  static const _gradient = [BrokaColors.danger, BrokaColors.neonPurple];

  ListingsRepository get _repo => widget.repository ?? listingsRepository;
  final _grid = ProductGridController();

  /// The whole list is one page: a shortlist, not a feed.
  Future<List<dynamic>> _fetch(int page) async {
    if (page > 0) return const [];
    return switch (await _repo.savedListings()) {
      Success(:final data) => data,
      Failure(:final message) => throw Exception(message),
    };
  }

  Future<void> _open(dynamic item) async {
    await Navigator.pushNamed(context, '/product', arguments: {'listingId': item.id as String});
    // An item un-hearted on its screen leaves this list.
    if (mounted) await _grid.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _grid.refresh,
            color: BrokaColors.gold,
            backgroundColor: BrokaColors.bgCard,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: CollapsingScreenHeader(
                    title: 'Saved',
                    emoji: '❤️',
                    gradient: _gradient,
                    onBack: () => Navigator.maybePop(context),
                    narrow: media.size.width < 360,
                    textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                  ),
                ),
                ProductGridView(
                  sliver: true,
                  controller: _grid,
                  fetchPage: _fetch,
                  onTapItem: _open,
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + media.padding.bottom),
                  emptyStateBuilder: (_) => const BrokaEmptyState(
                    emoji: '🤍',
                    gradient: _gradient,
                    headline: 'Nothing saved yet',
                    body: 'Tap the heart on a listing to keep it here for later.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
