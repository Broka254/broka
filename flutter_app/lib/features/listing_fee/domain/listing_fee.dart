// The monthly listing fee, as the server quotes it (PRICING.md,
// GET /pricing/listing-fee/...). Every amount comes from the server; the app
// never works one out, so what the seller sees is what M-Pesa asks for.
//
// The wording helpers below turn a quote into the sentences the Listing fee
// screen shows: why this price, and how long to list. They live here, not in
// the widget, so they can be tested with plain values.

import '../../../utils/price_format.dart';

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
double _double(Object? v) => (v as num?)?.toDouble() ?? 0;

/// One of the 1-6 month choices.
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

/// Featured placement, offered with the fee to short-term sellers.
class FeaturedPlan {
  const FeaturedPlan({required this.id, required this.label, required this.days, required this.price});

  final String id;
  final String label;
  final int days;
  final int price;

  factory FeaturedPlan.fromJson(Map<String, dynamic> j) => FeaturedPlan(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? '',
        days: _int(j['days']),
        price: _int(j['price']),
      );
}

/// Where a listing's paid time stands (listings/paid.py fee_state).
class FeeState {
  const FeeState({required this.status, required this.live, required this.paidUntil});

  /// free | unpaid | live | ending | expired
  final String status;
  final bool live;
  final DateTime? paidUntil;

  bool get unpaid => status == 'unpaid';
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
    required this.featuredAvailable,
    required this.featuredPlans,
    required this.feesEnabled,
    this.discountsApply = true,
    this.listingValue = 0,
    this.monthsAvailable,
    this.state,
  });

  final String category;
  final int listPrice;
  final int monthlyFee;
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
  final bool featuredAvailable;
  final List<FeaturedPlan> featuredPlans;

  /// False: listing is free right now and there is nothing to pay.
  final bool feesEnabled;

  /// False while BROKA handles no deal payments: the record discount and
  /// launch offer are measured in deals paid through BROKA, so neither
  /// applies, and the price is the listing's value alone.
  final bool discountsApply;

  /// Price x units, KES - what the fee is charged on.
  final double listingValue;

  /// For an existing listing: months that can still be paid for.
  final int? monthsAvailable;
  final FeeState? state;

  factory ListingFeeQuote.fromJson(Map<String, dynamic> j) {
    final risk = (j['risk'] as Map?)?.cast<String, dynamic>() ?? const {};
    final discounts = (j['discounts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rec = (j['recommendation'] as Map?)?.cast<String, dynamic>() ?? const {};
    final featured = (j['featured'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ListingFeeQuote(
      category: j['category'] as String? ?? '',
      listPrice: _int(j['list_price']),
      monthlyFee: _int(j['monthly_fee']),
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
      featuredAvailable: featured['available'] == true,
      featuredPlans: [
        for (final p in (featured['plans'] as List? ?? const []))
          FeaturedPlan.fromJson((p as Map).cast<String, dynamic>()),
      ],
      feesEnabled: j['fees_enabled'] != false,
      // Absent from older servers, which always applied the discounts.
      discountsApply: discounts['apply'] != false,
      listingValue: _double(j['listing_value']),
      monthsAvailable: j['months_available'] == null ? null : _int(j['months_available']),
      state: FeeState.fromJson(j['listing_fee']),
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
  });

  final String id;
  final String name;
  final double price;
  final FeeState state;
  final String? coverThumb;

  factory ListingAwaitingFee.fromJson(Map<String, dynamic> j) => ListingAwaitingFee(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        price: _double(j['price']),
        state: FeeState.fromJson(j['listing_fee']) ??
            const FeeState(status: 'unpaid', live: false, paidUntil: null),
        coverThumb: (j['cover'] as Map?)?['thumb'] as String?,
      );
}

// ── Wording ──────────────────────────────────────────────────────────────────

String _pct(double rate) => '${(rate * 100).round()}%';

/// Why the price is what it is - one line per discount.
List<String> feeReasons(ListingFeeQuote q) {
  final lines = <String>[];
  if (!q.discountsApply) {
    if (q.listingValue > 0) {
      lines.add('Priced on what you\'re listing: ${formatKes(q.listingValue)} (price \u00d7 units).');
    }
    lines.add('The rate falls as the value rises, so bigger listings pay a smaller share.');
    // The founding-seller offer travels in the launch discount's place.
    if (q.launchPercent > 0) {
      lines.add('Founding seller: ${q.launchPercent}% off for your first months on BROKA.');
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
  return lines;
}

/// "about 3 weeks", "about 4 months".
String roughDuration(int days) {
  if (days < 10) return 'about a week';
  if (days < 45) return 'about ${(days / 7).round()} weeks';
  return 'about ${(days / 30).round()} months';
}

/// The recommendation, or null when one month is enough.
String? recommendationText(ListingFeeQuote q) {
  if (q.strength == 'none' || q.recommendedMonths <= 1) return null;
  final option = q.option(q.recommendedMonths);
  final saving = option != null && option.savingPercent > 0
      ? ', and costs ${option.savingPercent}% less a month than renewing'
      : '';
  return '${q.category} listings like this usually take ${roughDuration(q.expectedDaysToSell)} '
      'to find a buyer on BROKA. ${q.recommendedMonths} months keeps you in front of buyers '
      'that long$saving.';
}
