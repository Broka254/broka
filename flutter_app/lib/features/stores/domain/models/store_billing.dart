// BROKA — Store billing domain model
//
// Mirrors backend/api/domains/stores/billing.py: the owner's plan state that
// rides on the store payload (`billing`, null while STORE_BILLING_ENABLED is
// off), the priced quote the billing screen reads, and one M-Pesa payment's
// progress. Amounts are always the server's - the app shows them, never
// works them out.

/// A plan's price for one prepay period, opening fee included in [amount].
class StorePlanPeriod {
  final int months;
  final int total;
  final double perMonth;
  final int savingPercent;

  /// The opening fee inside [amount]: 0 once it is paid, and 0 from six
  /// months up (PRICING.md §5: waived).
  final int setupFee;
  final int amount;

  const StorePlanPeriod({
    required this.months,
    required this.total,
    required this.perMonth,
    required this.savingPercent,
    required this.setupFee,
    required this.amount,
  });

  factory StorePlanPeriod.fromJson(Map<String, dynamic> j) => StorePlanPeriod(
        months: (j['months'] as num?)?.toInt() ?? 1,
        total: (j['total'] as num?)?.toInt() ?? 0,
        perMonth: (j['per_month'] as num?)?.toDouble() ?? 0,
        savingPercent: (j['saving_percent'] as num?)?.toInt() ?? 0,
        setupFee: (j['setup_fee'] as num?)?.toInt() ?? 0,
        amount: (j['amount'] as num?)?.toInt() ?? 0,
      );
}

/// The plan a listing count is priced at (GET .../billing?listings=).
class StorePlanQuote {
  final String id;
  final String name;
  final int monthlyPrice;
  final int listings;
  final List<StorePlanPeriod> periods;

  const StorePlanQuote({
    required this.id,
    required this.name,
    required this.monthlyPrice,
    required this.listings,
    this.periods = const [],
  });

  StorePlanPeriod? period(int months) {
    for (final p in periods) {
      if (p.months == months) return p;
    }
    return null;
  }

  factory StorePlanQuote.fromJson(Map<String, dynamic> j) => StorePlanQuote(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        monthlyPrice: (j['monthly_price'] as num?)?.toInt() ?? 0,
        listings: (j['listings'] as num?)?.toInt() ?? 0,
        periods: [
          for (final p in (j['periods'] as List? ?? const []))
            StorePlanPeriod.fromJson((p as Map).cast<String, dynamic>()),
        ],
      );
}

/// The store's rate card: what it pays for however many listings it picks.
class StoreRateCard {
  final String id;
  final String name;
  final int includedListings;
  final int basePrice;

  /// Car yards and agents pay for stock, not for a name: the card's floor
  /// (5 live listings) is checked when paying. 1 for everything else.
  final int minListings;
  final int maxListings;
  final int bandUpTo;
  final int bandPrice;

  const StoreRateCard({
    required this.id,
    required this.name,
    required this.includedListings,
    required this.basePrice,
    this.minListings = 1,
    this.maxListings = 1000,
    this.bandUpTo = 0,
    this.bandPrice = 0,
  });

