// BROKA - Ringback Service
//
// What the caller hears while the call is put through - two sounds, as
// WhatsApp and every phone network play them:
//
//   * "Calling…": a soft pip every two seconds. The server has the call
//     and has pushed it to the other person's phone, which has not said
//     it is ringing yet.
//   * "Ringing…": the "ring-ring... ring-ring" a phone network plays back
//     down the line, once a phone of theirs says it is ringing (the
//     server's `callee_ringing`).
//
// 2026-11-11: the ring played from the moment the call was placed
// (2026-10-12), so the caller heard ringing whether or not anything was -
// a phone that was off, offline or could not get the push sounded exactly
// like one ringing in someone's pocket. It was played early because a
// phone answering from a closed app often never reported ringing; that
// report is now retried (NotificationService.acknowledgeIncomingCall) and
// kept by the server however the call's state is written, and the caller
// is never left in silence: the pip plays until it comes. Stopped the
// moment they answer, decline, or the call ends.
//
// assets/audio/ringback.wav is one cycle of the double ring (400+450 Hz,
// 0.4s on, 0.2s off, 0.4s on, 2s off), assets/audio/calling.wav one pip
// (520 Hz, 0.16s, then 1.84s of quiet), both at the telephone band's
// 8 kHz, looped. They play on the voice-call stream, like the call they
// belong to: through the earpiece, or the speaker when the call is on
// speaker.
//
// Android only. On iOS the audio session belongs to CallKit and WebRTC,
// and a player taking it over to play this would cut the microphone.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Which of the caller's two sounds is playing (see the file comment).
enum CallerTone {
  /// "Calling…": the call has not reached a phone of theirs yet.
  calling,

  /// "Ringing…": a phone of theirs is ringing.
  ringback,
}

class RingbackService {
  RingbackService._();
  static final RingbackService instance = RingbackService._();

  static const String asset = 'audio/ringback.wav';
  static const String callingAsset = 'audio/calling.wav';

  AudioPlayer? _player;
  bool _playing = false;
  CallerTone? _tone;
  // Bumped by stop(): a start() still loading the tone when the call was
  // answered must not begin playing after it.
  int _generation = 0;

  bool get isPlaying => _playing;

  /// The sound playing now, or null.
  CallerTone? get tone => _playing ? _tone : null;

  /// Whether this platform plays a ringback at all (see the file comment).
  static bool get supported => debugSupported ?? (!kIsWeb && Platform.isAndroid);

  /// Overrides [supported] - for tests, which run on neither platform.
  @visibleForTesting
  static bool? debugSupported;

  /// Play [tone], in place of the other one if that is playing.
  ///
  /// [speakerOn]: the route the call is on. audioplayers applies a
  /// player's audio mode and speaker flag to the whole phone, so they must
  /// be the call's own - its defaults (normal mode, earpiece) would take
  /// the call out of communication mode and off the speaker.
  Future<void> start({required bool speakerOn, CallerTone tone = CallerTone.ringback}) async {
    if (!supported) return;
    if (_playing && _tone == tone) return;
    final switching = _playing;
    _playing = true;
    _tone = tone;
    // Also stops a start of the other tone still loading.
    final gen = ++_generation;
    try {
      final player = _player ??= AudioPlayer(playerId: 'broka_ringback');
      if (switching) await player.stop();
      if (gen != _generation) return;
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
      await player.play(AssetSource(tone == CallerTone.calling ? callingAsset : asset),
          volume: tone == CallerTone.calling ? 0.7 : 1.0);
      // stop() may have run while play() was starting. (Not when the other
      // tone took over meanwhile: it is the player's sound now.)
      if (gen != _generation && !_playing) await player.stop();
    } catch (e) {
      // A caller without the sound still has "Calling…" or "Ringing…" on
      // screen.
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
