// BROKA Premium, as the server describes it (PRICING.md section 4):
// the plans (GET /pricing/plans) and where the signed-in user stands
// (GET /premium/me). Every number is the server's.

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
double _double(Object? v) => (v as num?)?.toDouble() ?? 0;

/// The counted allowances, as the server names them.
class PremiumFeature {
  PremiumFeature._();
  static const voice = 'voice_requests';
  static const sms = 'sms_alerts';
  static const watches = 'agent_watches';
  static const negotiations = 'auto_negotiations';
  static const aiCovers = 'ai_covers';
  static const auctions = 'auctions_hosted';
  static const aiDescriptions = 'ai_descriptions';
  static const priceChecks = 'price_checks';

  /// In the order a plan card lists them: what helps a listing sell first.
  static const all = [aiDescriptions, aiCovers, priceChecks, voice, sms, watches, negotiations, auctions];

  /// "20 AI cover tries", "90 voice requests to Zeno"...
  static String describe(String feature, int n) => switch (feature) {
        aiCovers => '$n AI cover tries',
        voice => '$n voice requests to Zeno',
        sms => '$n texts from Zeno',
        watches => n == 1 ? '1 Buying Agent watch' : '$n Buying Agent watches',
        negotiations => '$n negotiations by Zeno',
        auctions => n == 1 ? '1 auction to host' : '$n auctions to host',
        aiDescriptions => '$n descriptions written by Zeno from your photos',
        priceChecks => '$n price checks against similar BROKA listings',
        _ => '$n $feature',
      };

  static String title(String feature) => switch (feature) {
        aiCovers => 'AI covers',
        voice => 'Voice mode',
        sms => 'Texts from Zeno',
        watches => 'Buying Agent watches',
        negotiations => 'Zeno negotiating for you',
        auctions => 'Auctions',
        aiDescriptions => 'Descriptions by Zeno',
        priceChecks => 'Price checks',
        _ => feature,
      };
}

class PlanPeriod {
  const PlanPeriod({required this.months, required this.total, required this.perMonth, required this.savingPercent});
  final int months;
  final int total;
  final double perMonth;
  final int savingPercent;

  factory PlanPeriod.fromJson(Map<String, dynamic> j) => PlanPeriod(
        months: _int(j['months']),
        total: _int(j['total']),
        perMonth: _double(j['per_month']),
        savingPercent: _int(j['saving_percent']),
      );
}

class PremiumPlan {
  const PremiumPlan({
    required this.id,
    required this.name,
    required this.pitch,
    required this.monthlyPrice,
    required this.periods,
    required this.allowances,
    this.aiCoverListings = 0,
    this.prioritySupportMinutes = 0,
  });

  final String id;
  final String name;
  final String pitch;
  final int monthlyPrice;
  final List<PlanPeriod> periods;

  /// feature -> monthly allowance (watches: how many at once).
  final Map<String, int> allowances;

  /// What the AI cover tries come to in listings.
  final int aiCoverListings;
  final int prioritySupportMinutes;

  int allowance(String feature) => allowances[feature] ?? 0;

  PlanPeriod? period(int months) {
    for (final p in periods) {
      if (p.months == months) return p;
    }
    return null;
  }

  factory PremiumPlan.fromJson(Map<String, dynamic> j) {
    final a = (j['allowances'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PremiumPlan(
      id: j['id'] as String? ?? '',
      name: j['name'] as String? ?? '',
      pitch: j['pitch'] as String? ?? '',
      monthlyPrice: _int(j['monthly_price']),
      periods: [
        for (final p in (j['periods'] as List? ?? const []))
          PlanPeriod.fromJson((p as Map).cast<String, dynamic>()),
      ],
      allowances: {for (final f in PremiumFeature.all) f: _int(a[f])},
      aiCoverListings: _int(a['ai_cover_listings']),
      prioritySupportMinutes: _int(a['priority_support_minutes']),
    );
  }
}

class Allowance {
  const Allowance({required this.allowance, required this.used, required this.left});
  final int allowance;
  final int used;
  final int left;

  factory Allowance.fromJson(Map<String, dynamic> j) =>
      Allowance(allowance: _int(j['allowance']), used: _int(j['used']), left: _int(j['left']));
}

/// GET /premium/me.
class PremiumStatus {
  const PremiumStatus({
    required this.enabled,
    this.planId,
    this.planName,
    this.monthlyPrice = 0,
    this.paidUntil,
    this.renewsAt,
    this.usage = const {},
    this.trial = const {},
  });

  /// False: every premium feature is free right now, and nothing is sold.
  final bool enabled;
  final String? planId;
  final String? planName;
  final int monthlyPrice;
  final DateTime? paidUntil;
  final DateTime? renewsAt;
  final Map<String, Allowance> usage;

  /// Free tries left for someone without a plan (feature -> left).
  final Map<String, int> trial;

  bool get hasPlan => planId != null;

  /// Whether [feature] can be used now: always while premium is off.
  bool canUse(String feature) => !enabled || (usage[feature]?.left ?? 0) > 0;

  int left(String feature) => usage[feature]?.left ?? 0;

  /// Whether the plan has [feature] at all, used up this month or not:
  /// always while premium is off. A screen the feature opens (Zeno's
  /// pricing conversation) asks this; the step that spends it, canUse.
  bool includes(String feature) => !enabled || (usage[feature]?.allowance ?? 0) > 0;

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse('${v}Z')?.toLocal() : null;

  factory PremiumStatus.fromJson(Map<String, dynamic> j) {
    final plan = (j['plan'] as Map?)?.cast<String, dynamic>();
    final usage = (j['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
    final trial = (j['trial'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PremiumStatus(
      enabled: j['enabled'] == true,
      planId: plan?['id'] as String?,
      planName: plan?['name'] as String?,
      monthlyPrice: _int(plan?['monthly_price']),
      paidUntil: _date(j['paid_until']),
      renewsAt: _date(j['renews_at']),
      usage: {
        for (final e in usage.entries)
          if (e.value is Map) e.key: Allowance.fromJson((e.value as Map).cast<String, dynamic>()),
      },
      trial: {for (final e in trial.entries) e.key: _int(e.value)},
    );
  }
}

/// A plan payment's progress (POST /premium/subscribe, GET /premium/payments/{id}).
class PlanPayment {
  const PlanPayment({
    required this.id,
    required this.status,
    required this.amount,
    required this.months,
    this.planId,
    this.paidUntil,
    this.failureReason,
  });

  final String id;

  /// pending | success | failed
  final String status;
  final int amount;
  final int months;
  final String? planId;
  final DateTime? paidUntil;
  final String? failureReason;

  bool get pending => status == 'pending';
  bool get succeeded => status == 'success';

  factory PlanPayment.fromJson(Map<String, dynamic> j) => PlanPayment(
        id: j['payment_id'] as String? ?? '',
        status: j['status'] as String? ?? 'pending',
        amount: _int(j['amount']),
        months: _int(j['months']),
        planId: j['plan_id'] as String?,
        paidUntil: PremiumStatus._date(j['paid_until']),
        failureReason: j['failure_reason'] as String?,
      );
}
