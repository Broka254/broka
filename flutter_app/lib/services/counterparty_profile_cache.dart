// BROKA - Counterparty profile cache.
//
// The direct-chat header used to depend on a live profile fetch: offline,
// it fell back to generic "Buyer"/"Seller" labels and lost the photo.
// This cache renders the last known profile instantly, then refreshes it
// in the background - and a failed refresh keeps the cached identity
// rather than replacing a known person with a generic label.
//
// Honesty rule: cached *identity* (name, photo) is durable, cached
// *presence* (online) is not. A stale "online" must never show as current,
// so the cache never reports online - only a fresh fetch does.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The profile fields the direct-chat header actually reads.
class CounterpartyProfile {
  const CounterpartyProfile({
    required this.userId,
    this.name,
    this.photo,
    this.verified,
    this.lastSeenLabel,
    this.savedAt,
  });

  final String userId;
  final String? name;
  final String? photo;
  final bool? verified;
  final String? lastSeenLabel;
  final DateTime? savedAt;

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        if (name != null) 'name': name,
        if (photo != null) 'profile_photo': photo,
        if (verified != null) 'verified': verified,
        if (lastSeenLabel != null) 'last_seen_label': lastSeenLabel,
        if (savedAt != null) 'saved_at': savedAt!.toUtc().toIso8601String(),
      };

  factory CounterpartyProfile.fromJson(Map<String, dynamic> j) =>
      CounterpartyProfile(
        userId: j['user_id'] as String? ?? '',
        name: (j['name'] as String?)?.trim().isEmpty == true
            ? null
            : j['name'] as String?,
        photo: j['profile_photo'] as String?,
        verified: j['verified'] as bool?,
        lastSeenLabel: j['last_seen_label'] as String?,
        savedAt: j['saved_at'] is String
            ? DateTime.tryParse(j['saved_at'] as String)
            : null,
      );

  /// From a live profile payload (ApiService.getUserProfile). Presence is
  /// intentionally NOT cached: see the file docstring.
  factory CounterpartyProfile.fromLive(
      String userId, Map<String, dynamic> info) {
    return CounterpartyProfile(
      userId: userId,
      name: (info['name'] as String?)?.trim().isEmpty == true
          ? null
          : (info['name'] as String?)?.trim(),
      photo: info['profile_photo'] as String?,
      verified: info['verified'] as bool?,
      lastSeenLabel: info['last_seen_label'] as String?,
      savedAt: DateTime.now().toUtc(),
    );
  }
}

class CounterpartyProfileCache {
  CounterpartyProfileCache._();

  static String _key(String viewerId, String counterpartyId) =>
      'counterparty_profile_v1_${viewerId}_$counterpartyId';

  static String keyFor(String? viewerId, String counterpartyId) =>
      _key(viewerId ?? 'anon', counterpartyId);

  /// Last known profile, or null when never fetched. Never throws: a cache
  /// miss must not break the header.
  static Future<CounterpartyProfile?> load(
      String? viewerId, String counterpartyId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(viewerId ?? 'anon', counterpartyId));
      if (raw == null || raw.isEmpty) return null;
      return CounterpartyProfile.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Header fields from a cached profile. Presence is NEVER trusted from
  /// cache: a stale "online" must not show as current, so this always
  /// reports offline with the last known label.
  static Map<String, dynamic> headerFromCache(CounterpartyProfile cached) => {
        'name': cached.name,
        'profile_photo': cached.photo,
        'verified': cached.verified,
        'last_seen_label': cached.lastSeenLabel,
        'is_online': false,
      };

  /// Overwrite the cached profile after a successful fetch. Best-effort.
  static Future<void> save(
      String? viewerId, CounterpartyProfile profile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key(viewerId ?? 'anon', profile.userId), jsonEncode(profile.toJson()));
    } catch (_) {}
  }
}
