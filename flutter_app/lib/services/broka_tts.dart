// BROKA TTS Service
// ─────────────────────────────────────────────────────────────────────────────
// Zeno's voice comes from the BROKA backend (/tts/speak) and nowhere else:
//   English  → Microsoft Edge TTS  en-US-AriaNeural   (English text only)
//   Swahili  → Microsoft Edge TTS  sw-KE-ZuriNeural   (Kenyan Swahili)
//   Sheng, Luo, Kikuyu, Luganda → Kokoro on the HF Space (Broka custom voice)
// The backend picks the voice from the text as well as the language asked
// for, so Swahili text is never read by the English voice
// (backend/api/routers/tts.py).
//
// No device voice any more (2026-09-26). When the backend call failed this
// used to fall back to flutter_tts - the phone's own engine, robotic, and
// usually without Swahili or any Kenyan language, so it read Swahili, Luo
// and Sheng in an English accent. Now Zeno stays silent instead and the
// reply is still on screen; [onUnavailable] lets a screen say so, once.
//
// No API keys on the phone. Audio is cached in memory - the same phrase is
// never fetched twice.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_service.dart';

/// Why Zeno couldn't speak.
enum TtsUnavailable {
  /// The backend has no voice for this language (HTTP 422).
  noVoiceForLanguage,

  /// The voice service, the network or playback failed.
  serviceDown,
}

class BrokaTts {
  BrokaTts._();
  static final BrokaTts instance = BrokaTts._();

  final AudioPlayer _player = AudioPlayer();

  // In-memory cache - key = "language:text"
  final Map<String, Uint8List> _cache = {};

  /// Languages the backend said it has no voice for, so each reply in one
  /// of them isn't another round trip to be told the same thing.
  final Set<String> _noVoice = {};

  bool _initialised = false;
  bool _speaking = false;

  VoidCallback? onStart;
  VoidCallback? onDone;

  /// Whether anything is being said, for anyone to listen to. onStart and
  /// onDone hold one callback each, and the screen that spoke last owns
  /// them; Zeno's session (zeno_session.dart) listens across every screen,
  /// so its microphone knows not to take a reply read out in the
  /// negotiation room for the user speaking.
  final ValueNotifier<bool> playing = ValueNotifier(false);

  /// Fired when Zeno can't speak a reply. At most once per reason per app
  /// session - saying "no voice for Dholuo" after every message is noise.
  void Function(TtsUnavailable reason)? onUnavailable;
  final Set<TtsUnavailable> _reported = {};

  // ── Public API ──────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    _player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.playing) {
        _speaking = true;
        playing.value = true;
        onStart?.call();
      } else if (state == PlayerState.completed || state == PlayerState.stopped) {
        _speaking = false;
        playing.value = false;
        onDone?.call();
      }
    });
  }

  bool get isSpeaking => _speaking;

  Future<void> speak(String text, {String language = 'english'}) async {
    final clean = _clean(text);
    if (clean.isEmpty) return;
    await stop();
    await _speakCloud(clean, language);
  }

  /// Like [speak], but finishes when Zeno has finished talking - or was
  /// stopped, or could not speak at all - rather than when playback starts.
  ///
  /// [speak] returns as the audio starts. The Zeno screen awaited it and
  /// then told the voice session Zeno had stopped speaking, so the session
  /// went back to listening at the first syllable, with Zeno's voice still
  /// coming out of the speaker into the open microphone.
  Future<void> speakToEnd(String text, {String language = 'english'}) async {
    await speak(text, language: language);
    // play() sets the state before it returns; anything else means nothing
    // is playing (no voice, no token, a failure) and there is nothing to
    // wait for.
    if (_player.state != PlayerState.playing) return;
    try {
      await _player.onPlayerStateChanged
          .firstWhere((s) => s != PlayerState.playing)
          // Longer than any reply takes to say: a lost completion event
          // must not leave voice mode stuck on "Speaking".
          .timeout(const Duration(seconds: 90));
    } catch (_) {
      // Timed out, or the player went away: either way, it is over.
    }
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
    _speaking = false;
    playing.value = false;
    onDone?.call();
  }

  void dispose() => _player.dispose();

  // ── Private ─────────────────────────────────────────────────────────────────

  void _unavailable(TtsUnavailable reason) {
    if (_reported.add(reason)) onUnavailable?.call(reason);
  }

  Future<void> _speakCloud(String text, String language) async {
    final cacheKey = '$language:$text';
    Uint8List? bytes = _cache[cacheKey];

    if (bytes == null) {
      // The backend can still route an "english" request to the Swahili
      // voice, so only a language it refused outright is skipped.
      if (_noVoice.contains(language) && language != 'english') {
        _unavailable(TtsUnavailable.noVoiceForLanguage);
        return;
      }
      final token = ApiService.authToken;
      if (token == null) return;
      try {
        final response = await http
            .post(
              Uri.parse('${ApiService.baseUrl}/tts/speak'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({'text': text, 'language': language}),
            )
            .timeout(const Duration(seconds: 25));

        if (response.statusCode == 422) {
          _noVoice.add(language);
          _unavailable(TtsUnavailable.noVoiceForLanguage);
          return;
        }
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          debugPrint('TTS backend ${response.statusCode} - staying silent');
          _unavailable(TtsUnavailable.serviceDown);
          return;
        }
        bytes = response.bodyBytes;
        if (_cache.length >= 40) _cache.remove(_cache.keys.first);
        _cache[cacheKey] = bytes;
      } catch (e) {
        debugPrint('TTS backend error: $e - staying silent');
        _unavailable(TtsUnavailable.serviceDown);
        return;
      }
    }

    try {
      await _player.play(BytesSource(bytes));
    } catch (e) {
      debugPrint('AudioPlayer error: $e');
      _unavailable(TtsUnavailable.serviceDown);
    }
  }

  String _clean(String text) => text
      .replaceAll('**', '')
      .replaceAll('*', '')
      .replaceAll('#', '')
      .replaceAll(RegExp(r'[\u{1F600}-\u{1F64F}]', unicode: true), '')
      .replaceAll(RegExp(r'[\u{1F300}-\u{1FFFF}]', unicode: true), '')
      .replaceAll(RegExp(r'[\u{2600}-\u{27BF}]', unicode: true), '')
      .trim();
}

/// What a screen tells the user when Zeno can't speak.
String ttsUnavailableMessage(TtsUnavailable reason) => switch (reason) {
      TtsUnavailable.noVoiceForLanguage =>
        "Zeno doesn't have a natural voice for this language yet, so replies are text only.",
      TtsUnavailable.serviceDown =>
        "Zeno's voice isn't available right now - replies are text only.",
    };
