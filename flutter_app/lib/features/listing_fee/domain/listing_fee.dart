// The monthly listing fee, as the server quotes it (PRICING.md,
// GET /pricing/listing-fee/...). Every amount comes from the server; the app
// never works one out, so what the seller sees is what M-Pesa asks for.
//
// The wording helpers below turn a quote into the sentences the Listing fee
// screen shows: why this price, and how long to list. They live here, not in
// the widget, so they can be tested with plain values.

import '../../../utils/price_format.dart';
import '../../launch_offers/domain/launch_offers.dart';

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
double _double(Object? v) => (v as num?)?.toDouble() ?? 0;

/// One of the 2, 4 or 6 month choices.
class FeeOption {
  const FeeOption({
    required this.months,
    required this.total,
    required this.perMonth,
    required this.savingPercent,
    required this.recommended,
  });

  final int months;
  final int total;
  final double perMonth;
  final int savingPercent;
  final bool recommended;

  factory FeeOption.fromJson(Map<String, dynamic> j) => FeeOption(
        months: _int(j['months']),
        total: _int(j['total']),
        perMonth: _double(j['per_month']),
        savingPercent: _int(j['saving_percent']),
        recommended: j['recommended'] == true,
      );
}

/// The seller's store plan, when its places cover one of their own listings
/// or have room for it (backend stores/plan_cover.py): a shop that paid for
/// 20 listings pays no listing fee until it has 20 up.
class StorePlanCover {
  const StorePlanCover({
    required this.storeName,
    required this.places,
    required this.inUse,
    required this.free,
    required this.covered,
    this.until,
  });

  final String storeName;

  /// Listings the plan pays for, and how many of them are taken.
  final int places;
  final int inUse;
  final int free;

  /// The listing asked about is already on the plan (false: a place is
  /// free for it).
  final bool covered;

  /// When the plan's paid time ends - and with it a covered listing's.
  final DateTime? until;

  static StorePlanCover? fromJson(Object? j) {
    if (j is! Map) return null;
    final until = j['until'] as String?;
    return StorePlanCover(
      storeName: j['store_name'] as String? ?? 'your store',
      places: _int(j['places']),
      inUse: _int(j['in_use']),
      free: _int(j['free']),
      covered: j['covered'] == true,
      // Naive UTC from the server.
      until: until == null ? null : DateTime.tryParse('${until}Z')?.toLocal(),
    );
  }
}

/// Where a listing's paid time stands (listings/paid.py fee_state).
class FeeState {
  const FeeState({required this.status, required this.live, required this.paidUntil});

  /// free | unpaid | live | ending | expired
  final String status;
  final bool live;
  final DateTime? paidUntil;

  bool get unpaid => status == 'unpaid';

  /// Covered by its store's plan: live, and never a payment to offer.
  bool get isStoreCovered => status == 'store_covered';
  bool get needsPayment => status == 'unpaid' || status == 'ending' || status == 'expired';

  static FeeState? fromJson(Object? j) {
    if (j is! Map) return null;
    final until = j['paid_until'] as String?;
    return FeeState(
      status: j['status'] as String? ?? 'free',
      live: j['live'] == true,
      // Naive UTC from the server.
      paidUntil: until == null ? null : DateTime.tryParse('${until}Z')?.toLocal(),
    );
  }
}

class ListingFeeQuote {
  const ListingFeeQuote({
    required this.category,
    required this.listPrice,
    required this.monthlyFee,
    required this.discountPercent,
    required this.recordPercent,
    required this.launchPercent,
    required this.completionRate,
    required this.categoryCompletionRate,
    required this.completedDeals,
    required this.ownRecordShare,
    required this.options,
    required this.recommendedMonths,
    required this.expectedDaysToSell,
    required this.strength,
    required this.feesEnabled,
    this.discountsApply = true,
    this.listingValue = 0,
    this.pricedOn = 0,
    this.quantity = 1,
    this.multiUnitPercent = 0,
    this.monthsAvailable,
    this.state,
    this.periodMonths = 2,
    this.freeListing = false,
    this.storeCovered = false,
    this.storePlan,
    this.launchOffer,
  });

  final String category;
  final int listPrice;

  /// The fee for one period of [periodMonths] (the server's `monthly_fee`,
  /// a name kept from when it bought one month).
  final int monthlyFee;

  /// How many months one fee buys: 2 (PRICING.md); listing time is sold in
  /// 2, 4 or 6 months.
  final int periodMonths;
  final int discountPercent;
  final int recordPercent;
  final int launchPercent;
  final double completionRate;
  final double categoryCompletionRate;
  final int completedDeals;
  final double ownRecordShare;

  /// Only the months that can still be added (six ahead at most).
  final List<FeeOption> options;
  final int recommendedMonths;
  final int expectedDaysToSell;

  /// none | suggested | strong
  final String strength;

  /// False: listing is free right now and there is nothing to pay.
  final bool feesEnabled;

  /// False while BROKA handles no deal payments: the record discount and
  /// launch offer are measured in deals paid through BROKA, so neither
  /// applies, and the price is the listing's value alone.
  final bool discountsApply;

