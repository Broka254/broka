// BROKA - Message Sync Service
//
// Brings this phone every message sent to it while it was offline - no
// signal, switched off, BROKA closed - and tells the server only once each
// one is stored.
//
// Before this, a message reached the phone three ways: the conversation's
// socket (only while that very chat was open), a push (only if one could be
// delivered - an APK without Firebase, a phone that was off for longer than
// Firebase keeps it, or a push that failed got nothing), and the Inbox sweep,
// which fetched the inbox list and then told the server "delivered" for the
// whole thread before a single message had been fetched. A conversation that
// was never opened was never on the phone at all, and the sender's double
// tick could be a guess.
//
// How it works:
//
//   * The server keeps, per recipient, which messages their phone has not
//     acknowledged (backend api/models/message_delivery.py). GET
//     /negotiate/sync hands them out, every conversation, oldest first, a
//     page at a time; this service stores each page in the conversation's
//     own on-device cache (the scope its screen reads, see [syncScopeFor]) -
//     or hands it to the conversation's screen if it is open ([attach]) -
//     and only then acknowledges it (POST /negotiate/sync/ack). Asking is
//     never delivery: what is not acknowledged is handed out again next
//     time, so a sync cut off half way, or run twice, loses and duplicates
//     nothing (the caches keep each message once, by its server id).
//   * It runs when the user signs in or the app starts (GlobalPollerService
//     .start), returns to the foreground (catchUp), the network comes back
//     (ConnectivityMonitor, and the Inbox sweep reaching the server after
//     failing), a conversation opens, a message push arrives with the app
//     in front, and the Inbox shows something unread it has not seen.
//   * One sync at a time: a request while one runs queues one more pass
//     after it, for what arrived meanwhile.
//   * A failed sync is tried again while the app is in front - 2s, 5s,
//     15s, 30s, then every minute - and the next request says which try it
//     is and why the last one failed, so the API log shows both.
//   * A server deployed before the sync answers 404: the app keeps its old
//     behaviour (the Inbox sweep's own receipts) and asks again later.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'local_chat_store.dart';

/// Takes one conversation's newly synced messages, for a screen that has the
/// conversation open (and so owns its cache). Returns once they are on
/// screen and saved; throws if it could not take them.
typedef SyncedMessagesSink = Future<void> Function(
    List<Map<String, dynamic>> messages);

enum SyncOutcome {
  /// Everything waiting was stored and acknowledged.
  completed,

  /// Something failed; a retry is scheduled while the app is in front.
  failed,

  /// The server has no offline sync.
  unsupported,

  /// Not signed in, or signed out during the sync.
  skipped,
}

/// The on-device cache scope a synced message belongs in - the one its
/// screen reads: NegotiationScreen keeps a direct conversation under
/// `direct_<listing id | store:<id>>_<buyer>`, NegotiateScreen keeps Zeno's
/// room under `ai_<listing>_<buyer>`. Null for a message that names no
/// conversation.
String? syncScopeFor(Map<String, dynamic> m) {
  String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
  final buyer = s(m['buyer_id']);
  final listing = s(m['listing_id']);
  final store = s(m['store_id']);
  if (buyer == null) return null;
  if (m['room'] == 'zeno') {
    return listing == null ? null : 'ai_${listing}_$buyer';
  }
  final thread = store != null && listing == null ? 'store:$store' : listing;
  return thread == null ? null : 'direct_${thread}_$buyer';
}

/// Fields the sync adds to each message to say where it belongs; not part
/// of the message as the chat stores it.
const _routingKeys = {
  'listing_id', 'store_id', 'buyer_id', 'thread_type', 'my_role', 'room',
  'delivery_status',
};

class MessageSyncService {
  MessageSyncService._();
  static final MessageSyncService instance = MessageSyncService._();

  /// Waits between failed syncs while the app is in front; the last one
  /// repeats.
  @visibleForTesting
  static List<Duration> retryDelays = const [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
  ];

  @visibleForTesting
  static int pageSize = 100;

  /// A pass stops after this many pages (and the next one carries on): a
  /// phone back after weeks away gets its messages in bounded pieces.
  @visibleForTesting
  static int maxPagesPerPass = 50;

  /// How long an older server's "no sync here" is believed before asking
  /// again - the backend may have been deployed since.
  @visibleForTesting
  static Duration unsupportedRecheck = const Duration(minutes: 10);

  bool _running = false;
  bool get isRunning => _running;

  /// Whether the server has the offline sync: null until it has answered.
  bool? get serverSupportsSync => _supported;
  bool? _supported;
  DateTime? _unsupportedSince;

