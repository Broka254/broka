// BROKA - Ringtone Service
//
// Rings the user's OWN ringtone for an incoming audio/video call, and
// respects their ringer setting while doing it.
//
// Previously this played a bundled two-tone chime (assets/audio/
// ringtone.mp3) through audioplayers for every call on every device. That
// was wrong in three ways beyond simply not being the sound the user chose:
//
//   - Ringer mode was not honoured. Routing through
//     AndroidUsageType.notificationRingtone puts the tone on the ring
//     stream, but it does not implement the silent/vibrate-only policy, so
//     a phone set to silent still made noise.
//   - It never vibrated, so a phone on vibrate gave no indication at all.
//   - Users cannot recognise an unfamiliar chime as their own phone.
//
// Android now goes through a small platform channel backed by
// RingtoneManager (android/.../SystemRingtone.kt), which resolves whatever
// is set in Settings > Sound > Phone ringtone, loops it, vibrates on the
// standard ring cadence, and stays quiet on silent.
//
// The bundled asset survives as a fallback for two cases that genuinely
// need one: iOS, where a local notification cannot play the system
// ringtone (only CallKit can, and that path is already wired separately in
// CallKitService), and any Android device where the platform call fails.
// Falling back to *something* matters more than which sound it is - a call
// that arrives in total silence is worse than one that arrives with the
// wrong tone.
//
// Centralised here rather than duplicated across negotiation_screen.dart's
// incoming-call dialog, voip_call_screen.dart's ringing state and
// NotificationService.showIncomingCall, so there is exactly one thing that
// can be ringing and exactly one safety timeout.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class RingtoneService {
  RingtoneService._();
  static final RingtoneService instance = RingtoneService._();

  static const MethodChannel _channel = MethodChannel('com.broka.app/ringtone');

  final AudioPlayer _player = AudioPlayer(playerId: 'broka_ringtone');
  bool _playing = false;
  bool _contextConfigured = false;
  Timer? _autoStopTimer;
  void Function()? _onTimeout;
  // The call this ring is for, when the caller said. One ringer serves
  // every call, so without an owner any call's teardown stopped whatever
  // was ringing - a cancelled earlier call silenced the one ringing now,
  // and the screen ringing for it lost its only teardown (see [stopFor]).
  String? _roomId;

  bool get isPlaying => _playing;

  /// The call the current ring belongs to, if it was started for one.
  String? get roomId => _playing ? _roomId : null;

  Future<void> _ensureAudioContext() async {
    if (_contextConfigured) return;
    _contextConfigured = true;
    try {
      // Only reached on the fallback path now, but still routed through the
      // ringtone usage so the fallback tone at least lands on the ring
      // stream rather than at media volume.
      await _player.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notificationRingtone,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
      ));
    } catch (_) {
      // Non-fatal - the tone still plays through the default context.
    }
  }

  /// Starts ringing. Safe to call repeatedly - calling it again while
  /// already ringing just refreshes the auto-stop timer and rebinds
  /// [onTimeout], which is what lets a screen take over a ring that
  /// NotificationService.showIncomingCall already started.
  ///
  /// [autoStopAfter] guarantees the tone can never ring forever - e.g. if
  /// the caller cancels before this device's next poll notices. Once it
  /// elapses, [onTimeout] fires so the screen can dismiss its own
  /// incoming-call UI in step with the sound stopping.
  ///
  /// Returns true if the device is handling the alert itself (rang,
  /// vibrated, or is deliberately on silent). Callers use that to decide
  /// whether a notification still needs to make its own sound - see
  /// NotificationService.showIncomingCall.
  Future<bool> play({
    Duration? autoStopAfter,
    void Function()? onTimeout,
    String? roomId,
  }) async {
    // Keep a previously-registered onTimeout when this call passes none.
    //
    // Two things start the same ring for one call: showIncomingCall (no
    // callback) and the screen that displays the incoming-call UI (which
    // needs one, to dismiss itself in step with the sound). They race -
    // showIncomingCall is not awaited by its callers - so a naive
    // assignment let the callback-free one land second and silently drop
    // the screen's teardown, leaving a dead incoming-call dialog behind
    // after the ring stopped.
    if (onTimeout != null) _onTimeout = onTimeout;
    if (roomId != null) _roomId = roomId;
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    if (autoStopAfter != null) {
      _autoStopTimer = Timer(autoStopAfter, () {
        final cb = _onTimeout;
        stop();
        cb?.call();
      });
    }
    // Already ringing: the device is handling the alert, whichever of the
    // two paths is doing it. This used to answer whether the SYSTEM ringtone
    // was the one playing, which is false on the bundled-tone fallback (always, on iOS) - so the caller
    // posted its notification with sound and an insistent flag on top of a
    // tone that was already looping.
    if (_playing) return true;
    _playing = true;

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final handled = await _channel.invokeMethod<bool>('play') ?? false;
        if (handled) return true;
      } catch (e) {
        // Channel missing (e.g. a background isolate, where MainActivity's
        // engine - and therefore this channel - does not exist) or the
        // platform side threw. Fall through to the bundled tone.
        debugPrint('[Ringtone] system ringtone unavailable: $e');
      }
    }

    await _ensureAudioContext();
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('audio/ringtone.mp3'));
      return true;
    } catch (_) {
      _playing = false;
      return false;
    }
  }

  /// Stop the ring if it is for [roomId] - or for no particular call. A
  /// ring that belongs to another call keeps ringing.
  Future<void> stopFor(String roomId) async {
    if (_roomId != null && _roomId != roomId) return;
    await stop();
  }

  Future<void> stop() async {
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    _onTimeout = null;
    _roomId = null;
    if (!_playing) return;
    _playing = false;

    // Stop BOTH paths unconditionally rather than only the one we believe
    // we started. A failed start can leave either side half-running, and a
    // ringtone that will not stop is the single worst failure this file
    // can produce.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stop');
      } catch (_) {}
    }
    try {
      await _player.stop();
    } catch (_) {}
  }
}