  factory StoreRateCard.fromJson(Map<String, dynamic> j) {
    final bands = (j['per_listing_bands'] as List? ?? const []);
    final first = bands.isEmpty ? null : (bands.first as Map).cast<String, dynamic>();
    return StoreRateCard(
      id: j['id'] as String? ?? '',
      name: j['name'] as String? ?? '',
      includedListings: (j['included_listings'] as num?)?.toInt() ?? 0,
      basePrice: (j['base_price'] as num?)?.toInt() ?? 0,
      minListings: (j['min_listings'] as num?)?.toInt() ?? 1,
      maxListings: (j['max_listings'] as num?)?.toInt() ?? 1000,
      bandUpTo: (first?['up_to'] as num?)?.toInt() ?? 0,
      bandPrice: (first?['price'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The owner's plan state, as the store payload and the quote both carry it.
class StoreBilling {
  /// Whether buyers can see the store right now: a plan paid up and, for
  /// the owner's own switch, the store open.
  final bool active;
  final String? planId;

  /// Listings the running plan covers. Null for a grace row (created when
  /// billing first switched on, before any plan was bought).
  final int? listings;
  final int? monthlyPrice;
  final DateTime? paidUntil;

  /// Whether the one-off opening fee is settled. False on grace rows: the
  /// time was free, the fee is still owed.
  final bool setupFeePaid;

  const StoreBilling({
    required this.active,
    this.planId,
    this.listings,
    this.monthlyPrice,
    this.paidUntil,
    this.setupFeePaid = false,
  });

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse('${v}Z')?.toLocal() : null;

  /// Null when the payload's `billing` is null - billing is off, and the
  /// app shows no billing surfaces at all.
  static StoreBilling? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j.cast<String, dynamic>();
    return StoreBilling(
      active: m['active'] as bool? ?? false,
      planId: m['plan_id'] as String?,
      listings: (m['listings'] as num?)?.toInt(),
      monthlyPrice: (m['monthly_price'] as num?)?.toInt(),
      paidUntil: _date(m['paid_until']),
      setupFeePaid: m['setup_fee_paid'] as bool? ?? false,
    );
  }
}

/// Everything the billing screen needs: the card, what is owed now, and -
/// when a size is asked for - that plan's priced periods.
class StoreBillingQuote {
  final StoreRateCard rateCard;
  final int setupFee;
  final int setupFeeWaivedFromMonths;
  final int minListings;
  final int liveListings;
  final StoreBilling current;
  final List<int> monthsOptions;
  final StorePlanQuote? plan;

  const StoreBillingQuote({
    required this.rateCard,
    required this.setupFee,
    this.setupFeeWaivedFromMonths = 6,
    this.minListings = 1,
    this.liveListings = 0,
    required this.current,
    this.monthsOptions = const [1, 3, 6, 12],
    this.plan,
  });

  factory StoreBillingQuote.fromJson(Map<String, dynamic> j) => StoreBillingQuote(
        rateCard: StoreRateCard.fromJson(
            (j['rate_card'] as Map).cast<String, dynamic>()),
        setupFee: (j['setup_fee'] as num?)?.toInt() ?? 0,
        setupFeeWaivedFromMonths: (j['setup_fee_waived_from_months'] as num?)?.toInt() ?? 6,
        minListings: (j['min_listings'] as num?)?.toInt() ?? 1,
        liveListings: (j['live_listings'] as num?)?.toInt() ?? 0,
        current: StoreBilling.fromJson(j['current']) ??
            const StoreBilling(active: false),
        monthsOptions: [
          for (final m in (j['months_options'] as List? ?? const []))
            if (m is num) m.toInt(),
        ],
        plan: j['plan'] == null
            ? null
            : StorePlanQuote.fromJson((j['plan'] as Map).cast<String, dynamic>()),
      );
}

/// One store plan payment's progress (POST .../billing/pay,
/// GET .../billing/payments/{id}). Also what `start` returns - the same
/// fields, minus the end.
class StorePlanPayment {
  final String id;

  /// pending | success | failed
  final String status;
  final int amount;
  final int months;
  final int listings;
  final String? planId;
  final DateTime? paidUntil;
  final String? failureReason;

  const StorePlanPayment({
    required this.id,
    required this.status,
    required this.amount,
    required this.months,
    this.listings = 0,
    this.planId,
    this.paidUntil,
    this.failureReason,
  });

  bool get pending => status == 'pending';
  bool get succeeded => status == 'success';

  factory StorePlanPayment.fromJson(Map<String, dynamic> j) => StorePlanPayment(
        id: j['payment_id'] as String? ?? '',
        status: j['status'] as String? ?? 'pending',
        amount: (j['amount'] as num?)?.toInt() ?? 0,
        months: (j['months'] as num?)?.toInt() ?? 1,
        listings: (j['listings'] as num?)?.toInt() ?? 0,
        planId: j['plan_id'] as String?,
        paidUntil: StoreBilling._date(j['paid_until']),
        failureReason: j['failure_reason'] as String?,
      );
}
