// BROKA - Ringback Service
//
// What the caller hears while the other person's phone is ringing: the
// "ring-ring... ring-ring" a phone network plays back down the line. The
// call screen said "Ringing…" and was otherwise silent, so the caller held
// a quiet phone to their ear with no sign the call had reached anyone.
//
// Played only once the callee's phone has acknowledged the call (the
// server's `callee_ringing`), never on "Calling…": the tone means their
// phone is ringing, as it does on a phone call. Stopped the moment they
// answer, decline, or the call ends.
//
// assets/audio/ringback.wav is one cycle of the double ring (400+450 Hz,
// 0.4s on, 0.2s off, 0.4s on, 2s off) at the telephone band's 8 kHz,
// looped. It plays on the voice-call stream, like the call it belongs to:
// through the earpiece, or the speaker when the call is on speaker.
//
// Android only. On iOS the audio session belongs to CallKit and WebRTC,
// and a player taking it over to play this would cut the microphone.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class RingbackService {
  RingbackService._();
  static final RingbackService instance = RingbackService._();

  static const String asset = 'audio/ringback.wav';

  AudioPlayer? _player;
  bool _playing = false;
  // Bumped by stop(): a start() still loading the tone when the call was
  // answered must not begin playing after it.
  int _generation = 0;

  bool get isPlaying => _playing;

  /// Whether this platform plays a ringback at all (see the file comment).
  static bool get supported => debugSupported ?? (!kIsWeb && Platform.isAndroid);

  /// Overrides [supported] - for tests, which run on neither platform.
  @visibleForTesting
  static bool? debugSupported;

  /// [speakerOn]: the route the call is on. audioplayers applies a
  /// player's audio mode and speaker flag to the whole phone, so they must
  /// be the call's own - its defaults (normal mode, earpiece) would take
  /// the call out of communication mode and off the speaker.
  Future<void> start({required bool speakerOn}) async {
    if (_playing || !supported) return;
    _playing = true;
    final gen = ++_generation;
    try {
      final player = _player ??= AudioPlayer(playerId: 'broka_ringback');
      await player.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          // The call's own stream: earpiece or speaker, whichever the call
          // is on, at call volume.
          usageType: AndroidUsageType.voiceCommunication,
          contentType: AndroidContentType.sonification,
          audioMode: AndroidAudioMode.inCommunication,
          isSpeakerphoneOn: speakerOn,
          stayAwake: false,
          // Taking audio focus would duck or pause WebRTC's own audio.
          audioFocus: AndroidAudioFocus.none,
        ),
      ));
      await player.setReleaseMode(ReleaseMode.loop);
      if (gen != _generation) return;
      await player.play(AssetSource(asset), volume: 1.0);
      // stop() may have run while play() was starting.
      if (gen != _generation) await player.stop();
    } catch (e) {
      // A caller without a ringback still has the "Ringing…" on screen.
      debugPrint('[Ringback] could not play: $e');
      if (gen == _generation) _playing = false;
    }
  }

  Future<void> stop() async {
    _generation++;
    if (!_playing) return;
    _playing = false;
    try {
      await _player?.stop();
    } catch (_) {}
  }
}
