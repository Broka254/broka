// The announcements centre's shared state: the feed, the server-backed
// unread count behind the badge, and read acknowledgement.
//
// One instance lives above the app (see main.dart's MultiProvider), so the
// Menu badge, the announcements list, and the push handler all read and
// update the same state: opening an announcement brings the badge down
// everywhere at once, without waiting for a refetch.
//
// The backend stays authoritative: the feed is reloaded from
// GET /communications, the badge from GET /communications/unread-count,
// and a read only counts once POST .../read answers. The on-device cache
// (SharedPreferences, per account) is first paint only - the same
// cache-first pattern InboxScreen uses.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../data/repositories/communications_repository.dart';
import '../domain/models/announcement.dart';
import 'priority_announcement_coordinator.dart';

class AnnouncementsState extends ChangeNotifier {
  AnnouncementsState({CommunicationsRepository? repository})
      : _repo = repository ?? communicationsRepository;

  final CommunicationsRepository _repo;

  /// Cache slot for one signed-in account. Per-account like the inbox
  /// cache: the next person to sign in on the same phone must not see the
  /// previous user's announcements before the network answers.
  @visibleForTesting
  static String cacheScopeFor(String? userId) =>
      'announcements_cache_v1_${userId ?? 'anon'}';

  /// Announcements acknowledged while offline or while the request failed.
  /// Kept across restarts so an acknowledgement is never silently dropped:
  /// the next successful load retries them.
  @visibleForTesting
  static String pendingReadsScopeFor(String? userId) =>
      'announcements_pending_reads_v1_${userId ?? 'anon'}';

  static const int pageSize = 50;

  List<Announcement> _items = [];
  List<Announcement> get items => _items;

  int _total = 0;
  int get total => _total;

  bool get hasMore => _items.length < _total;

  bool _loading = false;
  bool get loading => _loading;

  bool _loadingMore = false;
  bool get loadingMore => _loadingMore;

  String? _error;
  String? get error => _error;

  /// The badge number, from GET /communications/unread-count - the whole
  /// feed, not just the loaded page. Null while unknown: an API error is
  /// never silently shown as zero.
  int? _unreadCount;
  int? get unreadCount => _unreadCount;

  bool _unreadFailed = false;

  /// True once [unreadCount] holds a server answer (as opposed to "not
  /// loaded yet" or "the last load failed").
  bool get unreadKnown => _unreadCount != null && !_unreadFailed;

  String? _accountId;
  bool _disposed = false;

  // Overlapping loads (resume, pull-to-refresh, push arrival) must not let
  // a slow older answer overwrite a fresher one - the same _loadSeq guard
  // InboxScreen uses.
  int _loadSeq = 0;
  int _countSeq = 0;

  /// The account this state is currently loaded for. Signing in as someone
  /// else (or out) drops everything - feed, badge, pending reads - before
  /// loading theirs, so one account's announcements never leak into
  /// another's.
  Future<void> useAccount(String? userId) async {
    if (_accountId == userId) return;
    _accountId = userId;
    _loadSeq++;
    _countSeq++;
    _items = [];
    _total = 0;
    _error = null;
    _loading = false;
    _loadingMore = false;
    _unreadCount = null;
    _unreadFailed = false;
    notifyListeners();
    if (userId == null) return;
    await _paintCache();
    unawaited(refresh());
    unawaited(refreshUnreadCount());
  }

  Future<void> _paintCache() async {
    final cached = await _loadCache();
    if (_disposed || cached.isEmpty || _items.isNotEmpty) return;
    _items = cached;
    _total = cached.length;
    notifyListeners();
  }

  /// Unread, unexpired high/critical announcements from the loaded feed,
  /// critical first, then newest first - the ones important enough to
  /// surface automatically (see PriorityAnnouncementCoordinator). This is
  /// a view over [items] only; whether the feed is fresh enough to act on
  /// is the caller's call (a successful [refresh]).
  List<Announcement> get priorityAnnouncements =>
      PriorityAnnouncements.select(_items);

  /// Reload the feed from the server, first page. Safe to call on startup,
  /// resume, login and pull-to-refresh; concurrent calls collapse onto the
  /// latest one. Returns true only when the server answered, so callers
  /// that act on the feed (the priority coordinator) never treat a failed
  /// or superseded refresh - or the cache it painted - as proof.
  Future<bool> refresh() async {
    // No await before the seq capture below: two overlapping refreshes
    // must take sequence numbers in call order, or the slower older
    // answer wins (the reset itself is synchronous for this reason).
    _resetForAccount(ApiService.currentUserId);
    final seq = ++_loadSeq;
    if (_items.isEmpty) {
      await _paintCache();
      if (_disposed || seq != _loadSeq) return false;
    }
    _loading = _items.isEmpty;
    _error = null;
    notifyListeners();
    final result = await _repo.announcements(limit: pageSize, offset: 0);
    if (_disposed || seq != _loadSeq) return false;
    switch (result) {
      case Success(:final data):
        // A cached copy can outlive its expiry; the server already filters
        // its own rows, so only cached ones need this guard.
        _items = data.items.where((a) => !a.isExpired).toList();
        _total = data.total;
        _loading = false;
        _error = null;
        notifyListeners();
        unawaited(_saveCache(_items));
        // An acknowledgement that failed earlier (offline, restart) gets
        // its retry now that the network answered.
        unawaited(_retryPendingReads());
        return true;
      case Failure(:final message):
        _loading = false;
        // Something on screen stays on screen - a failed refresh over a
        // working feed shows the feed, not an error page.
        if (_items.isEmpty) _error = message;
        notifyListeners();
        return false;
    }
  }

