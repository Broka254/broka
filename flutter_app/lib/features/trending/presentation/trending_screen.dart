// lib/features/trending/presentation/trending_screen.dart
// Dense grid of the listings the backend ranks highest, fed by the trending
// repository (Design Journal Volume 6, Ch.25).
//
// Destination-alignment pass (2026-09-18): this was a bare AppBar with a bold
// white "Trending" over a flat black scaffold and a ProductGridView owning its
// own scrollable - no constellation, no trace of the pink 🔥 identity the rail
// pill carries, and a header that never moved out of the feed's way. It now
// shares the system Home and the Category Zones use: ConstellationBackground,
// one CustomScrollView with a collapsing pinned header, the grid in sliver
// mode, a 16px content edge and pull-to-refresh. The data layer is untouched -
// same repository call, same pagination, same routes.
import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../../discovery/domain/destination_visual.dart';
import '../data/repositories/trending_repository.dart';
import '../../listings/domain/models/listing.dart';

class TrendingScreen extends StatefulWidget {
  const TrendingScreen({super.key});

  @override
  State<TrendingScreen> createState() => _TrendingScreenState();
}

class _TrendingScreenState extends State<TrendingScreen> {
  static const _visual = DestinationVisuals.trending;

  final _scrollController = ScrollController();
  final _gridController = ProductGridController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<List<dynamic>> _fetchPage(int page) async {
    final result = await trendingRepository.getTrending(page: page);
    return result.fold<List<BrokaListing>>(
      onSuccess: (data) => data,
      onFailure: (_, __) => <BrokaListing>[],
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        child: DecoratedBox(
          // The destination's own colour as a wash OVER the constellation,
          // fading to transparent rather than to bg - the same treatment a
          // Category Zone gets, so a rail destination reads as a place inside
          // BROKA rather than a different app.
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.25,
              colors: [_visual.gradient.first.withOpacity(0.15), Colors.transparent],
              stops: const [0.0, 0.62],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: RefreshIndicator(
              onRefresh: _gridController.refresh,
              color: BrokaColors.gold,
              backgroundColor: BrokaColors.bgCard,
              displacement: 72,
              child: CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: CollapsingScreenHeader(
                      title: _visual.title,
                      emoji: _visual.emoji,
                      gradient: _visual.gradient,
                      onBack: () => Navigator.pop(context),
                      narrow: media.size.width < 360,
                      textScale:
                          media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                    ),
                  ),
                  ProductGridView(
                    sliver: true,
                    controller: _gridController,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                    fetchPage: _fetchPage,
                    onTapItem: (item) => Navigator.pushNamed(
                      context,
                      '/product',
                      arguments: {'listingId': (item as BrokaListing).id},
                    ),
                    onViewStore: (storeId, storeSlug) => Navigator.pushNamed(
                        context, '/store-view', arguments: {'storeId': storeId}),
                    emptyStateBuilder: (_) => BrokaEmptyState(
                      emoji: _visual.emoji,
                      gradient: _visual.gradient,
                      headline: _visual.emptyHeadline,
                      body: _visual.emptyBody,
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
}