  /// The app is on screen (GlobalPollerService passes main.dart's
  /// lifecycle on). Failed syncs are retried only then: in the background
  /// the next resume syncs anyway, and a timer would only cost battery.
  bool get appInForeground => _appInForeground;
  bool _appInForeground = true;
  set appInForeground(bool value) {
    final back = value && !_appInForeground;
    _appInForeground = value;
    if (!value) {
      _retryTimer?.cancel();
      _retryTimer = null;
    } else if (back && _failures > 0 && _inFlight == null) {
      _scheduleRetry(_lastTrigger ?? 'resume');
    }
  }

  /// Called after a sync stored something new (wired to the Inbox sweep's
  /// nudge: the badge and the list catch up at once).
  VoidCallback? onSynced;

  Future<SyncOutcome>? _inFlight;
  String? _queuedTrigger;
  String? _lastTrigger;
  int _failures = 0;
  String? _lastError;
  Timer? _retryTimer;
  final Map<String, SyncedMessagesSink> _sinks = {};
  final StreamController<Set<String>> _updates =
      StreamController<Set<String>>.broadcast();

  /// The cache scopes a sync has just written to.
  Stream<Set<String>> get updates => _updates.stream;

  @visibleForTesting
  int get failures => _failures;

  @visibleForTesting
  bool get retryScheduled => _retryTimer != null;

  final Random _random = Random();

  /// Signed in: syncs may run.
  void start() {
    _running = true;
    _failures = 0;
    _lastError = null;
  }

  /// Signed out: nothing runs, nothing is retried, and the next account
  /// starts afresh.
  void stop() {
    _running = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _queuedTrigger = null;
    _failures = 0;
    _lastError = null;
    _supported = null;
    _unsupportedSince = null;
  }

  /// [scope]'s conversation is open: its screen takes what the sync brings
  /// for it, instead of the sync writing the cache under it (the screen
  /// rewrites that cache from what it shows, and would drop the message).
  void attach(String scope, SyncedMessagesSink sink) => _sinks[scope] = sink;

  /// Only [sink]'s own registration goes: a screen for the same
  /// conversation opened since keeps its own. (`==`, not identical: two
  /// tear-offs of one method are equal, not identical.)
  void detach(String scope, SyncedMessagesSink sink) {
    if (_sinks[scope] == sink) _sinks.remove(scope);
  }

