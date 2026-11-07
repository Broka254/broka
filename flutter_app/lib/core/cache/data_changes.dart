// DataChanges - one place that knows when something the app has cached was
// changed, and tells the screens that show it.
//
// Every successful change the app makes goes through the network layer
// (InstrumentedClient), which hands the method, path and status here. A 2xx
// to a path that changes listings, the account, a store or a deal marks
// only the cache features that show that kind of data out of date
// (ScreenCache.invalidate) and bumps that domain's revision, which screens
// listen to. A refused change (4xx/5xx) changes nothing: the UI must never
// look updated by a change the backend turned down.
//
// Deliberately coarse and path-based. Matching at the network layer catches
// every screen that changes a listing - the product page, the dashboard,
// the publish queue, the store manager - without each of them having to
// remember to call anything, and a rule that fires too often costs one
// background refresh, while one that never fires leaves data stale only
// until its freshness time runs out.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'screen_cache.dart';

enum DataDomain { listings, account, store, deals }

class DataChange {
  const DataChange(this.domain, {this.method = '', this.path = '', this.listingId});
  final DataDomain domain;
  final String method;
  final String path;

  /// Set when one listing was changed or deleted (PATCH/DELETE /listings/{id}).
  final String? listingId;

  bool get isDelete => method.toUpperCase() == 'DELETE';

  @override
  String toString() => 'DataChange($domain, $method $path)';
}

class DataChanges {
  DataChanges._();
  static final DataChanges instance = DataChanges._();

  final Map<DataDomain, ValueNotifier<int>> _revisions = {
    for (final d in DataDomain.values) d: ValueNotifier<int>(0),
  };
  final StreamController<DataChange> _events = StreamController<DataChange>.broadcast();

  /// Bumped once per change in [domain]. A screen compares the value it
  /// loaded at with the current one to know whether to reload on return.
  ValueListenable<int> revision(DataDomain domain) => _revisions[domain]!;

  Stream<DataChange> get events => _events.stream;

  /// What each domain's changes make out of date.
  static const Map<DataDomain, List<CacheFeature>> features = {
    DataDomain.listings: [
      CacheFeature.homeFeed, CacheFeature.menuListingCount, CacheFeature.dashboardListings,
      CacheFeature.dashboardSummary, CacheFeature.storeSummary, CacheFeature.launchOffers,
    ],
    DataDomain.account: [CacheFeature.menuAccount, CacheFeature.dashboardProfile],
    DataDomain.store: [
      CacheFeature.storeSummary, CacheFeature.storeStats, CacheFeature.launchOffers,
      CacheFeature.dashboardSummary,
    ],
    DataDomain.deals: [
      CacheFeature.dashboardRevenue, CacheFeature.dashboardMetrics, CacheFeature.dashboardSummary,
      CacheFeature.dashboardProfile, CacheFeature.dashboardListings, CacheFeature.menuAccount,
    ],
  };

  void notify(DataDomain domain, {String method = '', String path = '', String? listingId}) {
    ScreenCache.instance.invalidate(features[domain]!);
    _revisions[domain]!.value++;
    _events.add(DataChange(domain, method: method, path: path, listingId: listingId));
  }

  /// Called by the network layer for every response.
  void observeResponse(String method, Uri url, int status) {
    final m = method.toUpperCase();
    if (m == 'GET' || m == 'HEAD' || m == 'OPTIONS') return;
    if (status < 200 || status >= 300) return;
    final domains = classify(m, url.path);
    if (domains.isEmpty) return;
    final id = listingIdOf(url.path);
    for (final d in domains) {
      notify(d, method: m, path: url.path, listingId: d == DataDomain.listings ? id : null);
    }
  }

  static List<String> _segments(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  /// The listing a PATCH/DELETE /listings/{id} was about.
  static String? listingIdOf(String path) {
    final s = _segments(path);
    if (s.length == 2 && s[0] == 'listings') return s[1];
    return null;
  }

  // Buyer actions on someone else's listing: they change nothing any cached
  // screen shows (the saved list is not cached).
  static const _listingReadActions = {
    'like', 'save', 'interest', 'view', 'views', 'report', 'share', 'engagement',
    'metrics', 'contact', 'impression', 'impressions',
  };

  // Sign-in plumbing, not a change to the account the Menu shows.
  static const _authPlumbing = {
    'login', 'register', 'token', 'heartbeat', 'location', 'otp', 'logout',
    'password', 'refresh', 'push-token', 'devices', 'biometric-login', 'forgot-password',
    'reset-password',
  };

  /// Which domains a successful [method] to [path] changed.
  static Set<DataDomain> classify(String method, String path) {
    final s = _segments(path);
    if (s.isEmpty) return const {};
    switch (s[0]) {
      case 'listings':
        if (s.length >= 3 && _listingReadActions.contains(s[2])) return const {};
        if (s.length >= 3 && s[2] == 'store') return const {DataDomain.listings, DataDomain.store};
        return const {DataDomain.listings};
      case 'featured':
      case 'boost':
        return const {DataDomain.listings};
      case 'pricing':
        // Paying a listing fee, a store plan or Premium: each changes what a
        // different screen shows, and these are rare enough to refresh all.
        return const {DataDomain.listings, DataDomain.store, DataDomain.account};
      case 'stores':
        if (s.length >= 2 && s[1] == 'email') return const {};
        if (s.length >= 3 && const {'visit', 'share', 'follow', 'marketing'}.contains(s[2])) {
          return const {};
        }
        return const {DataDomain.store, DataDomain.listings};
      case 'auth':
        if (s.length >= 2 && _authPlumbing.contains(s[1])) return const {};
        if (s.length >= 2 && s[1] == 'email' && !s.contains('verify')) return const {};
        return const {DataDomain.account};
      case 'traders':
      case 'users':
        return s.length >= 2 && s[1] == 'me' ? const {DataDomain.account} : const {};
      case 'premium':
        return s.length >= 2 && s[1] == 'insights' ? const {} : const {DataDomain.account};
      case 'verify':
        return const {DataDomain.account};
      case 'deal':
      case 'escrow':
      case 'mpesa':
      case 'disputes':
        return const {DataDomain.deals};
      default:
        return const {};
    }
  }
}
