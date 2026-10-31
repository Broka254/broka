// Launch offers + time left, as the server computes them
// (backend/api/domains/pricing/launch_offers.py,
// backend/api/domains/listings/time_left.py,
// GET /pricing/launch-offers).
//
// The server owns both facts — how many free slots are left, and how long
// before a listing/store goes offline — so no phone clock or local count
// can disagree with what buyers actually see. This file only parses and
// words them; it never invents a deadline or a remaining count.

import '../../../utils/backend_time.dart';

/// How long before one listing/store goes offline.
class TimeLeft {
  const TimeLeft({
    required this.status,
    required this.label,
    this.secondsLeft,
    this.daysLeft,
    this.goesOfflineAt,
    this.isExpiringSoon = false,
  });

  /// unlimited | live | ending | unpaid | expired | store_covered
  final String status;

  /// Ready to show, from the server: "2d 3h left", "No expiry", …
  final String label;
  final int? secondsLeft;
  final double? daysLeft;
  final DateTime? goesOfflineAt;
  final bool isExpiringSoon;

  bool get isUnlimited => status == 'unlimited';
  bool get isStoreCovered => status == 'store_covered';
  bool get isExpired => status == 'expired';
  bool get isUnpaid => status == 'unpaid';
  bool get isOffline => isExpired || isUnpaid;

  /// Worth a buyer's eye on a card: live, but ending within the window.
  bool get showOnCard => isExpiringSoon && !isOffline && !isUnlimited && !isStoreCovered;

  /// Worth interrupting the owner: ending soon, or already offline.
  bool get needsAttention => isExpiringSoon || isOffline;

  static TimeLeft? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j.cast<String, dynamic>();
    final label = m['label'] as String?;
    if (label == null) return null;
    return TimeLeft(
      status: m['status'] as String? ?? 'unlimited',
      label: label,
      secondsLeft: (m['seconds_left'] as num?)?.toInt(),
      daysLeft: (m['days_left'] as num?)?.toDouble(),
      goesOfflineAt: parseBackendUtc(m['goes_offline_at'] as String?),
      isExpiringSoon: m['is_expiring_soon'] == true,
    );
  }

  /// A payload that carries the flat siblings (`time_left_label`,
  /// `seconds_left`, …) beside a nested `time_left`, as store payloads do.
  static TimeLeft? fromPayload(Map<String, dynamic> j) {
    final nested = fromJson(j['time_left']);
    if (nested != null) return nested;
    final label = j['time_left_label'] as String?;
    if (label == null) return null;
    final seconds = (j['seconds_left'] as num?)?.toInt();
    return TimeLeft(
      status: seconds == null
          ? 'unlimited'
          : (seconds <= 0 ? 'expired' : 'live'),
      label: label,
      secondsLeft: seconds,
      daysLeft: (j['days_left'] as num?)?.toDouble(),
      goesOfflineAt: parseBackendUtc(j['goes_offline_at'] as String?),
      isExpiringSoon: seconds != null && seconds > 0 && seconds <= 7 * 86400,
    );
  }

  /// "Goes offline 14 Oct" for owner surfaces, or null with no deadline.
  String? get offlineDateLabel {
    final at = goesOfflineAt;
    if (at == null) return null;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final local = at.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}

/// One launch offer (first-50 listings / first-10 stores) for one user.
class LaunchOffer {
  const LaunchOffer({
    required this.limit,
    required this.claimed,
    required this.remaining,
    required this.freeDays,
    this.onePerUser = true,
    this.eligible,
    this.alreadyClaimed,
    this.enabled,
  });

  final int limit;
  final int claimed;
  final int remaining;
  final int freeDays;
  final bool onePerUser;
  final bool? eligible;
  final bool? alreadyClaimed;

  /// False: the matching billing switch is off — paused, not exhausted.
  final bool? enabled;

  /// An explicit server `enabled` wins; older payloads without it fall
  /// back to a positive limit (a quote carries no limit at all).
  bool get isEnabled => enabled ?? limit > 0;
  bool get isExhausted => remaining <= 0;

  /// This user can still claim it right now (billing on, slot left).
  bool get isAvailableForUser =>
      isEnabled && !isExhausted && eligible == true && alreadyClaimed != true;

  /// Slots are still on the table for someone. Independent of the billing
  /// switches: while fees are off in production, `eligible`/`enabled`
  /// read false for everyone, and gating the card on them made the launch
  /// offer invisible on every screen — the offer existed only in the API.
  bool get hasSlots => limit > 0 && remaining > 0;

  /// Show the card at all: slots remain (a promotion users can act on by
  /// posting/opening now), or this user already took it (so they know
  /// where their free period came from). Only a configured-off offer
  /// (limit 0) or an exhausted one nobody took stays silent.
  bool get shouldShow => hasSlots || alreadyClaimed == true;

  factory LaunchOffer.fromJson(Map<String, dynamic> j) => LaunchOffer(
        limit: (j['limit'] as num?)?.toInt() ?? 0,
        claimed: (j['claimed'] as num?)?.toInt() ?? 0,
        remaining: (j['remaining'] as num?)?.toInt() ?? 0,
        freeDays: (j['free_days'] as num?)?.toInt() ?? 0,
        onePerUser: j['one_per_user'] != false,
        eligible: j['eligible'] as bool?,
        alreadyClaimed: j['already_claimed'] as bool?,
        enabled: j['enabled'] as bool?,
      );

  /// The listing-fee quote's smaller `launch_offer` object. The server
  /// rides the offer's `limit` along so the sell screen's banner can say
  /// "only X of 50 left" from the quote alone.
  factory LaunchOffer.fromQuoteJson(Map<String, dynamic> j) => LaunchOffer(
        limit: (j['limit'] as num?)?.toInt() ?? 0,
        claimed: 0,
        remaining: (j['remaining'] as num?)?.toInt() ?? 0,
        freeDays: (j['free_days'] as num?)?.toInt() ?? 0,
        eligible: j['eligible'] as bool?,
        enabled: j['enabled'] as bool?,
      );
}

/// Both offers, from GET /pricing/launch-offers.
class LaunchOffers {
  const LaunchOffers({required this.listingFree, required this.storeFree});
  final LaunchOffer listingFree;
  final LaunchOffer storeFree;

  factory LaunchOffers.fromJson(Map<String, dynamic> j) => LaunchOffers(
        listingFree: LaunchOffer.fromJson(
            (j['listing_free'] as Map?)?.cast<String, dynamic>() ?? const {}),
        storeFree: LaunchOffer.fromJson(
            (j['store_free'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}
