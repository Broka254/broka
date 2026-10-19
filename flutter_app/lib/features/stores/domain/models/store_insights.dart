// BROKA — the store dashboard's data
//
// Mirrors GET /stores/{id}/insights (backend stores/insights.py). Every
// number here is measured by the server; this model only parses it, so the
// screen cannot invent a figure the backend did not send.
//
// Two rules the parsing keeps:
//   * a missing source stays missing (null), never 0 — "not measured" and
//     "none" are different facts;
//   * `exact` on product views is carried through, because a lifetime
//     counter must not be labelled "this week" when no snapshot covers the
//     period.
import 'store.dart';

/// One KPI, with the period immediately before it for the delta.
class StoreKpi {
  final int value;
  final int? previous;

  /// Null when there is no previous period to compare against, or when the
  /// previous value was zero: a jump from nothing is "new", not "+100%".
  final double? changePercent;

  /// False when the number is a lifetime total rather than a period count.
  final bool exact;

  const StoreKpi({
    this.value = 0,
    this.previous,
    this.changePercent,
    this.exact = true,
  });

  factory StoreKpi.fromJson(Object? json) {
    if (json is! Map) return const StoreKpi();
    return StoreKpi(
      value: (json['value'] as num?)?.toInt() ?? 0,
      previous: (json['previous'] as num?)?.toInt(),
      changePercent: (json['change_percent'] as num?)?.toDouble(),
      exact: json['exact'] as bool? ?? true,
    );
  }

  bool get isNew => value > 0 && (previous ?? 0) == 0;
  bool get hasChange => changePercent != null;
}

class StoreDayPoint {
  final DateTime date;
  final int count;
  const StoreDayPoint(this.date, this.count);

  static List<StoreDayPoint> listFromJson(Object? json) => [
        for (final row in json as List? ?? const [])
          if (row is Map && DateTime.tryParse(row['date'] as String? ?? '') != null)
            StoreDayPoint(
              DateTime.parse(row['date'] as String),
              (row['count'] as num?)?.toInt() ?? 0,
            ),
      ];
}

class StoreTopProduct {
  final String id;
  final String name;
  final double? price;
  final int views;
  final int saves;
  final int likes;
  final int interestedBuyers;
  final String state;

  const StoreTopProduct({
    required this.id,
    required this.name,
    this.price,
    this.views = 0,
    this.saves = 0,
    this.likes = 0,
    this.interestedBuyers = 0,
    this.state = 'active',
  });

  factory StoreTopProduct.fromJson(Map<String, dynamic> j) => StoreTopProduct(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        price: (j['price'] as num?)?.toDouble(),
        views: (j['views'] as num?)?.toInt() ?? 0,
        saves: (j['saves'] as num?)?.toInt() ?? 0,
        likes: (j['likes'] as num?)?.toInt() ?? 0,
        interestedBuyers: (j['interested_buyers'] as num?)?.toInt() ?? 0,
        state: j['state'] as String? ?? 'active',
      );
}

/// One advice card. `severity` sorts negatives, worst first; positives use 0.
class StoreAdvice {
  final String code;
  final String title;
  final String detail;
  final int severity;

  const StoreAdvice({
    required this.code,
    required this.title,
    required this.detail,
    this.severity = 0,
  });

  factory StoreAdvice.fromJson(Map<String, dynamic> j) => StoreAdvice(
        code: j['code'] as String? ?? '',
        title: j['title'] as String? ?? '',
        detail: j['detail'] as String? ?? '',
        severity: (j['severity'] as num?)?.toInt() ?? 0,
      );
}

class StoreInsights {
  final String storeId;
  final String storeName;
  final String slug;
  final bool isActive;
  final double? rating;
  final StoreRatingBreakdown? ratingBreakdown;
  final String? ratingExplanation;
  final int reviewCount;
  final double? responseMinutes;
  final int? rank;
  final int storesTotal;
  final int products;
  final int liveVisitors;

  final int days;
  final DateTime from;
  final DateTime to;

  final StoreKpi visits;
  final StoreKpi productViews;
  final StoreKpi saves;
  final StoreKpi likes;
  final StoreKpi interestedBuyers;
  final StoreKpi chats;
  final StoreKpi messages;
  final StoreKpi shares;

  final List<StoreDayPoint> visitSeries;
  final List<StoreDayPoint> viewSeries;
  final List<StoreDayPoint> chatSeries;

  final Map<String, int> visitsBySource;
  final Map<String, int> visitsBySurface;
  final Map<String, int> sharesByChannel;

  final List<StoreTopProduct> topProducts;
  final List<StoreAdvice> positives;
  final List<StoreAdvice> negatives;

  const StoreInsights({
    required this.storeId,
    required this.storeName,
    required this.slug,
    this.isActive = true,
    this.rating,
    this.ratingBreakdown,
    this.ratingExplanation,
    this.reviewCount = 0,
    this.responseMinutes,
    this.rank,
    this.storesTotal = 0,
    this.products = 0,
    this.liveVisitors = 0,
    this.days = 7,
    required this.from,
    required this.to,
    this.visits = const StoreKpi(),
    this.productViews = const StoreKpi(),
    this.saves = const StoreKpi(),
    this.likes = const StoreKpi(),
    this.interestedBuyers = const StoreKpi(),
    this.chats = const StoreKpi(),
    this.messages = const StoreKpi(),
    this.shares = const StoreKpi(),
    this.visitSeries = const [],
    this.viewSeries = const [],
    this.chatSeries = const [],
    this.visitsBySource = const {},
    this.visitsBySurface = const {},
    this.sharesByChannel = const {},
    this.topProducts = const [],
    this.positives = const [],
    this.negatives = const [],
  });

