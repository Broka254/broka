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
  sold('sold', 'Sold');

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

class StoreProduct {
  const StoreProduct({
    required this.listing,
    required this.state,
    required this.json,
    this.feeStatus = 'free',
    this.needsPayment = false,
    this.paidUntil,
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
    final listing = BrokaListing.fromJson(j);
    return StoreProduct(
      listing: listing,
      state: StoreProductState.parse(j['store_state'] as String?) ??
          (listing.isActive ? StoreProductState.live : StoreProductState.inDeal),
      feeStatus: fee['status'] as String? ?? 'free',
      needsPayment: fee['needs_payment'] as bool? ?? false,
      paidUntil: parseBackendUtc(fee['paid_until'] as String?),
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
  });

  final int all;
  final int live;
  final int hidden;
  final int inDeal;
  final int sold;

  /// The count for a filter; null is "all".
  int of(StoreProductState? state) => switch (state) {
        null => all,
        StoreProductState.live => live,
        StoreProductState.hidden => hidden,
        StoreProductState.inDeal => inDeal,
        StoreProductState.sold => sold,
      };

  factory StoreProductCounts.fromJson(Map<String, dynamic> j) {
    int n(String key) => (j[key] as num?)?.toInt() ?? 0;
    return StoreProductCounts(
      all: n('all'),
      live: n('live'),
      hidden: n('hidden'),
      inDeal: n('in_deal'),
      sold: n('sold'),
    );
  }
}

class StoreProductsPage {
  const StoreProductsPage({required this.items, required this.counts});
  final List<StoreProduct> items;
  final StoreProductCounts counts;
}
