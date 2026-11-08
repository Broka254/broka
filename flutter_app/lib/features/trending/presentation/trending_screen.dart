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
//
// Mobile-data pass (2026-11-08): kept on the phone like Home - opened from
// the saved copy, fetched again only past CachePolicies.trendingFeed - and
// asked for lean cards. A failed page is an error with a Retry now: it used
// to come back as an empty page, which read "nothing is trending" and
// ended the feed for good on one dropped connection.
import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../../core/cache/screen_cache.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../../listings/data/listing_feed_cache.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../../discovery/domain/destination_visual.dart';
import '../data/repositories/trending_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../../stores/presentation/storefront_launcher.dart';

class TrendingScreen extends StatefulWidget {
  const TrendingScreen({super.key});

  @override
  State<TrendingScreen> createState() => _TrendingScreenState();
}

class _TrendingScreenState extends State<TrendingScreen> {
  static const _visual = DestinationVisuals.trending;

  final _scrollController = ScrollController();
  final _gridController = ProductGridController();

  /// The saved feed's listings as the server sent them (ListingFeedCache).
  final Map<String, Map<String, dynamic>> _rawListings = {};

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<List<dynamic>> _fetchPage(int page) async {
    final result = await trendingRepository.getTrending(
      page: page,
      lean: true,
      onRaw: (raw) {
        for (final j in raw) {
          final id = j['id'];
          if (id is String) _rawListings[id] = j;
        }
      },
    );
    switch (result) {
      case Success(:final data):
        return data;
      case Failure(:final message):
        // ProductGridView shows a thrown error with Retry, and keeps the
        // listings already on screen.
        throw TrendingFeedFailure(message);
    }
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
                    cache: ListingFeedCache(
                      key: CacheKey.forUser(
                          CacheFeature.trendingFeed, ApiService.currentUserId),
                      raw: _rawListings,
                      policy: CachePolicies.trendingFeed,
                    ),
                    itemId: (item) => (item as BrokaListing).id,
                    onTapItem: (item) => Navigator.pushNamed(
                      context,
                      '/product',
                      arguments: {'listingId': (item as BrokaListing).id},
                    ),
                    onViewStore: (_, storeSlug) =>
                        openStoreHome(context, slug: storeSlug),
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

/// Why a page of Trending failed, for ProductGridView's retry state.
class TrendingFeedFailure implements Exception {
  const TrendingFeedFailure(this.message);
  final String message;

  @override
  String toString() => message;
}