  /// Load the next page and append it. Rows already on screen (same id)
  /// are not duplicated - pages can overlap when the feed shifts between
  /// requests.
  Future<void> loadMore() async {
    if (_loadingMore || _loading) return;
    _resetForAccount(ApiService.currentUserId);
    if (!hasMore) return;
    _loadingMore = true;
    notifyListeners();
    final result =
        await _repo.announcements(limit: pageSize, offset: _items.length);
    if (_disposed) return;
    switch (result) {
      case Success(:final data):
        final known = _items.map((a) => a.id).toSet();
        for (final a in data.items) {
          if (!a.isExpired && known.add(a.id)) _items.add(a);
        }
        _total = data.total;
        _loadingMore = false;
        notifyListeners();
        unawaited(_saveCache(_items));
      case Failure():
        // A failed next page is not a failed feed: keep what is shown and
        // let the list's retry affordance try again.
        _loadingMore = false;
        notifyListeners();
    }
  }

  /// Reload the badge number from the server. Called on startup, resume,
  /// login, feed refresh and read-state changes.
  Future<void> refreshUnreadCount() async {
    // No await before the seq capture (see refresh()).
    _resetForAccount(ApiService.currentUserId);
    final seq = ++_countSeq;
    final result = await _repo.unreadCount();
    if (_disposed || seq != _countSeq) return;
    switch (result) {
      case Success(:final data):
        _unreadCount = data;
        _unreadFailed = false;
        notifyListeners();
      case Failure():
        // Never present an error as zero: keep the last known count (or
        // nothing) rather than claiming "all read".
        _unreadFailed = true;
        notifyListeners();
    }
  }

  /// The signed-in account may have changed since the last call (login,
  /// logout, account switch) with no screen open to notice: every entry
  /// point re-syncs first, so one account's feed, badge and pending reads
  /// never leak into another's. Cheap when unchanged.
  ///
  /// Deliberately synchronous (no cache paint): callers run it before
  /// capturing their sequence number, with no await between, so
  /// overlapping calls take numbers in call order. The cache paints
  /// afterwards, under the seq guard like any other answer.
  void _resetForAccount(String? current) {
    if (current == _accountId) return;
    // Invalidate anything in flight for the previous account.
    _loadSeq++;
    _countSeq++;
    _accountId = current;
    _items = [];
    _total = 0;
    _error = null;
    _loading = false;
    _loadingMore = false;
    _unreadCount = null;
    _unreadFailed = false;
    notifyListeners();
  }

  /// Acknowledge that the user opened [announcement]. The UI updates
  /// optimistically, then reconciles with the server answer: on success
  /// the server's read timestamp wins; on failure the announcement goes
  /// back to unread and the id is kept for retry, so the app never claims
  /// the server confirmed a read it did not.
  Future<bool> markRead(Announcement announcement) async {
    _resetForAccount(ApiService.currentUserId);
    if (announcement.isRead) return true;
    final index = _items.indexWhere((a) => a.id == announcement.id);
    final now = DateTime.now().toUtc();
    if (index >= 0) {
      _items[index] = _items[index].copyWith(readAt: now);
      _bumpUnread(-1);
      notifyListeners();
    }
    final result = await _repo.markRead(announcement.id);
    if (_disposed) return false;
    switch (result) {
      case Success(:final data):
        if (index >= 0) {
          _items[index] = _items[index].copyWith(readAt: data.readAt ?? now);
          notifyListeners();
        }
        unawaited(_dropPendingRead(announcement.id));
        // The server is the badge's source of truth - reconcile rather
        // than trusting the optimistic decrement alone.
        unawaited(refreshUnreadCount());
        return true;
      case Failure(:final statusCode):
        if (index >= 0) {
          _items[index] = _items[index].copyWith(clearReadAt: true);
          _bumpUnread(1);
          notifyListeners();
        }
        if (statusCode == 404) {
          // Gone for this user (expired, unpublished, never theirs):
          // remove it rather than retrying forever.
          if (index >= 0) {
            _items.removeAt(index);
            if (_total > 0) _total--;
            notifyListeners();
            unawaited(_saveCache(_items));
          }
          unawaited(_dropPendingRead(announcement.id));
          unawaited(refreshUnreadCount());
          return false;
        }
        unawaited(_storePendingRead(announcement.id));
        return false;
    }
  }

