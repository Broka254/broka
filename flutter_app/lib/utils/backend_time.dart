// FIX (2026-08-18, reported as "'3h ago' shown for something posted under
// 15 minutes ago"): the backend stores every timestamp as naive UTC
// (Python's `datetime.utcnow()`, which carries no timezone info) and
// serializes it via `.isoformat()`, which produces a string with NO
// timezone suffix at all - no "Z", no "+00:00". e.g. "2026-08-18T18:20:00.123456".
//
// `DateTime.tryParse()` on a string with no offset marker is interpreted
// by Dart as LOCAL time, not UTC. So a later `.toUtc()` call converts it
// AGAIN, subtracting the device's own UTC offset from a value that was
// already UTC to begin with - a double shift. In Kenya (UTC+3) this turns
// "posted 5 minutes ago" into "posted 3h 5m ago", which is exactly the
// bug reported and matches the UTC+3 offset precisely.
//
// parseBackendUtc() fixes this at the parse site: if the string has no
// timezone marker, it appends "Z" before parsing, telling Dart the value
// is already UTC (which it is) instead of letting Dart guess wrong.
//
// Known still-affected call sites this pass did NOT change (found via a
// grep across the whole app, not exhaustively verified/fixed - flagged
// for a dedicated pass rather than silently left implied-fixed):
// services/api_service.dart, auctions/domain/models/auction.dart,
// buy_agent/domain/models/buy_agent_request.dart, models/models.dart,
// core/network/deal_ws_client.dart, screens/review_screen.dart,
// screens/boost_screen.dart, screens/user_profile_screen.dart,
// screens/product_screen.dart, screens/negotiation_screen.dart,
// screens/deal_receipt_history_screen.dart. This pass only fixed the two
// call sites feeding the specific freshness text the user reported
// (models/listing.dart's `Listing.createdAt`, and BrokaListing's
// createdAt as parsed by product_card.dart) - any of the files above that
// also displays a relative/absolute time to the user likely has the same
// bug, just not confirmed against a live report yet.
DateTime? parseBackendUtc(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  // Already has an explicit UTC/offset marker ("Z", or "+HH:MM"/"-HH:MM"
  // at the very end - anchored with $ so this doesn't false-match the
  // hyphens inside the date portion, e.g. "2026-08-18").
  final hasOffset = raw.endsWith('Z') || RegExp(r'[+-]\d\d:\d\d$').hasMatch(raw);
  return DateTime.tryParse(hasOffset ? raw : '${raw}Z');
}
