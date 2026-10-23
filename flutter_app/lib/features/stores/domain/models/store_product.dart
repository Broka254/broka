// A product in the owner's own store, as My Store manages it
// (GET /stores/{id}/manage/listings): the listing, whether buyers can see
// it, and where its listing fee stands.
import '../../../../utils/backend_time.dart';
import '../../../listings/domain/models/listing.dart';

/// Where a store product stands, as its owner sees it.
enum StoreProductState {
  /// Buyers can see it.
  live('live', 'Live'),

  /// Active, but its listing fee is unpaid or ran out: buyers can't see it.
  hidden('hidden', 'Hidden'),

  /// A buyer agreed a deal on it.
  inDeal('in_deal', 'In a deal'),

  /// The deal completed.
  sold('sold', 'Sold'),

  /// The seller took it off sale (status cancelled). The row survives so
  /// deals, reviews and history keep pointing at it.
  archived('archived', 'Archived');

  const StoreProductState(this.value, this.label);

  /// The backend's name for it.
  final String value;
  final String label;

  static StoreProductState? parse(String? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// One thing about a product its owner can fix, as the server reports it
/// in `health.issues` (StoreService._product_health). [fix] names the editor
/// that fixes it; [code] is stable for tests.
class StoreProductIssue {
  const StoreProductIssue({
    required this.code,
    required this.label,
    required this.fix,
  });

  final String code;
  final String label;
  final String fix;

  factory StoreProductIssue.fromJson(Map<String, dynamic> j) => StoreProductIssue(
        code: j['code'] as String? ?? '',
        label: j['label'] as String? ?? '',
        fix: j['fix'] as String? ?? '',
      );
}

class StoreProduct {
  const StoreProduct({
    required this.listing,
    required this.state,
    required this.json,
    this.feeStatus = 'free',
    this.needsPayment = false,
    this.paidUntil,
    this.issues = const [],
  });

  final BrokaListing listing;
  final StoreProductState state;

  /// The listing fee: free | unpaid | live | ending | expired
  /// (api/domains/listings/paid.py, fee_state).
  final String feeStatus;

  /// Unpaid, expired, or ending soon: "Pay" or "Renew" applies.
  final bool needsPayment;

  /// When its paid listing time ends, in UTC.
  final DateTime? paidUntil;

  /// What the server's own checks say the product is missing. Empty means
  /// it passes every check BROKA applies; it is never a quality score.
  final List<StoreProductIssue> issues;

  bool get needsAttention => issues.isNotEmpty;

  /// The issues worth showing beside the state. "archived" only restates
  /// the pill, and an archived product is no longer for sale anyway.
  List<StoreProductIssue> get actionableIssues =>
      issues.where((i) => i.code != 'archived').toList(growable: false);

  /// The row as the API sent it, for screens that read the older Listing
  /// model (the listing insights screen).
  final Map<String, dynamic> json;

  String get id => listing.id;

  /// Paid, but the paid time ends soon.
  bool get endingSoon => state == StoreProductState.live && feeStatus == 'ending';

  /// Its price can still change: not while a buyer's deal stands on it,
  /// and not once it's sold (the server refuses both anyway).
  bool get priceEditable =>
      state == StoreProductState.live || state == StoreProductState.hidden;

  factory StoreProduct.fromJson(Map<String, dynamic> j) {
    final fee = (j['listing_fee'] as Map?)?.cast<String, dynamic>() ?? const {};
    final health = (j['health'] as Map?)?.cast<String, dynamic>() ?? const {};
    final listing = BrokaListing.fromJson(j);
    return StoreProduct(
      listing: listing,
      // An unknown state is never presented as live: claiming buyers can
      // see a product they cannot is the one wrong answer here.
      state: StoreProductState.parse(j['store_state'] as String?) ??
          (listing.status == 'cancelled'
              ? StoreProductState.archived
              : listing.isActive
                  ? StoreProductState.live
                  : StoreProductState.hidden),
      feeStatus: fee['status'] as String? ?? 'free',
      needsPayment: fee['needs_payment'] as bool? ?? false,
      paidUntil: parseBackendUtc(fee['paid_until'] as String?),
      issues: [
        for (final raw in (health['issues'] as List?) ?? const [])
          if (raw is Map)
            StoreProductIssue.fromJson(raw.cast<String, dynamic>()),
      ],
      json: j,
    );
  }
}

/// How many of the store's products are in each state.
class StoreProductCounts {
  const StoreProductCounts({
    this.all = 0,
    this.live = 0,
    this.hidden = 0,
    this.inDeal = 0,
    this.sold = 0,
    this.archived = 0,
  });

  final int all;
  final int live;
  final int hidden;
  final int inDeal;
  final int sold;
  final int archived;

  /// The count for a filter; null is "all".
  int of(StoreProductState? state) => switch (state) {
        null => all,
        StoreProductState.live => live,
        StoreProductState.hidden => hidden,
        StoreProductState.inDeal => inDeal,
        StoreProductState.sold => sold,
        StoreProductState.archived => archived,
      };

  factory StoreProductCounts.fromJson(Map<String, dynamic> j) {
    int n(String key) => (j[key] as num?)?.toInt() ?? 0;
    return StoreProductCounts(
      all: n('all'),
      live: n('live'),
      hidden: n('hidden'),
      inDeal: n('in_deal'),
      sold: n('sold'),
      archived: n('archived'),
    );
  }
}

class StoreProductsPage {
  const StoreProductsPage({required this.items, required this.counts});
  final List<StoreProduct> items;
  final StoreProductCounts counts;
}