  /// Delete [announcement] from this user's feed. Optimistic: the row
  /// leaves the list at once and comes back if the server refuses (a 404
  /// means it was already gone - expiry, another device - so that stays
  /// deleted). Returns true when the server confirmed or had already
  /// removed it.
  Future<bool> dismissAnnouncement(Announcement announcement) async {
    _resetForAccount(ApiService.currentUserId);
    final index = _items.indexWhere((a) => a.id == announcement.id);
    Announcement? removed;
    if (index >= 0) {
      removed = _items.removeAt(index);
      if (_total > 0) _total--;
      if (!announcement.isRead) _bumpUnread(-1);
      notifyListeners();
      unawaited(_saveCache(_items));
    }
    final result = await _repo.dismiss(announcement.id);
    if (_disposed) return false;
    switch (result) {
      case Success():
        unawaited(_dropPendingRead(announcement.id));
        unawaited(refreshUnreadCount());
        return true;
      case Failure(:final statusCode):
        if (statusCode == 404) {
          unawaited(refreshUnreadCount());
          return true;
        }
        if (removed != null) {
          _items.insert(index.clamp(0, _items.length), removed);
          _total++;
          if (!announcement.isRead) _bumpUnread(1);
          notifyListeners();
          unawaited(_saveCache(_items));
        }
        return false;
    }
  }

  /// Mark the whole feed read in one request; the badge reconciles with
  /// the server afterwards rather than trusting local arithmetic.
  Future<bool> markAllRead() async {
    _resetForAccount(ApiService.currentUserId);
    final result = await _repo.markAllRead();
    if (_disposed) return false;
    switch (result) {
      case Success():
        final now = DateTime.now().toUtc();
        _items = _items
            .map((a) => a.isRead ? a : a.copyWith(readAt: now))
            .toList();
        _unreadCount = 0;
        _unreadFailed = false;
        notifyListeners();
        unawaited(_saveCache(_items));
        unawaited(refreshUnreadCount());
        return true;
      case Failure():
        return false;
    }
  }

  /// One announcement by id, from the loaded feed - for opening a detail
  /// from a push. The backend remains authoritative for anything not
  /// loaded: callers fetch the feed rather than trusting the payload.
  Announcement? byId(String id) {
    for (final a in _items) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// A push arrived for an announcement: refresh the badge (cheap) and, if
  /// the feed is already loaded, the feed too - the push itself is never
  /// the feed's source of truth.
  void onPushReceived() {
    unawaited(refreshUnreadCount());
    if (_items.isNotEmpty) unawaited(refresh());
  }

  void _bumpUnread(int delta) {
    final current = _unreadCount;
    if (current == null || _unreadFailed) return;
    _unreadCount = (current + delta).clamp(0, 1 << 30);
  }

  Future<void> _retryPendingReads() async {
    final pending = await _loadPendingReads();
    if (pending.isEmpty || _disposed) return;
    var changed = false;
    for (final id in pending.toList()) {
      final result = await _repo.markRead(id);
      if (_disposed) return;
      if (result is Success<AnnouncementRead>) {
        await _dropPendingRead(id);
        final index = _items.indexWhere((a) => a.id == id);
        if (index >= 0 && !_items[index].isRead) {
          _items[index] =
              _items[index].copyWith(readAt: result.data.readAt);
          changed = true;
        }
      } else if (result is Failure<AnnouncementRead> &&
          result.statusCode == 404) {
        // Gone for this user - stop retrying it.
        await _dropPendingRead(id);
      } else {
        // Still failing (offline?): leave the rest for next time.
        break;
      }
    }
    if (changed) notifyListeners();
    unawaited(refreshUnreadCount());
  }

  Future<List<Announcement>> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheScopeFor(_accountId));
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      final items = <Announcement>[];
      for (final e in decoded) {
        if (e is Map<String, dynamic>) {
          final parsed = Announcement.fromJson(e);
          if (parsed != null && !parsed.isExpired) items.add(parsed);
        }
      }
      return items;
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveCache(List<Announcement> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final toStore =
          items.length > 300 ? items.sublist(0, 300) : items;
      await prefs.setString(
          cacheScopeFor(_accountId), jsonEncode(toStore.map((a) => a.toJson()).toList()));
    } catch (_) {}
  }

  Future<List<String>> _loadPendingReads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(pendingReadsScopeFor(_accountId)) ?? [];
    } catch (_) {
      return [];
    }
  }

  Future<void> _storePendingRead(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = pendingReadsScopeFor(_accountId);
      final pending = prefs.getStringList(key) ?? [];
      if (!pending.contains(id)) {
        pending.add(id);
        await prefs.setStringList(key, pending);
      }
    } catch (_) {}
  }

  Future<void> _dropPendingRead(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = pendingReadsScopeFor(_accountId);
      final pending = prefs.getStringList(key) ?? [];
      if (pending.remove(id)) {
        await prefs.setStringList(key, pending);
      }
    } catch (_) {}
  }

  /// The account id this state should track, from the session. Called on
  /// startup, resume and after login - cheap when unchanged.
  static String? get currentAccountId => ApiService.currentUserId;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