  /// Price x units, KES: what the listing offers. Not what the fee is
  /// charged on since 2026-11-20 - that is [pricedOn].
  final double listingValue;

  /// One unit's price, KES: what the fee is charged on.
  final double pricedOn;

  /// Units in the listing.
  final int quantity;

  /// What more than one unit adds to the fee, in percent (20), however
  /// many there are; 0 for a single unit.
  final int multiUnitPercent;

  /// For an existing listing: months that can still be paid for.
  final int? monthsAvailable;
  final FeeState? state;

  /// This (new) listing posts free: a free place, the founding offer, or
  /// the launch offer. The sell screen says so instead of quoting a fee.
  final bool freeListing;

  /// Posted through the seller's store - or, for a listing about to be
  /// posted, taking a place on their store plan ([storePlan]): no listing fee.
  final bool storeCovered;

  /// The seller's store plan when it covers this listing of their own, or
  /// has a place free for it; null otherwise.
  final StorePlanCover? storePlan;

  /// The launch offer as this seller stands with it, when quoted.
  final LaunchOffer? launchOffer;

  factory ListingFeeQuote.fromJson(Map<String, dynamic> j) {
    final risk = (j['risk'] as Map?)?.cast<String, dynamic>() ?? const {};
    final discounts = (j['discounts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rec = (j['recommendation'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ListingFeeQuote(
      category: j['category'] as String? ?? '',
      listPrice: _int(j['list_price']),
      monthlyFee: _int(j['period_fee'] ?? j['monthly_fee']),
      periodMonths: j['period_months'] == null ? 1 : _int(j['period_months']),
      discountPercent: _int(j['discount_percent']),
      recordPercent: _int(discounts['record_percent']),
      launchPercent: _int(discounts['launch_percent']),
      completionRate: _double(risk['completion_rate']),
      categoryCompletionRate: _double(risk['category_completion_rate']),
      completedDeals: _int(risk['completed_deals']),
      ownRecordShare: _double(risk['own_record_share']),
      options: [
        for (final o in (j['options'] as List? ?? const []))
          FeeOption.fromJson((o as Map).cast<String, dynamic>()),
      ],
      recommendedMonths: _int(rec['months']),
      expectedDaysToSell: _int(rec['expected_days_to_sell']),
      strength: rec['strength'] as String? ?? 'none',
      feesEnabled: j['fees_enabled'] != false,
      // Absent from older servers, which always applied the discounts.
      discountsApply: discounts['apply'] != false,
      listingValue: _double(j['listing_value']),
      // Older servers sent no priced_on: they charged price x units.
      pricedOn: _double(j['priced_on']),
      quantity: j['quantity'] == null ? 1 : _int(j['quantity']),
      multiUnitPercent: _int(j['multi_unit_percent']),
      monthsAvailable: j['months_available'] == null ? null : _int(j['months_available']),
      state: FeeState.fromJson(j['listing_fee']),
      freeListing: j['free_listing'] == true,
      storeCovered: j['store_covered'] == true,
      storePlan: StorePlanCover.fromJson(j['store_plan']),
      launchOffer: j['launch_offer'] is Map
          ? LaunchOffer.fromQuoteJson((j['launch_offer'] as Map).cast<String, dynamic>())
          : null,
    );
  }

  FeeOption? option(int months) {
    for (final o in options) {
      if (o.months == months) return o;
    }
    return null;
  }

  /// The choice to start on: the recommended months if they can still be
  /// bought, else the longest that can.
  int get defaultMonths {
    if (option(recommendedMonths) != null) return recommendedMonths;
    return options.isEmpty ? 0 : options.last.months;
  }

  /// Whether the price rests on the seller's own deals or, for someone new,
  /// on their category's.
  bool get pricedOnOwnRecord => completedDeals > 0 && ownRecordShare >= 0.5;
}

/// A free renewal while listing fees are off
/// (POST /pricing/listing-fee/renew-free): one more launch window, no money.
class RenewFreeResult {
  const RenewFreeResult({
    required this.listingId,
    this.paidUntil,
    this.state,
    this.timeLeft,
  });

  final String listingId;
  final DateTime? paidUntil;
  final FeeState? state;
  final TimeLeft? timeLeft;

  factory RenewFreeResult.fromJson(Map<String, dynamic> j) {
    final until = j['paid_until'] as String?;
    return RenewFreeResult(
      listingId: j['listing_id'] as String? ?? '',
      paidUntil: until == null ? null : DateTime.tryParse('${until}Z')?.toLocal(),
      state: FeeState.fromJson(j['listing_fee']),
      timeLeft: TimeLeft.fromPayload(j),
    );
  }
}

/// A payment's progress (GET /pricing/listing-fee/payments/{id}).
class ListingFeePayment {
  const ListingFeePayment({
    required this.id,
    required this.status,
    required this.amount,
    required this.months,
    this.failureReason,
    this.paidUntil,
    this.state,
  });

  final String id;

  /// pending | success | failed
  final String status;
  final int amount;
  final int months;
  final String? failureReason;
  final DateTime? paidUntil;
  final FeeState? state;

  bool get pending => status == 'pending';
  bool get succeeded => status == 'success';

