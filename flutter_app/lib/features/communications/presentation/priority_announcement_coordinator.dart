// App-wide priority announcement coordination.
//
// The announcements centre only helps a user who opens it. This decides
// which already-fetched announcements are important enough to interrupt
// with (unread, unexpired, high or critical severity), in what order, and
// whether this app session has already presented or deferred them - so
// startup, sign-in, resume, the poller and an FCM push can all ask the
// same question without stacking dialogs or repeating one on every poll.
import 'dart:async';

import '../domain/models/announcement.dart';

/// Pure selection and ordering for priority announcements.
abstract final class PriorityAnnouncements {
  static int _rank(AnnouncementSeverity severity) =>
      severity == AnnouncementSeverity.critical ? 0 : 1;

  static bool isPriority(Announcement a) =>
      a.severity == AnnouncementSeverity.critical ||
      a.severity == AnnouncementSeverity.high;

  static bool _isExpiredAt(Announcement a, DateTime now) {
    final expiry = a.expiresAt;
    return expiry != null && !expiry.isAfter(now.toUtc());
  }

  /// Unread, unexpired, high/critical announcements: critical first, then
  /// newest published first. The id breaks ties so the order never
  /// depends on the feed's own ordering.
  static List<Announcement> select(
    Iterable<Announcement> items, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now().toUtc();
    final eligible = items
        .where((a) => isPriority(a) && !a.isRead && !_isExpiredAt(a, at))
        .toList();
    eligible.sort((a, b) {
      final bySeverity = _rank(a.severity).compareTo(_rank(b.severity));
      if (bySeverity != 0) return bySeverity;
      final aTime = a.publishedAt;
      final bTime = b.publishedAt;
      if (aTime != null && bTime != null) {
        final byTime = bTime.compareTo(aTime);
        if (byTime != 0) return byTime;
      } else if (aTime != null) {
        return -1;
      } else if (bTime != null) {
        return 1;
      }
      return a.id.compareTo(b.id);
    });
    return eligible;
  }
}

/// Session-scoped presentation state for one authenticated account.
///
/// Deliberately in memory only: deferring a notice suppresses it for this
/// app session, never permanently, so an unread critical announcement is
/// eligible again on the next cold launch (a new coordinator, or
/// [resetSession]). Nothing here marks anything read.
class PriorityAnnouncementCoordinator {
  String? _accountId;
  final Set<String> _deferredIds = <String>{};
  bool _presenting = false;
  bool _checking = false;
  int _generation = 0;

  String? get accountId => _accountId;
  bool get isPresenting => _presenting;
  bool get isChecking => _checking;

  /// Point the coordinator at [userId]. A different account (or sign-out)
  /// drops the previous account's deferrals and invalidates any check
  /// still in flight for it.
  void syncAccount(String? userId) {
    if (_accountId == userId) return;
    _accountId = userId;
    _deferredIds.clear();
    _generation++;
  }

  /// A new cold-start session: deferred notices are eligible again.
  void resetSession() {
    _deferredIds.clear();
    _generation++;
  }

  bool isDeferred(String announcementId) =>
      _deferredIds.contains(announcementId);

  /// "Remind me later": suppress this announcement for this session only.
  /// Does not touch read state.
  void defer(String announcementId) {
    if (announcementId.isNotEmpty) _deferredIds.add(announcementId);
  }

  /// Eligible announcements that may be presented now (deferrals removed).
  List<Announcement> eligibleFor(Iterable<Announcement> items,
          {DateTime? now}) =>
      PriorityAnnouncements.select(items, now: now)
          .where((a) => !_deferredIds.contains(a.id))
          .toList();

  /// The single presentation lock: only one priority overlay at a time.
  bool tryStartPresenting() {
    if (_presenting) return false;
    _presenting = true;
    return true;
  }

  void stopPresenting() => _presenting = false;

  /// Refresh the feed, then present the eligible priority announcements
  /// once. Returns true when an overlay was presented.
  ///
  /// A failed refresh is not an empty feed: nothing is presented and
  /// nothing is marked seen, so a later trigger can retry. A check that
  /// finishes after the account changed is discarded. [canPresent] is
  /// asked after the refresh, when the UI state is current; returning
  /// false defers presentation to a later trigger without consuming it.
  Future<bool> checkAndPresent({
    required String? accountId,
    required Future<bool> Function() refreshFeed,
    required List<Announcement> Function() feed,
    required bool Function() canPresent,
    required Future<void> Function(List<Announcement> eligible) present,
  }) async {
    syncAccount(accountId);
    if (accountId == null || _checking) return false;
    _checking = true;
    final generation = _generation;
    try {
      final refreshed = await refreshFeed();
      if (!refreshed) return false;
      if (generation != _generation || _accountId != accountId) return false;
      if (!canPresent()) return false;
      final eligible = eligibleFor(feed());
      if (eligible.isEmpty) return false;
      if (!tryStartPresenting()) return false;
      try {
        await present(eligible);
      } finally {
        stopPresenting();
      }
      return true;
    } finally {
      _checking = false;
    }
  }
}
