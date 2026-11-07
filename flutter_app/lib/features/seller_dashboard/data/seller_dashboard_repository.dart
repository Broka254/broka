// The Seller Dashboard's data, with a copy of each part kept on the phone.
//
// Opening the dashboard used to download the seller profile and up to 200
// listings, then revenue twice over and 90 days of metrics, every time -
// and the launch offers twice. Now:
//   * the totals come from GET /listings/seller/{id}/summary, one small
//     response, and the listings arrive a page at a time (pageSize) as the
//     Products tab scrolls - all of them only when the Deals tab needs every
//     listing's deal;
//   * profile, the first page, the totals, revenue and metrics are each
//     saved (ScreenCache) and shown at once on the next open, offline
//     included, and refetched only when out of date - past their
//     CachePolicies time, or changed in the app (DataChanges);
//   * deal and boost statuses are never saved: they say whether money is in
//     escrow, and an old answer must not read as a current one.
import '../../../core/cache/screen_cache.dart';
import '../../../services/api_service.dart';

class SavedDashboard {
  const SavedDashboard({
    this.profile,
    this.listings,
    this.listingsHaveMore = true,
    this.summary,
    this.revenue,
    this.metrics,
  });

  final CacheEntry? profile;

  /// The first page, as saved.
  final CacheEntry? listings;
  final bool listingsHaveMore;
  final CacheEntry? summary;
  final CacheEntry? revenue;
  final CacheEntry? metrics;

  bool get isEmpty => profile == null && listings == null;

  /// Profile, first page and totals all saved and current: nothing to ask.
  bool get coreFresh =>
      (profile?.isFresh ?? false) && (listings?.isFresh ?? false) && (summary?.isFresh ?? false);

  /// The oldest of the parts shown, for "saved N min ago".
  DateTime? get oldest {
    final times = [profile?.fetchedAt, listings?.fetchedAt].whereType<DateTime>().toList()..sort();
    return times.isEmpty ? null : times.first;
  }
}

class SellerDashboardRepository {
  const SellerDashboardRepository();

  static const pageSize = 20;

  /// The most the Deals tab loads to find every deal - the ceiling the
  /// dashboard always had.
  static const maxListings = 200;

  CacheKey _key(CacheFeature f, String uid) => CacheKey.forUser(f, uid);

  ScreenCache get _cache => ScreenCache.instance;

  Future<SavedDashboard> saved(String uid) async {
    final profile = await _cache.read(_key(CacheFeature.dashboardProfile, uid), CachePolicies.dashboardProfile);
    final listings = await _cache.read(_key(CacheFeature.dashboardListings, uid), CachePolicies.dashboardListings);
    final summary = await _cache.read(_key(CacheFeature.dashboardSummary, uid), CachePolicies.dashboardSummary);
    final revenue = await _cache.read(_key(CacheFeature.dashboardRevenue, uid), CachePolicies.dashboardRevenue);
    final metrics = await _cache.read(_key(CacheFeature.dashboardMetrics, uid), CachePolicies.dashboardMetrics);
    final data = listings?.data;
    return SavedDashboard(
      profile: profile?.data is Map ? profile : null,
      listings: data is Map && data['items'] is List ? listings : null,
      listingsHaveMore: data is Map ? data['has_more'] as bool? ?? true : true,
      summary: summary?.data is Map ? summary : null,
      revenue: revenue?.data is Map ? revenue : null,
      metrics: metrics?.data is Map ? metrics : null,
    );
  }

  static List<Map<String, dynamic>> savedItems(CacheEntry entry) {
    final data = entry.data as Map;
    return [
      for (final j in data['items'] as List)
        if (j is Map) Map<String, dynamic>.from(j),
    ];
  }

  Future<Map<String, dynamic>> profile(String uid) async {
    final data = await _cache.fetch(_key(CacheFeature.dashboardProfile, uid), () async {
      final p = await ApiService.getUserProfile(uid);
      // An error body is not a profile, and must not be saved as one.
      if (p['id'] == null && p['detail'] != null) throw StateError('profile unavailable');
      return p;
    }, persist: (d) => d is Map<String, dynamic> ? stripLargeInlineMedia(d) : d);
    return Map<String, dynamic>.from(data as Map);
  }

  /// One page of the seller's listings, from [offset]. The first page is
  /// saved; later ones are fetched as they are scrolled to.
  Future<List<Map<String, dynamic>>> listings(String uid, {int offset = 0}) async {
    if (offset != 0) {
      return ApiService.getSellerListingMaps(uid, limit: pageSize, offset: offset);
    }
    final data = await _cache.fetch(_key(CacheFeature.dashboardListings, uid), () async {
      final items = await ApiService.getSellerListingMaps(uid, limit: pageSize);
      return {'items': items, 'has_more': items.length >= pageSize};
    }, persist: (d) => d is Map
        ? {
            'items': [for (final j in d['items'] as List) stripInlineMedia(j as Map<String, dynamic>)],
            'has_more': d['has_more'],
          }
        : d);
    return [for (final j in (data as Map)['items'] as List) Map<String, dynamic>.from(j as Map)];
  }

  /// The server's totals, or null where it has none (see
  /// ApiService.getSellerSummary). A null is not saved.
  Future<Map<String, dynamic>?> summary(String uid) async {
    try {
      final data = await _cache.fetch(_key(CacheFeature.dashboardSummary, uid), () async {
        final s = await ApiService.getSellerSummary(uid);
        if (s == null) throw StateError('no summary');
        return s;
      });
      return Map<String, dynamic>.from(data as Map);
    } catch (_) {
      return null;
    }
  }

  /// This week's and this month's paid-out revenue, together.
  Future<Map<String, dynamic>> revenue(String uid) async {
    final data = await _cache.fetch(_key(CacheFeature.dashboardRevenue, uid), () async {
      final week = await ApiService.getSellerRevenue(uid, period: 'week');
      final month = await ApiService.getSellerRevenue(uid, period: 'month');
      return {'week': week, 'month': month};
    });
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> metrics(String uid) async {
    final data = await _cache.fetch(
        _key(CacheFeature.dashboardMetrics, uid), () => ApiService.getSellerMetrics(uid, days: 90));
    return Map<String, dynamic>.from(data as Map);
  }
}
