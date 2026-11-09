// test/support/fake_webrtc.dart
//
// The native side of a call, in memory: a peer connection, its
// transceivers, a microphone. Only what WebRtcService touches is
// implemented; anything else reaches noSuchMethod and fails loudly, so a
// code path a test didn't expect shows up as a failure rather than a
// silent default.
//
// The peer connection behaves as unified-plan WebRTC does where the call
// code depends on it: a remote offer applied to a connection with no
// tracks creates a receive-only audio transceiver; addTrack before the
// offer creates a send-and-receive one that the offer then uses.
import 'package:flutter_webrtc/flutter_webrtc.dart';

class FakeTrack extends MediaStreamTrack {
  FakeTrack(this._id, this._kind);

  final String _id;
  final String _kind;
  bool _enabled = true;
  bool stopped = false;

  @override
  String? get id => _id;

  @override
  String? get label => _id;

  @override
  String? get kind => _kind;

  @override
  bool get enabled => _enabled;

  @override
  set enabled(bool b) => _enabled = b;

  @override
  bool? get muted => false;

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeStream extends MediaStream {
  FakeStream(this.tracks, {String id = 'local'}) : super(id, 'test');

  final List<FakeTrack> tracks;

  @override
  bool? get active => true;

  @override
  Future<void> getMediaTracks() async {}

  @override
  Future<void> addTrack(MediaStreamTrack track, {bool addToNative = true}) async {}

  @override
  Future<void> removeTrack(MediaStreamTrack track, {bool removeFromNative = true}) async {}

  @override
  List<MediaStreamTrack> getTracks() => List<MediaStreamTrack>.of(tracks);

  @override
  List<MediaStreamTrack> getAudioTracks() =>
      [for (final t in tracks) if (t.kind == 'audio') t];

  @override
  List<MediaStreamTrack> getVideoTracks() =>
      [for (final t in tracks) if (t.kind == 'video') t];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSender extends RTCRtpSender {
  FakeSender(this._track);

  MediaStreamTrack? _track;

  @override
  MediaStreamTrack? get track => _track;

  @override
  String get senderId => 'sender-${identityHashCode(this)}';

  @override
  Future<void> replaceTrack(MediaStreamTrack? track) async {
    _track = track;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeReceiver extends RTCRtpReceiver {
  FakeReceiver(this._track);

  final MediaStreamTrack _track;

  @override
  MediaStreamTrack? get track => _track;

  @override
  String get receiverId => 'receiver-${identityHashCode(this)}';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTransceiver extends RTCRtpTransceiver {
  FakeTransceiver(this._sender, this.direction, {String kind = 'audio'})
      : _receiver = FakeReceiver(FakeTrack('remote-$kind', kind));

  final FakeSender _sender;
  final FakeReceiver _receiver;
  TransceiverDirection direction;

  @override
  RTCRtpSender get sender => _sender;

  @override
  RTCRtpReceiver get receiver => _receiver;

  @override
  String get mid => '0';

  @override
  Future<TransceiverDirection> getDirection() async => direction;

  @override
  Future<void> setDirection(TransceiverDirection direction) async {
    this.direction = direction;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakePeerConnection extends RTCPeerConnection {
  final List<FakeTransceiver> transceivers = [];
  final List<RTCIceCandidate> candidates = [];
  RTCSessionDescription? localDescription;
  RTCSessionDescription? remoteDescription;
  bool closed = false;
  int _offers = 0;

  /// The direction each transceiver had when the last answer was made -
  /// what that answer told the other side.
  List<TransceiverDirection> answeredDirections = const [];

  @override
  Future<RTCSessionDescription> createOffer(
      [Map<String, dynamic> constraints = const {}]) async {
    _offers++;
    return RTCSessionDescription('v=0 offer $_offers ${identityHashCode(this)}', 'offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer(
      [Map<String, dynamic> constraints = const {}]) async {
    answeredDirections = [for (final t in transceivers) t.direction];
    return RTCSessionDescription('v=0 answer ${identityHashCode(this)}', 'answer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    localDescription = description;
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    remoteDescription = description;
    // An offer's audio, on a connection without a microphone track: a
    // receive-only transceiver, as unified-plan WebRTC makes.
    if (description.type == 'offer' && transceivers.isEmpty) {
      transceivers.add(FakeTransceiver(FakeSender(null), TransceiverDirection.RecvOnly));
    }
  }

  @override
  Future<RTCRtpSender> addTrack(MediaStreamTrack track, [MediaStream? stream]) async {
    final sender = FakeSender(track);
    transceivers.add(FakeTransceiver(sender, TransceiverDirection.SendRecv,
        kind: track.kind ?? 'audio'));
    return sender;
  }

  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async =>
      List<RTCRtpTransceiver>.of(transceivers);

  @override
  Future<List<RTCRtpSender>> getSenders() async =>
      [for (final t in transceivers) t.sender];

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    candidates.add(candidate);
  }

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async => [];

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> dispose() async {}

  /// What the native side reports as the connection comes up (or doesn't).
  void reportState(RTCPeerConnectionState state) => onConnectionState?.call(state);

  /// The other side's audio arriving.
  FakeTrack deliverRemoteAudio() {
    final track = FakeTrack('remote-audio', 'audio');
    onTrack?.call(RTCTrackEvent(
        streams: [FakeStream([track], id: 'remote')], track: track));
    return track;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
