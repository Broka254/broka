// lib/features/buy_agent/domain/models/buy_agent_request.dart
import '../../../../utils/backend_time.dart';

class BuyAgentRequest {
  final String id;
  final String category;
  final double maxPrice;
  final List<String> mustHaveFeatures;
  final String status; // "active" | "matched" | "cancelled" | "expired"
  // Nullable (buying-agent bug-hunt, 2026-09-17): the backend's own
  // serializer now tolerates a row with no created_at rather than 500ing
  // (buy_agent/service.py _dict), so parsing has to as well - a
  // non-null DateTime.parse on a null here would have crashed the
  // Home card and the Hub for that buyer instead.
  final DateTime? createdAt;
  // Real count of listings matched so far (redesign-guide audit fix -
  // buy_agent_subscribers.py increments this on the backend; previously
  // there was no persisted count at all, so the UI could only say "still
  // searching" / "match found", never a real number).
  final int matchCount;
  // When the watch ends by itself (BUY_AGENT_WATCH_DAYS after it was made
  // or last changed). Naive UTC from the backend, so parseBackendUtc - a
  // plain DateTime.tryParse would read it as local time. Null from a
  // backend that predates expiry.
  final DateTime? expiresAt;

  /// Days until the watch ends, a part day counting as one: a new 30-day
  /// watch has 30, its final hours 1, and one already past its date 0.
  /// Null when the backend didn't say.
  int? daysLeft(DateTime now) {
    final ends = expiresAt;
    if (ends == null) return null;
    final left = ends.difference(now.toUtc());
    if (left <= Duration.zero) return 0;
    return (left.inMinutes / Duration.minutesPerDay).ceil();
  }

  /// True once Zeno has found at least one listing for this request.
  /// Derived here rather than re-deriving `status == 'matched'` at each of
  /// the three call sites that render it.
  bool get hasMatches => status == 'matched' && matchCount > 0;

  BuyAgentRequest({
    required this.id,
    required this.category,
    required this.maxPrice,
    required this.mustHaveFeatures,
    required this.status,
    this.createdAt,
    this.matchCount = 0,
    this.expiresAt,
  });

  factory BuyAgentRequest.fromJson(Map<String, dynamic> json) => BuyAgentRequest(
        id: json['id'] as String,
        category: json['category'] as String,
        maxPrice: (json['max_price'] as num).toDouble(),
        mustHaveFeatures: (json['must_have_features'] as List?)?.map((e) => e.toString()).toList() ?? [],
        status: json['status'] as String,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
        matchCount: (json['match_count'] as num?)?.toInt() ?? 0,
        expiresAt: parseBackendUtc(json['expires_at'] as String?),
      );
}
