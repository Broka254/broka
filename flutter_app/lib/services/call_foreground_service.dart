// BROKA - Call Foreground Service (Dart bridge)
//
// Root-cause fix for calls dropping when the screen goes blank/locks
// mid-call:
//
// Once the screen turns off (or the app otherwise loses foreground), the
// Flutter activity is no longer in the foreground from Android's point of
// view. Starting with Android 9 (API 28), apps that are not in the
// foreground - and not running a foreground service - lose access to the
// microphone and camera outright, and on top of that, Doze/App Standby can
// throttle their network sockets. Neither flutter_webrtc nor any Flutter
// plugin can work around this from the Dart side; it has to be handled by
// an actual Android foreground service.
//
// This bridge starts/stops that native service (see CallForegroundService.kt)
// for the lifetime of a call, which (a) keeps the app exempt from those
// background mic/camera/network restrictions, and (b) holds a partial wake
// lock so the CPU keeps running the WebRTC/signaling code even with the
// screen off. The screen is still allowed to turn off as normal - only the
// CPU is kept awake, matching how a normal phone call behaves.
import 'package:flutter/services.dart';

class CallForegroundService {
  CallForegroundService._();
  static const MethodChannel _channel = MethodChannel('com.broka.app/call_service');

  /// Call once the call attempt begins (ringing/dialling) and keep it
  /// running for the whole call. Must be paired with [stop].
  static Future<void> start({required String peerName, required bool isVideo}) async {
    try {
      await _channel.invokeMethod('start', {
        'peerName': peerName,
        'isVideo': isVideo,
      });
    } catch (_) {
      // Non-fatal (e.g. iOS, or platform channel unavailable) - the call UI
      // still works, it just loses the background-survival protection.
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
