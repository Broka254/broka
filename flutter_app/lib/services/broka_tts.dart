// BROKA TTS Service
// ─────────────────────────────────────────────────────────────────────────────
// Zeno's voice comes from the BROKA backend (/tts/speak) and nowhere else:
//   English  → Microsoft Edge TTS  en-US-AvaMultilingualNeural (English text only)
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
//
// Spoken a sentence at a time (2026-10-12). The whole reply used to be one
// request, and the voice is made whole before it is sent, so a long reply
// kept Zeno silent for seconds after its text was up. Now the reply is
// split into parts ([speechParts]), all fetched at once; the first is short,
// so it comes back first and plays while the rest are still on their way.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
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

/// [text] split for speaking a part at a time: the first sentence alone
/// (with the next if it is only a word or two, like "Sure!"), so the voice
/// starts soon; then sentences grouped up to about [maxChars], so a long
/// reply is a few requests rather than one per sentence.
@visibleForTesting
List<String> speechParts(String text, {int maxChars = 220}) {
  final sentences = text
      .split(RegExp(r'(?<=[.!?…])\s+|\n+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final parts = <String>[];
  var current = '';
  for (final s in sentences) {
    final first = parts.isEmpty;
    final full = first ? current.length >= 24 : current.length + s.length + 1 > maxChars;
    if (current.isNotEmpty && full) {
      parts.add(current);
      current = s;
    } else {
      current = current.isEmpty ? s : '$current $s';
    }
  }
  if (current.isNotEmpty) parts.add(current);
  return parts;
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

  /// True between the parts of one reply: the player stops after each part,
  /// and that must not read as Zeno having finished - the microphone would
  /// open in the gap and hear the next part.
  bool _morePending = false;

  /// The reply being spoken, done when its last part has played (or it was
  /// stopped, or a part could not be fetched).
  Future<void>? _run;

  /// Bumped by every [speak] and [stop]. A reply's audio is fetched before
  /// it plays, and the fetch can take seconds: Zeno's next reply (or a
  /// stop) used to be overtaken by the earlier one's audio arriving late,
  /// so Zeno started saying the last thing after it had moved on to the
  /// next. Audio that comes back for a superseded request is now dropped.
  int _generation = 0;

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
        if (_speaking) return;
        _speaking = true;
        playing.value = true;
        onStart?.call();
      } else if (state == PlayerState.completed && _morePending) {
        // Another part of the same reply follows.
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
    final generation = ++_generation;
    final started = Completer<void>();
    final run = _speakParts(speechParts(clean), language, generation, started);
    _run = run;
    // Returns as the voice starts, like a single clip did - or when there
    // is no voice at all.
    await Future.any([started.future, run]);
  }

  @visibleForTesting
  int get generation => _generation;

  /// Like [speak], but finishes when Zeno has finished talking - or was
  /// stopped, or could not speak at all - rather than when playback starts.
  ///
  /// [speak] returns as the audio starts. The Zeno screen awaited it and
  /// then told the voice session Zeno had stopped speaking, so the session
  /// went back to listening at the first syllable, with Zeno's voice still
  /// coming out of the speaker into the open microphone.
  Future<void> speakToEnd(String text, {String language = 'english'}) async {
    await speak(text, language: language);
    final run = _run;
    if (run == null) return;
    try {
      // Longer than any reply takes to say: a lost completion event must
      // not leave voice mode stuck on "Speaking".
      await run.timeout(const Duration(seconds: 90));
    } catch (_) {
      // Timed out, or the player went away: either way, it is over.
    }
  }

  Future<void> stop() async {
    _generation++;
    _morePending = false;
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

  /// Plays [parts] in order, all fetched at once. Stops at the first part
  /// with no audio (already reported) or when something else is said.
  Future<void> _speakParts(
      List<String> parts, String language, int generation, Completer<void> started) async {
    final audio = [for (final p in parts) _fetch(p, language)];
    try {
      for (var i = 0; i < audio.length; i++) {
        final bytes = await audio[i];
        if (generation != _generation || bytes == null) return;
        _morePending = i < audio.length - 1;
        try {
          await _player.play(BytesSource(bytes));
        } catch (e) {
          debugPrint('AudioPlayer error: $e');
          _unavailable(TtsUnavailable.serviceDown);
          return;
        }
        if (!started.isCompleted) started.complete();
        // play() sets the state before it returns; anything else means
        // this part is already over.
        if (_player.state != PlayerState.playing) continue;
        try {
          await _player.onPlayerStateChanged
              .firstWhere((s) => s != PlayerState.playing)
              .timeout(const Duration(seconds: 60));
        } catch (_) {
          return;
        }
      }
    } finally {
      if (!started.isCompleted) started.complete();
      // A later part failed after an earlier one played: the gap between
      // them was kept quiet, so say it is over here.
      if (generation == _generation) {
        _morePending = false;
        if (_speaking) {
          _speaking = false;
          playing.value = false;
          onDone?.call();
        }
      }
    }
  }

  /// One part's audio, from the cache or the backend; null when there is
  /// none (reported through [onUnavailable]).
  Future<Uint8List?> _fetch(String text, String language) async {
    final cacheKey = '$language:$text';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    // The backend can still route an "english" request to the Swahili
    // voice, so only a language it refused outright is skipped.
    if (_noVoice.contains(language) && language != 'english') {
      _unavailable(TtsUnavailable.noVoiceForLanguage);
      return null;
    }
    final token = ApiService.authToken;
    if (token == null) return null;
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
        return null;
      }
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        debugPrint('TTS backend ${response.statusCode} - staying silent');
        _unavailable(TtsUnavailable.serviceDown);
        return null;
      }
      final bytes = response.bodyBytes;
      if (_cache.length >= 40) _cache.remove(_cache.keys.first);
      _cache[cacheKey] = bytes;
      return bytes;
    } catch (e) {
      debugPrint('TTS backend error: $e - staying silent');
      _unavailable(TtsUnavailable.serviceDown);
      return null;
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
