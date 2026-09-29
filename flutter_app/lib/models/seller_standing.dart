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

class SellerStanding {
  const SellerStanding({
    this.overallRating,
    this.dcr,
    this.dcrProvisional = false,
    this.responseMinutes,
    this.completedDeals = 0,
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

  // The dashboard's bands (seller_dashboard_screen.dart, _buildTrendSection).
  static const ratingGood = 8.0;
  static const ratingPoor = 6.0;
  static const dcrGood = 90.0;
  static const dcrPoor = 70.0;

  /// Response time is the other way up: lower is better.
  static const responseGood = 30.0;
  static const responsePoor = 180.0;

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

  static StandingBand _band(double? v, double good, double poor) {
    if (v == null) return StandingBand.unknown;
    if (v >= good) return StandingBand.good;
    return v < poor ? StandingBand.poor : StandingBand.fair;
  }
}