  /// Fetch and store everything waiting, then acknowledge it. Safe to call
  /// any time and any number of times.
  Future<SyncOutcome> sync({required String trigger}) {
    if (!_running || ApiService.currentUserId == null) {
      return Future.value(SyncOutcome.skipped);
    }
    if (_supported == false) {
      final since = _unsupportedSince;
      if (since != null &&
          DateTime.now().difference(since) < unsupportedRecheck) {
        return Future.value(SyncOutcome.unsupported);
      }
    }
    final running = _inFlight;
    if (running != null) {
      // Whatever prompted this may be newer than the page in flight.
      _queuedTrigger ??= trigger;
      return running;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    final future = _pass(trigger);
    _inFlight = future;
    unawaited(future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
      final again = _queuedTrigger;
      _queuedTrigger = null;
      if (again != null && _running) unawaited(sync(trigger: again));
    }));
    return future;
  }

  Future<SyncOutcome> _pass(String trigger) async {
    _lastTrigger = trigger;
    final account = ApiService.currentUserId;
    final syncId = _newSyncId();
    final attempt = _failures + 1;
    final previousError = _lastError;
    var page = 1;
    var stored = 0;
    String? after;
    _log('OFFLINE_SYNC_STARTED',
        'trigger=$trigger attempt=$attempt sync_id=$syncId'
        '${previousError != null ? ' previous_error=$previousError' : ''}');
    try {
      while (true) {
        final answer = await ApiService.fetchSyncPage(
          after: after,
          limit: pageSize,
          trigger: trigger,
          attempt: attempt,
          syncId: syncId,
          page: page,
          previousError: page == 1 ? previousError : null,
        );
        if (!_stillFor(account)) return SyncOutcome.skipped;
        if (answer.unsupported) {
          _supported = false;
          _unsupportedSince = DateTime.now();
          _failures = 0;
          _lastError = null;
          _log('OFFLINE_SYNC_UNSUPPORTED', 'status=${answer.status ?? '-'}');
          return SyncOutcome.unsupported;
        }
        if (!answer.ok) {
          return _failed(trigger, answer.error ?? 'http_${answer.status}');
        }
        _supported = true;
        final last = !answer.hasMore || page >= maxPagesPerPass;
        if (answer.messages.isNotEmpty) {
          final kept = await _store(answer.messages);
          if (!_stillFor(account)) return SyncOutcome.skipped;
          if (kept.stored.isNotEmpty) {
            final ack = await ApiService.acknowledgeMessages(kept.stored,
                source: 'sync', syncId: syncId, finalPage: !answer.hasMore);
            if (!_stillFor(account)) return SyncOutcome.skipped;
            if (!ack.ok) {
              // Stored, not acknowledged: the server hands them out again
              // next time and the caches keep each message once.
              return _failed(trigger, ack.error ?? 'ack_http_${ack.status}');
            }
            stored += kept.stored.length;
          }
          if (kept.failed > 0) {
            // Could not be stored, so not acknowledged: they come back on
            // the next pass, which runs soon, as for any failure.
            return _failed(trigger, 'store_failed');
          }
        }
        if (last) {
          // More than one pass holds: carry on in another.
          if (answer.hasMore) _queuedTrigger ??= trigger;
          break;
        }
        after = answer.nextCursor;
        page++;
      }
    } catch (e) {
      return _failed(trigger, '${e.runtimeType}');
    }
    _failures = 0;
    _lastError = null;
    _log('OFFLINE_SYNC_COMPLETED',
        'trigger=$trigger sync_id=$syncId pages=$page stored=$stored');
    if (stored > 0) onSynced?.call();
    return SyncOutcome.completed;
  }

  bool _stillFor(String? account) =>
      _running && account != null && ApiService.currentUserId == account;

  /// Puts each message where its screen will find it. `stored` are the ids
  /// now safely on the phone - the only ones acknowledged; `failed` counts
  /// those that could not be saved.
  Future<({List<String> stored, int failed})> _store(
      List<Map<String, dynamic>> messages) async {
    final byScope = <String, List<Map<String, dynamic>>>{};
    for (final m in messages) {
      final id = m['id'];
      final scope = syncScopeFor(m);
      if (id is! String || id.isEmpty || scope == null) {
        // Names no conversation this app can show: left unacknowledged.
        _log('OFFLINE_SYNC_UNROUTABLE', 'message=${id is String ? id : '-'}');
        continue;
      }
      byScope.putIfAbsent(scope, () => []).add(
          {for (final e in m.entries) if (!_routingKeys.contains(e.key)) e.key: e.value});
    }
    final stored = <String>[];
    var failed = 0;
    final written = <String>{};
    for (final entry in byScope.entries) {
      final ids = [for (final m in entry.value) m['id'] as String];
      var ok = false;
      final sink = _sinks[entry.key];
      if (sink != null) {
        try {
          await sink(entry.value);
          ok = true;
        } catch (_) {
          // The screen closed under us: store it the ordinary way.
        }
      }
      if (!ok) ok = await LocalChatStore.mergeMessages(entry.key, entry.value);
      if (ok) {
        stored.addAll(ids);
        written.add(entry.key);
        for (final id in ids) {
          _log('MESSAGE_SYNCED_TO_CLIENT', 'message=$id scope=${entry.key}');
        }
      } else {
        failed += ids.length;
        _log('OFFLINE_SYNC_STORE_FAILED',
            'scope=${entry.key} messages=${ids.length}');
      }
    }
    if (written.isNotEmpty && !_updates.isClosed) _updates.add(written);
    return (stored: stored, failed: failed);
  }

  SyncOutcome _failed(String trigger, String reason) {
    _failures++;
    // A word, not a message: the exception's type or an HTTP status.
    _lastError = reason.replaceAll(RegExp(r'[^A-Za-z0-9_.:\-]'), '');
    final delay = _scheduleRetry(trigger);
    _log('OFFLINE_SYNC_FAILED',
        'trigger=$trigger attempt=$_failures reason=$_lastError'
        ' retry_in_ms=${delay?.inMilliseconds ?? '-'}');
    return SyncOutcome.failed;
  }

  Duration? _scheduleRetry(String trigger) {
    if (!_running || !_appInForeground || _failures <= 0) return null;
    final delay =
        retryDelays[min(_failures - 1, retryDelays.length - 1)];
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(sync(trigger: 'retry_$trigger'));
    });
    return delay;
  }

  String _newSyncId() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${_random.nextInt(1 << 32).toRadixString(36)}';

  static void _log(String event, String details) {
    debugPrint('[Sync] $event at=${DateTime.now().toUtc().toIso8601String()} $details');
  }

  /// Test seam: forget everything between tests.
  @visibleForTesting
  void reset() {
    stop();
    _sinks.clear();
    _inFlight = null;
    _lastTrigger = null;
    _appInForeground = true;
    onSynced = null;
  }
}
