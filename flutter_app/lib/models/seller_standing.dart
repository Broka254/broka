// A seller's standing, as buyers see it on a listing's screen:
// GET /auth/user/{id} -> seller_standing (backend/api/domains/trust/
// public_standing.py).
//
// These are the seller dashboard's own figures - the overall rating, the
// deal completion rate and the response time, its first three "performance
// over time" charts - so the thresholds that colour them live here, and the
// dashboard's charts read them from here too. A seller whose reply time the
// dashboard shades green is not shown the same number in amber on their
// listing.
//
// Last night's snapshot, not the dashboard's live figure: a listing is
// opened far more often than a dashboard, and the live response time is a
// scan of every recent message on the platform. Rank position and backlog
// are not in it - they stay the seller's.
//
// The average deal completion time rides alongside: agreement to payout,
// over the seller's recent completed deals, measured live on the profile
// (backend/api/domains/trust/deal_time.py) - a few rows, not a scan.

class SellerStanding {
  const SellerStanding({
    this.overallRating,
    this.dcr,
    this.dcrProvisional = false,
    this.responseMinutes,
    this.completedDeals = 0,
    this.dealTimeMinutes,
    this.timedDeals = 0,
  });

  /// 0-10.
  final double? overallRating;

  /// 0-100. Null until the seller's first completed deal: the rate starts
  /// at an 80% prior, which is not a track record.
  final double? dcr;

  /// Under ten completed deals - real, but it still moves a lot per deal.
  final bool dcrProvisional;

  /// Median minutes to reply. Null when there were too few conversations to
  /// measure, which is not the same as fast.
  final double? responseMinutes;

  final int completedDeals;

  /// Mean minutes from a deal being agreed to the seller being paid, over
  /// their recent completed deals. Null before the first one: "no deals
  /// yet" is not "instant".
  final double? dealTimeMinutes;

  /// How many completed deals [dealTimeMinutes] is the mean of.
  final int timedDeals;

  // The dashboard's bands (seller_dashboard_screen.dart, _buildTrendSection).
  static const ratingGood = 8.0;
  static const ratingPoor = 6.0;
  static const dcrGood = 90.0;
  static const dcrPoor = 70.0;

  /// Response time is the other way up: lower is better.
  static const responseGood = 30.0;
  static const responsePoor = 180.0;

  /// Deal time is lower-is-better too. The buyer's money sits in escrow for
  /// all of it: two days is a local handover done promptly, a week or more is
  /// money held that long.
  static const dealTimeGood = 2 * 1440.0;
  static const dealTimePoor = 7 * 1440.0;

  static SellerStanding? fromJson(Object? json) {
    if (json is! Map) return null;
    double? d(String k) => (json[k] as num?)?.toDouble();
    return SellerStanding(
      overallRating: d('overall_rating'),
      dcr: d('dcr'),
      dcrProvisional: json['dcr_provisional'] == true,
      responseMinutes: d('median_response_minutes'),
      completedDeals: (json['completed_deals'] as num?)?.toInt() ?? 0,
    );
  }

  /// The standing from a GET /auth/user/{id} body: the snapshot under
  /// `seller_standing`, and the deal time beside it. Never null - a seller
  /// with no snapshot yet still shows which figures are not in.
  static SellerStanding fromProfile(Map<String, dynamic>? profile) {
    final s = fromJson(profile?['seller_standing']) ?? const SellerStanding();
    return SellerStanding(
      overallRating: s.overallRating,
      dcr: s.dcr,
      dcrProvisional: s.dcrProvisional,
      responseMinutes: s.responseMinutes,
      completedDeals: s.completedDeals,
      dealTimeMinutes: (profile?['avg_deal_time_minutes'] as num?)?.toDouble(),
      timedDeals: (profile?['timed_deals'] as num?)?.toInt() ?? 0,
    );
  }

  /// Buyer-facing standing carried by a public listing detail. This avoids
  /// making the product screen depend on the authenticated profile request.
  static SellerStanding fromListing(Map<String, dynamic>? listing) {
    final nested = fromJson(listing?['seller_standing']);
    final completed = (listing?['seller_completed_deals'] as num?)?.toInt()
        ?? nested?.completedDeals
        ?? 0;
    return SellerStanding(
      overallRating: nested?.overallRating,
      dcr: (listing?['seller_dcr'] as num?)?.toDouble() ?? nested?.dcr,
      dcrProvisional: listing?['seller_dcr_provisional'] == true
          || (nested?.dcrProvisional ?? false),
      responseMinutes: (listing?['seller_response_minutes'] as num?)?.toDouble()
          ?? nested?.responseMinutes,
      completedDeals: completed,
      dealTimeMinutes: (listing?['seller_avg_deal_time_minutes'] as num?)?.toDouble(),
      timedDeals: (listing?['seller_timed_deals'] as num?)?.toInt() ?? 0,
    );
  }

  /// "25m", "2.5h", "1.5d" - the dashboard's response-time chart labels.
  static String formatMinutes(double v) => v < 60
      ? '${v.round()}m'
      : (v < 1440 ? '${(v / 60).toStringAsFixed(1)}h' : '${(v / 1440).toStringAsFixed(1)}d');
}

/// Where a figure sits against its bands.
enum StandingBand { good, fair, poor, unknown }

extension SellerStandingBands on SellerStanding {
  StandingBand get ratingBand => _band(overallRating, SellerStanding.ratingGood, SellerStanding.ratingPoor);
  StandingBand get dcrBand => _band(dcr, SellerStanding.dcrGood, SellerStanding.dcrPoor);
  StandingBand get responseBand {
    final m = responseMinutes;
    if (m == null) return StandingBand.unknown;
    if (m <= SellerStanding.responseGood) return StandingBand.good;
    return m >= SellerStanding.responsePoor ? StandingBand.poor : StandingBand.fair;
  }

  StandingBand get dealTimeBand {
    final m = dealTimeMinutes;
    if (m == null) return StandingBand.unknown;
    if (m <= SellerStanding.dealTimeGood) return StandingBand.good;
    return m >= SellerStanding.dealTimePoor ? StandingBand.poor : StandingBand.fair;
  }

  static StandingBand _band(double? v, double good, double poor) {
    if (v == null) return StandingBand.unknown;
    if (v >= good) return StandingBand.good;
    return v < poor ? StandingBand.poor : StandingBand.fair;
  }
}
