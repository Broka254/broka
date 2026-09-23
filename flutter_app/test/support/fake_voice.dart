// test/support/fake_voice.dart
//
// The three seams a voice test cannot have for real - a microphone, a
// WebSocket, and a vendor's frames - in one place, so the Zeno voice tests and
// the provider/failover tests drive the SAME fakes.
//
// These deliberately emit the vendors' real frame shapes rather than a
// convenient shorthand. A change to the parsing that would break on a live
// Deepgram `Results` or AssemblyAI `Turn` therefore breaks here too, which is
// the only reason a fake is worth having.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A WebSocket that never leaves the process.
class FakeSocket implements WebSocketChannel {
  FakeSocket({Object? handshakeError, this.hangs = false})
      : _handshakeError = handshakeError {
    _sink.onAdd = (data) {
      if (data is Uint8List) {
        sentBinary.add(data);
      } else if (data is String) {
        sentText.add(data);
      }
    };
    _sink.onClose = () => closed = true;
  }

  final _incoming = StreamController<dynamic>.broadcast();
  final _sink = FakeSink();

  final List<Uint8List> sentBinary = [];
  final List<String> sentText = [];
  bool closed = false;

  @override
  int? closeCode;
  @override
  String? closeReason;

  Object? _handshakeError;

  /// The handshake that never answers: no accept, no refusal, no close.
  ///
  /// This is the shape of the bug this whole timeout layer exists for - a
  /// socket a proxy or a dead radio swallows, where every other fake would
  /// have produced an error the code already handled.
  final bool hangs;

  /// The handshake result. This is what "the provider accepted this
  /// connection" means now - a service waits for it before it opens the
  /// microphone, so a fake that never resolves it is a fake that never
  /// connects.
  ///
  /// Built fresh on each read rather than handed out from a Completer that
  /// setUp completed. A Completer resolved outside a testWidgets body
  /// schedules its callbacks in the zone it was completed in, and the
  /// FakeAsync zone a widget test runs in never drains that queue - so
  /// `await channel.ready` would deadlock the whole test. `Future.value`
  /// resolves in the caller's zone, which is the one being pumped.
  @override
  Future<void> get ready {
    if (hangs) return Completer<void>().future;
    return _handshakeError == null
        ? Future<void>.value()
        : Future<void>.error(_handshakeError!);
  }

  /// Refuse the upgrade. Set before the session starts.
  void failHandshake(Object error) => _handshakeError = error;

  /// Close from the far end, the way a provider or a proxy does.
  void closeWith({int? code, String? reason}) {
    closeCode = code;
    closeReason = reason;
    if (!_incoming.isClosed) _incoming.close();
  }

  void emit(Map<String, dynamic> event) => emitRaw(jsonEncode(event));

  void emitRaw(String raw) {
    if (!_incoming.isClosed) _incoming.add(raw);
  }

  /// Text frames decoded back to maps, for asserting on control messages.
  List<Map<String, dynamic>> get sentJson => [
        for (final t in sentText)
          if (jsonDecode(t) case final Map<String, dynamic> m) m,
      ];

  @override
  Stream get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSink implements WebSocketSink {
  void Function(dynamic)? onAdd;
  void Function()? onClose;

  @override
  void add(dynamic data) => onAdd?.call(data);

  @override
  Future close([int? closeCode, String? closeReason]) async => onClose?.call();

  @override
  Future addStream(Stream stream) async {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future get done async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRecorder implements AudioRecorder {
  FakeRecorder({
    this.permitted = true,
    this.failToStart = false,
    this.hangsOnStart = false,
  });

  final bool permitted;

  /// startStream never returns - a wedged platform channel, which throws
  /// nothing and answers nothing.
  final bool hangsOnStart;

  /// Permission granted, recorder still will not open - another app holding
  /// the microphone, a platform channel failure, a device with no input.
  final bool failToStart;

  final _audio = StreamController<Uint8List>.broadcast();
  bool stopped = false;
  bool cancelled = false;
  bool running = false;
  int startCount = 0;

  void emit(Uint8List chunk) {
    if (!_audio.isClosed) _audio.add(chunk);
  }

  @override
  Future<bool> hasPermission({bool request = true}) async => permitted;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    // Both vendors take 16 kHz mono PCM16, and the service must ask for
    // exactly that - a configuration drift here is a silent transcription
    // failure in production.
    expect(config.encoder, AudioEncoder.pcm16bits);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
    if (failToStart) throw StateError('recorder unavailable');
    if (hangsOnStart) return Completer<Stream<Uint8List>>().future;
    startCount++;
    running = true;
    return _audio.stream;
  }

  @override
  Future<String?> stop() async {
    stopped = true;
    running = false;
    return null;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    running = false;
  }

  @override
  Future<void> dispose() async {
    running = false;
    if (!_audio.isClosed) await _audio.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── Vendor frame shapes ──────────────────────────────────────────────────────

/// A Deepgram `Results` frame, in the shape the real service sends.
Map<String, dynamic> deepgramResults(String text,
        {required bool isFinal, bool speechFinal = false}) =>
    {
      'type': 'Results',
      'is_final': isFinal,
      'speech_final': speechFinal,
      'channel': {
        'alternatives': [
          {'transcript': text, 'confidence': 0.98}
        ]
      },
    };

/// An AssemblyAI Universal Streaming `Turn`.
///
/// `transcript` carries only finalised words and `words` carries the live
/// tail, which is why the service prefers the array: that is where the text
/// that makes the card feel responsive actually lives.
Map<String, dynamic> assemblyTurn(
  String text, {
  required int order,
  bool endOfTurn = false,
  bool formatted = false,
}) {
  final words = [
    for (final w in text.split(' '))
      if (w.isNotEmpty)
        {
          'text': w,
          'word_is_final': endOfTurn,
          'start': 0,
          'end': 100,
          'confidence': 0.97,
        }
  ];
  return {
    'type': 'Turn',
    'turn_order': order,
    'end_of_turn': endOfTurn,
    'turn_is_formatted': formatted,
    'end_of_turn_confidence': endOfTurn ? 0.91 : 0.2,
    'transcript': endOfTurn ? text : '',
    'words': words,
  };
}

/// 16 kHz mono PCM16: one millisecond is 32 bytes.
Uint8List pcmOfMs(int ms, {int amplitude = 4000}) {
  final samples = ms * 16;
  final bytes = Uint8List(samples * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    view.setInt16(i * 2, amplitude, Endian.little);
  }
  return bytes;
}
