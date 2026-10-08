// BROKA - the call this phone is on, and the calls it is done with.
//
// Reported from phones (2026-10-07): "multiple calls arriving at the same
// time even when another call is going on / ringing". Nothing in the app
// knew it was on a call. Every path that can ring - the inbox sweep every
// 7s, a push in the foreground, a push to a closed app, a tap on a
// notification - rang for whatever the server reported, so:
//
//   * a call the user had just accepted rang again (and posted a fresh
//     Accept/Decline notification) while it was still connecting, because
//     the server reports it as ringing until the callee's socket joins -
//     and Decline on that notification hung up the live call;
//   * a second call rang over a call in progress, and answering it opened a
//     second call screen over the first;
//   * a tap on a notification for the call already on screen opened that
//     call a second time.
//
// The call screen registers its room here (begin/end), Accept marks it
// answered, and NotificationService.showIncomingCall - the one funnel every
// ringing path goes through - asks [shouldRing] first. The room is also
// written to preferences, because a push to a closed or backgrounded app is
// handled in a separate isolate that shares nothing else with this one.

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

class ActiveCall {
  ActiveCall._();
  static final ActiveCall instance = ActiveCall._();

  static const String _prefsKey = 'active_call_v1';

  /// How long the saved call counts as current without being refreshed.
  /// The screen refreshes it every [_keepAliveEvery]; a call screen that
  /// died with the process stops refreshing, and after this the background
  /// isolate stops treating the phone as busy.
  static const Duration _fresh = Duration(seconds: 90);
  static const Duration _keepAliveEvery = Duration(seconds: 30);

  String? _roomId;
  bool _answered = false;
  // Rooms answered, declined or ended on this phone: never rung again.
  final Set<String> _settled = <String>{};
  Timer? _keepAlive;

  /// The room whose call screen is open, if any.
  String? get roomId => _roomId;

  /// Whether that call is under way - the user placed it or accepted it -
  /// rather than still ringing on its screen.
  bool get answered => _answered;

  bool get onCall => _roomId != null;

  bool isSettled(String roomId) => _settled.contains(roomId);

  /// Whether an incoming call for [roomId] may ring now.
  ///
  /// Never one this phone is done with, never the call already on screen,
  /// and never over a call that is under way. A different room while the
  /// screen is still only ringing is allowed: the server answers "busy" to a
  /// second caller, so a new room in that state is the same caller dialling
  /// again, and the earlier ring is being taken down.
  bool shouldRing(String roomId) {
    if (roomId.isEmpty || _settled.contains(roomId)) return false;
    final active = _roomId;
    if (active == null) return true;
    if (active == roomId) return false;
    return !_answered;
  }

  /// The call screen for [roomId] opened. [answered] is true for the
  /// caller, and for a callee who already accepted (from a notification).
  void begin(String roomId, {required bool answered}) {
    if (roomId.isEmpty) return;
    _roomId = roomId;
    _answered = answered;
    if (answered) _settled.add(roomId);
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(_keepAliveEvery, (_) => unawaited(_persist()));
    unawaited(_persist());
  }

  /// The callee accepted the call on screen.
  void markAnswered(String roomId) {
    _settled.add(roomId);
    if (_roomId != roomId) return;
    _answered = true;
    unawaited(_persist());
  }

  /// This phone is done with [roomId] (declined it, or it ended) without it
  /// necessarily having had a screen.
  void settle(String roomId) {
    if (roomId.isNotEmpty) _settled.add(roomId);
  }

  /// The call screen for [roomId] closed.
  void end(String roomId) {
    _settled.add(roomId);
    if (_roomId != roomId) return;
    _roomId = null;
    _answered = false;
    _keepAlive?.cancel();
    _keepAlive = null;
    unawaited(_clearPersisted());
  }

  Future<void> _persist() async {
    final room = _roomId;
    if (room == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey,
          '$room|${DateTime.now().millisecondsSinceEpoch}|${_answered ? 1 : 0}');
    } catch (_) {}
  }

  Future<void> _clearPersisted() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_prefsKey);
    } catch (_) {}
  }

  /// The call this phone is on, as last saved by the app's main isolate -
  /// for the FCM background isolate, which cannot see [instance]'s state.
  /// Null when there is none, or the saved one has gone stale.
  static Future<({String roomId, bool answered})?> saved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return null;
      final parts = raw.split('|');
      if (parts.length != 3) return null;
      final at = DateTime.fromMillisecondsSinceEpoch(int.tryParse(parts[1]) ?? 0);
      if (DateTime.now().difference(at) > _fresh) return null;
      return (roomId: parts[0], answered: parts[2] == '1');
    } catch (_) {
      return null;
    }
  }

  /// Whether a call for [roomId] may ring, judged from the saved state -
  /// the background isolate's version of [shouldRing].
  static Future<bool> savedAllowsRinging(String roomId) async {
    final current = await saved();
    if (current == null) return true;
    if (current.roomId == roomId) return false;
    return !current.answered;
  }

  /// Forget everything - for tests, and sign-out.
  void reset() {
    _roomId = null;
    _answered = false;
    _settled.clear();
    _keepAlive?.cancel();
    _keepAlive = null;
  }
}
