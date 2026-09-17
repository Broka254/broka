// BROKA TTS Service
// ─────────────────────────────────────────────────────────────────────────────
// ALL languages go to the BROKA backend (/tts/speak):
//   English  → Microsoft Edge TTS  en-US-AriaNeural  (American English)
//   Swahili  → Microsoft Edge TTS  sw-KE-ZuriNeural    (Kenyan Swahili)
//   Sheng    → Kokoro on HF Space  (Broka custom voice)
//   Luo      → Kokoro on HF Space
//   Kikuyu   → Kokoro on HF Space
//   Luganda  → Kokoro on HF Space
//
// No API keys on the phone. If the backend call fails, silently falls back
// to the device TTS engine so the app never breaks.
// Audio is cached in memory - same phrase never fetched twice.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'api_service.dart';

class BrokaTts {
  BrokaTts._();
  static final BrokaTts instance = BrokaTts._();

  final FlutterTts  _fallback = FlutterTts();
  final AudioPlayer _player   = AudioPlayer();

  // In-memory cache - key = "language:text"
  final Map<String, Uint8List> _cache = {};

  bool _initialised = false;
  bool _speaking    = false;

  VoidCallback? onStart;
  VoidCallback? onDone;
  VoidCallback? onFallback;  // fired when cloud voice fails and device TTS is used

  // ── Public API ──────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    // Configure device TTS as fallback
    try {
      final engines = await _fallback.getEngines;
      if (engines != null && (engines as List).isNotEmpty) {
        await _fallback.setSpeechRate(0.45);
        await _fallback.setVolume(1.0);
        await _fallback.setPitch(0.95);
        await _fallback.awaitSpeakCompletion(true);
        _fallback.setStartHandler(()      { _speaking = true;  onStart?.call(); });
        _fallback.setCompletionHandler(() { _speaking = false; onDone?.call();  });
        _fallback.setCancelHandler(()    { _speaking = false; onDone?.call();  });
        _fallback.setErrorHandler((_)    { _speaking = false; onDone?.call();  });
      }
    } catch (_) {}

    // AudioPlayer state listeners
    _player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.playing) {
        _speaking = true;  onStart?.call();
      } else if (state == PlayerState.completed ||
                 state == PlayerState.stopped) {
        _speaking = false; onDone?.call();
      }
    });
  }

  bool get isSpeaking => _speaking;

  Future<void> speak(String text, {String language = 'english'}) async {
    final clean = _clean(text);
    if (clean.isEmpty) return;
    await stop();
    // All languages go to the backend - it decides which engine to use
    await _speakCloud(clean, language);
  }

  Future<void> stop() async {
    try { await _player.stop();   } catch (_) {}
    try { await _fallback.stop(); } catch (_) {}
    _speaking = false;
    onDone?.call();
  }

  void dispose() {
    _player.dispose();
    _fallback.stop();
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  Future<void> _speakCloud(String text, String language) async {
    final cacheKey = '$language:$text';
    Uint8List? bytes = _cache[cacheKey];

    if (bytes == null) {
      try {
        final token = ApiService.authToken;
        if (token == null) {
          await _speakFallback(text, language);
          return;
        }

        final response = await http.post(
          Uri.parse('${ApiService.baseUrl}/tts/speak'),
          headers: {
            'Content-Type':  'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'text': text, 'language': language}),
        ).timeout(const Duration(seconds: 25));

        if (response.statusCode == 200) {
          bytes = response.bodyBytes;
          // Keep cache to 40 items max
          if (_cache.length >= 40) {
            _cache.remove(_cache.keys.first);
          }
          _cache[cacheKey] = bytes;
        } else {
          debugPrint('TTS backend ${response.statusCode} - falling back');
          await _speakFallback(text, language);
          return;
        }
      } catch (e) {
        debugPrint('TTS backend error: $e - falling back');
        await _speakFallback(text, language);
        return;
      }
    }

    try {
      await _player.play(BytesSource(bytes));
    } catch (e) {
      debugPrint('AudioPlayer error: $e - falling back');
      await _speakFallback(text, language);
    }
  }

  Future<void> _speakFallback(String text, String language) async {
    onFallback?.call();
    try {
      await _fallback.setLanguage(_localeFor(language));
      await _fallback.speak(text);
    } catch (_) {}
  }

  String _localeFor(String language) {
    switch (language) {
      case 'english': return 'en-US';
      case 'swahili': return 'sw-KE';
      case 'luganda': return 'en-UG';
      default:        return 'en-KE';
    }
  }

  String _clean(String text) => text
      .replaceAll('**', '')
      .replaceAll('*', '')
      .replaceAll('#', '')
      .replaceAll(RegExp(r'[\u{1F600}-\u{1F64F}]', unicode: true), '')
      .replaceAll(RegExp(r'[\u{1F300}-\u{1FFFF}]', unicode: true), '')
      .replaceAll(RegExp(r'[\u{2600}-\u{27BF}]',   unicode: true), '')
      .trim();
}
