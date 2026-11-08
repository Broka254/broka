// Home's feed, kept on the phone (a ProductGridCache over ScreenCache).
//
// One entry per account and set of filters: the first [maxItems] listings
// shown, as the server sent them minus their inline base64 media
// (stripInlineMedia), with how many pages they make up. Reopening Home -
// after the app was closed, after "back to Home" following a long absence,
// or offline - shows these at once; ProductGridView refreshes them in the
// background only once they are past CachePolicies.homeFeed.
//
// The Category Zones, the type-of-item screens and Trending keep their
// feeds the same way, each under its own key and policy (2026-11-08): they
// were the screens people browse most after Home, and every visit fetched
// page 0 again.
import 'package:flutter/foundation.dart';

import '../../../core/cache/screen_cache.dart';
import '../../../widgets/product_grid_view.dart';
import '../domain/models/listing.dart';

class ListingFeedCache implements ProductGridCache {
  ListingFeedCache({
    required this.key,
    required this.raw,
    this.policy = CachePolicies.homeFeed,
    this.pageSize = 20,
    this.maxItems = 60,
    this.total,
  });

  /// The feed's result count ("128 listings"), for a screen that shows one:
  /// saved with the items and handed back by [read], so a saved feed opens
  /// with its count rather than a blank. The screen sets it from each
  /// page's answer.
  final ValueNotifier<int?>? total;

  final CacheKey key;

  /// id -> the listing's JSON as fetched. Filled by the caller's fetch
  /// (ListingsRepository.getListings' onRaw) and by [read].
  final Map<String, Map<String, dynamic>> raw;
  final CachePolicy policy;
  final int pageSize;

  /// Three pages. Enough to come back to where most people stop scrolling;
  /// past that a refetch is cheaper than keeping everything.
  final int maxItems;

  @override
  Future<ProductGridSnapshot?> read() async {
    final entry = await ScreenCache.instance.read(key, policy);
    final data = entry?.data;
    if (entry == null || data is! Map) return null;
    final list = data['items'];
    if (list is! List) return null;
    final items = <BrokaListing>[];
    for (final j in list) {
      if (j is! Map) continue;
      try {
        final json = Map<String, dynamic>.from(j);
        final l = BrokaListing.fromJson(json);
        raw[l.id] = json;
        items.add(l);
      } catch (_) {
        // One entry the current model cannot read (an older shape) is
        // skipped, not the whole copy.
      }
    }
    if (items.isEmpty) return null;
    final savedTotal = data['total'];
    if (total != null && savedTotal is num) total!.value = savedTotal.toInt();
    return ProductGridSnapshot(
      items: items,
      page: (data['page'] as num?)?.toInt() ?? (items.length / pageSize).ceil(),
      hasMore: data['has_more'] as bool? ?? true,
      fetchedAt: entry.fetchedAt,
      fresh: entry.isFresh,
    );
  }

  @override
  Future<void> write(List<dynamic> items,
      {required int page, required bool hasMore, required DateTime fetchedAt}) async {
    final trimmed = items.length > maxItems;
    final kept = <Map<String, dynamic>>[];
    for (final i in items.take(maxItems)) {
      if (i is! BrokaListing) continue;
      final json = raw[i.id];
      if (json != null) kept.add(stripInlineMedia(json));
    }
    if (kept.isEmpty) {
      await ScreenCache.instance.remove(key);
      return;
    }
    await ScreenCache.instance.write(
      key,
      {
        'items': kept,
        'page': trimmed ? maxItems ~/ pageSize : page,
        'has_more': trimmed ? true : hasMore,
        if (total?.value != null) 'total': total!.value,
      },
      fetchedAt: fetchedAt,
    );
  }
}
