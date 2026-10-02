// One call in the user's call history, as GET /calls/history returns it
// (backend/api/routers/calls.py get_call_history), seen from the user's side.
import '../../../utils/backend_time.dart';

enum CallDirection { incoming, outgoing }

/// The other person on a call. Sent once per person, not once per call.
class CallPeer {
  const CallPeer({required this.id, required this.name, this.photo, this.isOnline = false});

  final String id;
  final String name;

  /// Inline base64, like every profile photo in the app.
  final String? photo;
  final bool isOnline;

  factory CallPeer.fromJson(String id, Map<String, dynamic> j) => CallPeer(
        id: id,
        name: (j['name'] as String?)?.trim() ?? '',
        photo: j['photo'] as String?,
        isOnline: j['is_online'] as bool? ?? false,
      );
}

class CallRecord {
  const CallRecord({
    required this.id,
    required this.listingId,
    required this.listingName,
    required this.buyerId,
    required this.myRole,
    required this.peer,
    required this.direction,
    required this.outcome,
    required this.missed,
    required this.isVideo,
    this.durationSecs,
    this.at,
  });

  final String id;
  final String listingId;
  final String listingName;

  /// The thread's buyer - what a seller needs to open or call the thread.
  final String buyerId;

  /// The user's own side of the deal: "buyer" or "seller".
  final String myRole;
  final CallPeer peer;
  final CallDirection direction;

  /// completed | missed | declined | cancelled, as the call card stores it.
  final String outcome;

  /// Rang the user and nobody picked up. "cancelled" (the caller gave up
  /// first) is missed too, to the person called.
  final bool missed;
  final bool isVideo;
  final int? durationSecs;
  final DateTime? at;

  bool get isOutgoing => direction == CallDirection.outgoing;

  /// "Buyer" or "Seller": which side the other person is on.
  String get peerRoleLabel => myRole == 'seller' ? 'Buyer' : 'Seller';

  /// The name to show - their side of the deal when they have none.
  String get peerDisplayName => peer.name.isEmpty ? peerRoleLabel : peer.name;

  /// What happened, in the user's words.
  String get summary {
    if (missed) return 'Missed';
    if (outcome == 'completed') {
      final d = durationSecs;
      return d == null || d <= 0 ? 'Answered' : formatCallDuration(d);
    }
    if (outcome == 'declined') return isOutgoing ? 'Declined' : 'You declined';
    // An outgoing call nobody answered, cancelled or rung out.
    if (isOutgoing) return outcome == 'cancelled' ? 'Cancelled' : 'No answer';
    return 'Missed';
  }

  static CallRecord? fromJson(Map<String, dynamic> j, Map<String, CallPeer> people) {
    final id = j['id'] as String?;
    final listingId = j['listing_id'] as String?;
    final peerId = j['peer_id'] as String?;
    final buyerId = j['buyer_id'] as String?;
    if (id == null || listingId == null || peerId == null || buyerId == null) return null;
    return CallRecord(
      id: id,
      listingId: listingId,
      listingName: j['listing_name'] as String? ?? '',
      buyerId: buyerId,
      myRole: j['my_role'] == 'seller' ? 'seller' : 'buyer',
      peer: people[peerId] ?? CallPeer(id: peerId, name: ''),
      direction: j['direction'] == 'outgoing' ? CallDirection.outgoing : CallDirection.incoming,
      outcome: (j['outcome'] as String? ?? '').toLowerCase(),
      missed: j['missed'] as bool? ?? false,
      isVideo: j['call_type'] == 'video',
      durationSecs: (j['duration_secs'] as num?)?.toInt(),
      at: parseBackendUtc(j['created_at'] as String?)?.toLocal(),
    );
  }
}

/// One page of history, newest first, and where the next one starts.
class CallHistoryPage {
  const CallHistoryPage({required this.calls, this.nextBefore});

  final List<CallRecord> calls;

  /// Pass back as `before` for the next page; null on the last one.
  final String? nextBefore;

  factory CallHistoryPage.fromJson(Map<String, dynamic> j) {
    final people = <String, CallPeer>{};
    final rawPeople = j['people'];
    if (rawPeople is Map) {
      rawPeople.forEach((id, p) {
        if (id is String && p is Map) {
          people[id] = CallPeer.fromJson(id, p.cast<String, dynamic>());
        }
      });
    }
    final calls = <CallRecord>[];
    for (final c in (j['calls'] as List? ?? const [])) {
      if (c is! Map) continue;
      final record = CallRecord.fromJson(c.cast<String, dynamic>(), people);
      if (record != null) calls.add(record);
    }
    return CallHistoryPage(calls: calls, nextBefore: j['next_before'] as String?);
  }
}

/// 75 -> "1:15", 3725 -> "1:02:05".
String formatCallDuration(int secs) {
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  final s = (secs % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}