  factory ListingFeePayment.fromJson(Map<String, dynamic> j) {
    final until = j['paid_until'] as String?;
    return ListingFeePayment(
      id: j['payment_id'] as String? ?? '',
      status: j['status'] as String? ?? 'pending',
      amount: _int(j['amount']),
      months: _int(j['months']),
      failureReason: j['failure_reason'] as String?,
      paidUntil: until == null ? null : DateTime.tryParse('${until}Z')?.toLocal(),
      state: FeeState.fromJson(j['listing_fee']),
    );
  }
}

/// One of the seller's listings waiting for payment or renewal.
class ListingAwaitingFee {
  const ListingAwaitingFee({
    required this.id,
    required this.name,
    required this.price,
    required this.state,
    this.coverThumb,
    this.timeLeft,
  });

  final String id;
  final String name;
  final double price;
  final FeeState state;
  final String? coverThumb;

  /// Server-computed countdown before it goes offline, when present.
  final TimeLeft? timeLeft;

  factory ListingAwaitingFee.fromJson(Map<String, dynamic> j) => ListingAwaitingFee(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        price: _double(j['price']),
        state: FeeState.fromJson(j['listing_fee']) ??
            const FeeState(status: 'unpaid', live: false, paidUntil: null),
        coverThumb: (j['cover'] as Map?)?['thumb'] as String?,
        timeLeft: TimeLeft.fromPayload(j),
      );
}

// ── Wording ──────────────────────────────────────────────────────────────────

String _pct(double rate) => '${(rate * 100).round()}%';

/// What the fee is charged on (2026-11-20): one unit's price, and a flat
/// share more for a listing of several - the same for 2 units or 200. Null
/// from a server that sends no priced_on (it charged price x units).
String? pricedOnText(ListingFeeQuote q) {
  if (q.pricedOn <= 0) return null;
  if (q.quantity > 1 && q.multiUnitPercent > 0) {
    return 'Priced on one unit: ${formatKes(q.pricedOn)}, plus ${q.multiUnitPercent}% '
        'because you\'re listing ${q.quantity} - the same however many you list.';
  }
  return 'Priced on the item\'s price: ${formatKes(q.pricedOn)}.';
}

/// Why the price is what it is - one line per discount.
List<String> feeReasons(ListingFeeQuote q) {
  final lines = <String>[];
  final pricedOn = pricedOnText(q);
  if (!q.discountsApply) {
    if (pricedOn != null) {
      lines.add(pricedOn);
    } else if (q.listingValue > 0) {
      lines.add('Priced on what you\'re listing: ${formatKes(q.listingValue)} (price \u00d7 units).');
    }
    lines.add('The rate falls as the price rises, so dearer items pay a smaller share.');
    // The founding-seller offer travels in the launch discount's place.
    if (q.launchPercent > 0) {
      lines.add('Founding seller: ${q.launchPercent}% off your first listing.');
    }
    return lines;
  }
  if (q.pricedOnOwnRecord) {
    lines.add('${_pct(q.completionRate)} of your deals complete through BROKA'
        '${q.recordPercent > 0 ? ' - ${q.recordPercent}% off' : ''}.');
  } else {
    lines.add('New sellers start at the ${q.category} average: '
        '${_pct(q.categoryCompletionRate)} of deals there complete through BROKA'
        '${q.recordPercent > 0 ? ' - ${q.recordPercent}% off' : ''}.');
  }
  if (q.launchPercent > 0) {
    lines.add('Launch offer: ${q.launchPercent}% off while ${q.category} gets going on BROKA.');
  }
  lines.add('The more of your deals complete through BROKA, the less you pay.');
  // Several units cost more whatever the record: said too, or a seller of
  // ten would wonder why their price is above the category's.
  if (pricedOn != null && q.multiUnitPercent > 0 && q.quantity > 1) lines.add(pricedOn);
  return lines;
}

/// "2 months", or "a month" for a server still selling single months.
String periodLabel(int months) => months <= 1 ? 'a month' : '$months months';

/// "about 3 weeks", "about 4 months".
String roughDuration(int days) {
  if (days < 10) return 'about a week';
  if (days < 45) return 'about ${(days / 7).round()} weeks';
  return 'about ${(days / 30).round()} months';
}

/// The recommendation, or null when the shortest period is enough.
///
/// The saving is against renewing the shortest period over and over, never
/// "a month": a fee paid once for two months, quoted per month, read as a
/// monthly charge (2026-11-20).
String? recommendationText(ListingFeeQuote q) {
  if (q.strength == 'none' || q.recommendedMonths <= q.periodMonths) return null;
  final option = q.option(q.recommendedMonths);
  final every = q.periodMonths <= 1 ? 'every month' : 'every ${q.periodMonths} months';
  final saving = option != null && option.savingPercent > 0
      ? ', and costs ${option.savingPercent}% less than renewing $every'
      : '';
  return '${q.category} listings like this usually take ${roughDuration(q.expectedDaysToSell)} '
      'to find a buyer on BROKA. ${q.recommendedMonths} months keeps you in front of buyers '
      'that long$saving.';
}
