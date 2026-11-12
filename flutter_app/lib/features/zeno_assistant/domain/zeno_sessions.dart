// Today's Zeno sessions for an account without a plan (backend
// api/domains/premium/zeno_sessions.py, GET /zeno/sessions/today).
//
// A free account asks Zeno about a few listings a day and starts a few
// Buying Agent hunts - two of each by default. A session is the whole
// conversation, not a message: every question about one listing that day
// is one, and a hunt is one however many turns it takes. The listing's
// "Ask Zeno" card says how many are left, and that asking again about a
// listing already asked about today costs nothing.

int? _int(Object? v) => v is num ? v.toInt() : null;

class ZenoSessionsToday {
  const ZenoSessionsToday({
    required this.limited,
    this.listingLimit,
    this.listingLeft,
    this.listingIds = const {},
    this.agentLimit,
    this.agentLeft,
  });

  /// False with a plan: nothing is counted.
  final bool limited;

  /// Listings a free account may ask Zeno about today, and how many are left.
  final int? listingLimit;
  final int? listingLeft;

  /// Listings already asked about today.
  final Set<String> listingIds;

  /// Buying Agent hunts a free account may start today, and how many are left.
  final int? agentLimit;
  final int? agentLeft;

  /// Asking about [listingId] today needs no session it doesn't already have.
  bool covers(String listingId) => !limited || listingIds.contains(listingId);

  static ZenoSessionsToday? fromJson(Object? json) {
    if (json is! Map || json['limited'] is! bool) return null;
    final listing = json['listing'] is Map ? json['listing'] as Map : const {};
    final agent = json['agent'] is Map ? json['agent'] as Map : const {};
    final ids = listing['listing_ids'];
    return ZenoSessionsToday(
      limited: json['limited'] as bool,
      listingLimit: _int(listing['limit']),
      listingLeft: _int(listing['left']),
      listingIds: {
        if (ids is List)
          for (final id in ids)
            if (id is String && id.isNotEmpty) id,
      },
      agentLimit: _int(agent['limit']),
      agentLeft: _int(agent['left']),
    );
  }
}
