// lib/features/buy_agent/domain/models/buy_agent_request.dart
class BuyAgentRequest {
  final String id;
  final String category;
  final double maxPrice;
  final List<String> mustHaveFeatures;
  final String status; // "active" | "matched" | "cancelled"
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
  });

  factory BuyAgentRequest.fromJson(Map<String, dynamic> json) => BuyAgentRequest(
        id: json['id'] as String,
        category: json['category'] as String,
        maxPrice: (json['max_price'] as num).toDouble(),
        mustHaveFeatures: (json['must_have_features'] as List?)?.map((e) => e.toString()).toList() ?? [],
        status: json['status'] as String,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
        matchCount: (json['match_count'] as num?)?.toInt() ?? 0,
      );
}