  factory StoreInsights.fromJson(Map<String, dynamic> j) {
    final store = (j['store'] as Map?)?.cast<String, dynamic>() ?? const {};
    final period = (j['period'] as Map?)?.cast<String, dynamic>() ?? const {};
    final kpis = (j['kpis'] as Map?)?.cast<String, dynamic>() ?? const {};
    final series = (j['series'] as Map?)?.cast<String, dynamic>() ?? const {};
    final sources = (j['sources'] as Map?)?.cast<String, dynamic>() ?? const {};
    final advice = (j['advice'] as Map?)?.cast<String, dynamic>() ?? const {};

    Map<String, int> counts(Object? m) => m is Map
        ? {
            for (final e in m.entries)
              e.key.toString(): (e.value as num?)?.toInt() ?? 0,
          }
        : const {};

    final today = DateTime.now();
    final from = DateTime.tryParse(period['from'] as String? ?? '') ?? today;
    final to = DateTime.tryParse(period['to'] as String? ?? '') ?? today;

    return StoreInsights(
      storeId: store['id'] as String? ?? '',
      storeName: store['name'] as String? ?? '',
      slug: store['slug'] as String? ?? '',
      isActive: store['is_active'] as bool? ?? true,
      rating: (store['rating'] as num?)?.toDouble(),
      ratingBreakdown: StoreRatingBreakdown.fromJson(store['rating_breakdown']),
      ratingExplanation: store['rating_explanation'] as String?,
      reviewCount: (store['review_count'] as num?)?.toInt() ?? 0,
      responseMinutes: (store['response_minutes'] as num?)?.toDouble(),
      rank: (store['rank'] as num?)?.toInt(),
      storesTotal: (store['stores_total'] as num?)?.toInt() ?? 0,
      products: (store['products'] as num?)?.toInt() ?? 0,
      liveVisitors: (store['live_visitors'] as num?)?.toInt() ?? 0,
      days: (period['days'] as num?)?.toInt() ?? 7,
      from: from,
      to: to,
      visits: StoreKpi.fromJson(kpis['visits']),
      productViews: StoreKpi.fromJson(kpis['product_views']),
      saves: StoreKpi.fromJson(kpis['saves']),
      likes: StoreKpi.fromJson(kpis['likes']),
      interestedBuyers: StoreKpi.fromJson(kpis['interested_buyers']),
      chats: StoreKpi.fromJson(kpis['chats']),
      messages: StoreKpi.fromJson(kpis['messages']),
      shares: StoreKpi.fromJson(kpis['shares']),
      visitSeries: StoreDayPoint.listFromJson(series['visits']),
      viewSeries: StoreDayPoint.listFromJson(series['product_views']),
      chatSeries: StoreDayPoint.listFromJson(series['chats']),
      visitsBySource: counts(sources['visits_by_source']),
      visitsBySurface: counts(sources['visits_by_surface']),
      sharesByChannel: counts(sources['shares_by_channel']),
      topProducts: [
        for (final row in j['top_products'] as List? ?? const [])
          if (row is Map) StoreTopProduct.fromJson(row.cast<String, dynamic>()),
      ],
      positives: [
        for (final row in advice['positives'] as List? ?? const [])
          if (row is Map) StoreAdvice.fromJson(row.cast<String, dynamic>()),
      ],
      negatives: [
        for (final row in advice['negatives'] as List? ?? const [])
          if (row is Map) StoreAdvice.fromJson(row.cast<String, dynamic>()),
      ],
    );
  }

  /// "Usually replies in about 25 min", or null when unmeasured.
  String? get replyLabel {
    final minutes = responseMinutes;
    if (minutes == null) return null;
    if (minutes < 1) return 'Usually replies straight away';
    if (minutes < 60) return 'Usually replies in about ${minutes.round()} min';
    final hours = minutes / 60;
    if (hours < 24) return 'Usually replies in about ${hours.toStringAsFixed(1)} h';
    return 'Usually replies in about ${(hours / 24).toStringAsFixed(1)} days';
  }

  /// "6.5/10" or "Not rated yet" for the header.
  String get ratingLabel => rating == null ? '–' : rating!.toStringAsFixed(1);

  /// "#4 of 37 stores", or null when the rank is not known.
  String? get rankLabel {
    final position = rank;
    if (position == null || storesTotal <= 0) return null;
    return '#$position of $storesTotal stores';
  }

  /// The chosen metric's series, for the chart's metric switch.
  List<StoreDayPoint> seriesFor(StoreMetric metric) => switch (metric) {
        StoreMetric.visits => visitSeries,
        StoreMetric.views => viewSeries,
        StoreMetric.chats => chatSeries,
      };
}

/// The three series the trend card can draw.
enum StoreMetric {
  visits('Visits', 'Visitors'),
  views('Product views', 'Views'),
  chats('Chats', 'Chats');

  const StoreMetric(this.label, this.axisTitle);
  final String label;
  final String axisTitle;
}
