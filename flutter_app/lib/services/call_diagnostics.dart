// BROKA - one call's diagnostics, for Render's logs (CALLING.md, 2026-11-13).
//
// A call that failed left Render with "SDP/ICE relayed" and nothing else:
// what the phone saw - its ICE and peer-connection states, the candidates
// it gathered and received, whether TURN worked, why it gave up - stayed in
// logcat, out of reach without the phone. WebRtcService now reports each of
// those as an event (`diag` frames on the call's socket; the backend logs
// them as `[call-event]` lines, api/core/call_events.py). Events that could
// not go over a live socket - it was down, or the call ended as they
// happened - are posted when the call ends (POST /calls/{room}/events).
//
// What may be reported: state names, counts, candidate TYPES and
// protocols. Never a token, a TURN credential, SDP, or an IP address -
// exception texts are cleaned here, and again by the server.

/// An exception or message, made safe to report: no SDP, addresses or
/// secrets, one line, and short.
String cleanDiagnosticText(Object? value, {int max = 160}) {
  if (value == null) return '';
  var text = value.toString();
  final sdp = RegExp(r'(v=0|\ba=[a-z-]+:|\bcandidate:|\bm=audio|\bm=video|\bc=IN\b)')
      .firstMatch(text);
  if (sdp != null) text = '${text.substring(0, sdp.start).trimRight()} [sdp removed]';
  text = text
      .replaceAll(RegExp(r'\b(token|credential|password|secret)\s*[=:]\s*\S+', caseSensitive: false),
          '[redacted]')
      .replaceAll(RegExp(r'\bbearer\s+\S+', caseSensitive: false), '[redacted]')
      .replaceAll(RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b'), '<ip>')
      .replaceAllMapped(RegExp(r'(?<![0-9a-fA-F:])[0-9a-fA-F:]{3,39}(?![0-9a-fA-F:])'), (m) {
    final s = m.group(0)!;
    final ipv6 = (s.contains('::') || ':'.allMatches(s).length >= 3) &&
        s.contains(RegExp(r'[0-9]'));
    return ipv6 ? '<ip>' : s;
  }).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length > max) text = '${text.substring(0, max - 1)}…';
  return text;
}

/// What an ICE candidate line says about itself, without its address.
class CandidateInfo {
  const CandidateInfo({this.type, this.protocol, this.ufrag});

  /// host | srflx | prflx | relay
  final String? type;

  /// udp | tcp
  final String? protocol;

  /// The ICE session it belongs to (libwebrtc writes it into the line):
  /// which offer or answer, so a candidate for one that has not been
  /// applied yet is not added to the one that has.
  final String? ufrag;

  static CandidateInfo parse(String? candidate) {
    if (candidate == null || candidate.isEmpty) return const CandidateInfo();
    final parts = candidate.split(RegExp(r'\s+'));
    String? after(String key) {
      final i = parts.indexOf(key);
      return i >= 0 && i + 1 < parts.length ? parts[i + 1] : null;
    }

    final protocol = parts.length > 2 ? parts[2].toLowerCase() : null;
    return CandidateInfo(
      type: after('typ'),
      protocol: protocol == 'udp' || protocol == 'tcp' ? protocol : null,
      ufrag: after('ufrag'),
    );
  }
}

/// The audio and video directions an SDP negotiates (`sendrecv`,
/// `recvonly`...; `none` when the section is missing) - whether the call's
/// audio was set up both ways, without any of the SDP itself.
Map<String, String> sdpDirections(String? sdp) {
  final out = {'audio': 'none', 'video': 'none'};
  if (sdp == null) return out;
  String? section;
  for (final line in sdp.split(RegExp(r'\r?\n'))) {
    if (line.startsWith('m=')) {
      section = line.startsWith('m=audio') ? 'audio' : (line.startsWith('m=video') ? 'video' : null);
      if (section != null) out[section] = 'sendrecv'; // the default direction
      continue;
    }
    if (section == null) continue;
    for (final d in const ['sendrecv', 'sendonly', 'recvonly', 'inactive']) {
      if (line == 'a=$d') out[section] = d;
    }
  }
  return out;
}

/// The ICE session (`a=ice-ufrag`) a description belongs to.
String? sdpIceUfrag(String? sdp) {
  if (sdp == null) return null;
  final m = RegExp(r'^a=ice-ufrag:(\S+)', multiLine: true).firstMatch(sdp);
  return m?.group(1);
}

class CallDiagnostics {
  CallDiagnostics({required this.roomId, required this.role});

  final String roomId;

  /// caller | callee
  final String role;

  /// Writes a frame to the call's socket when one is open; false otherwise.
  bool Function(Map<String, dynamic> frame)? sendOverSocket;

  int _seq = 0;
  final List<Map<String, dynamic>> _unsent = [];
  static const maxUnsent = 200;

  /// Candidates gathered here and received from the other phone, by type.
  final Map<String, int> gathered = {};
  final Map<String, int> received = {};

  /// Every event so far, newest last - for tests.
  final List<Map<String, dynamic>> history = [];

  /// One event: the states it happened in, why, and anything else that
  /// says what it was. [terminal] events (the call failing or ending) are
  /// kept for the end-of-call post rather than sent over a socket that is
  /// about to close under them.
  Map<String, dynamic> record(
    String event,
    Map<String, Object?> states, {
    String? reason,
    Object? error,
    Map<String, Object?> extra = const {},
    bool terminal = false,
  }) {
    final e = <String, dynamic>{
      'event': event,
      'seq': ++_seq,
      'client_ts': DateTime.now().toUtc().toIso8601String(),
      ...states,
      if (reason != null) 'reason': reason,
      if (error != null) 'error': cleanDiagnosticText(error),
      for (final entry in extra.entries)
        if (entry.value != null) entry.key: entry.value,
    };
    history.add(e);
    if (history.length > 400) history.removeAt(0);
    if (terminal) {
      _terminal.add(e);
    } else if (!_trySend(e)) {
      _keep(e);
    }
    return e;
  }

  // The call failing or ending: posted at the end, never over the socket.
  final List<Map<String, dynamic>> _terminal = [];

  bool _trySend(Map<String, dynamic> e) {
    final send = sendOverSocket;
    if (send == null) return false;
    try {
      return send({'type': 'diag', 'room_id': roomId, ...e});
    } catch (_) {
      return false;
    }
  }

  void _keep(Map<String, dynamic> e) {
    if (_unsent.length >= maxUnsent) _unsent.removeAt(0);
    _unsent.add(e);
  }

  /// A socket is open again: what waited for one goes over it.
  void flushOverSocket() {
    if (_unsent.isEmpty) return;
    final waiting = List<Map<String, dynamic>>.of(_unsent);
    _unsent.clear();
    for (final e in waiting) {
      if (!_trySend(e)) _keep(e);
    }
  }

  /// What never went over a socket, for the end-of-call post - once.
  List<Map<String, dynamic>> takeUnsent() {
    final out = [..._unsent, ..._terminal];
    _unsent.clear();
    _terminal.clear();
    return out;
  }

  void countGathered(String? type) {
    final t = type ?? 'unknown';
    gathered[t] = (gathered[t] ?? 0) + 1;
  }

  void countReceived(String? type) {
    final t = type ?? 'unknown';
    received[t] = (received[t] ?? 0) + 1;
  }
}
