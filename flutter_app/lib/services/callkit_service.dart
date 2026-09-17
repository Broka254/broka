// BROKA - CallKit bridge (iOS)
//
// The Dart half of ios/Runner/AppDelegate.swift. iOS cannot ring the way
// Android does: a normal push can't start a call, and an app that isn't
// registered with CallKit loses its microphone the moment it backgrounds.
// So on iOS the OS owns the ringing UI and the audio session, and this
// service is the seam between that and BROKA's existing, platform-neutral
// call flow (WebRtcService + VoipCallScreen), which is unchanged.
//
// Division of responsibility, deliberately the same shape as Android's:
//   • Native (Swift) rings, answers, ends, and owns the audio session.
//   • Dart owns the actual call - signaling, peer connection, media.
// No call logic is duplicated in Swift.
//
// Every method here is a no-op on Android, where CallForegroundService and
// the local-notification path already cover the same ground. Callers don't
// need to branch on platform.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api_service.dart';
import 'notification_service.dart';

class CallKitService {
  CallKitService._();
  static final CallKitService instance = CallKitService._();

  static const MethodChannel _channel = MethodChannel('com.broka.app/callkit');

  bool get _supported => !kIsWeb && Platform.isIOS;

  /// Room id of the call CallKit is currently showing, if any. Lets an
  /// `endCall` arriving from the native side be matched against the call
  /// actually on screen.
  String? _activeRoomId;
  String? get activeRoomId => _activeRoomId;

  /// Called once from main(), after the navigator exists.
  Future<void> initialize() async {
    if (!_supported) return;
    _channel.setMethodCallHandler(_onNativeCall);
    try {
      // Tells the native side the engine is up, which replays any call that
      // was answered from the lock screen before Flutter existed (cold
      // start). Without this handshake, answering a call on a terminated
      // app opens the app to the home screen and nothing else.
      await _channel.invokeMethod('ready');
      await registerVoipToken();
    } catch (e) {
      debugPrint('[CallKit] initialize failed: $e');
    }
  }

  /// Sends this device's PushKit VoIP token to the backend. Distinct from
  /// the FCM token: iOS requires a VoIP push (not a normal alert) to wake a
  /// terminated app for a call, and those are delivered over APNs against a
  /// separate token. Safe to call repeatedly - it's driven from the same
  /// login/session-restore paths as FCM registration.
  Future<void> registerVoipToken() async {
    if (!_supported) return;
    try {
      final token = await _channel.invokeMethod<String>('getVoipToken');
      if (token != null && token.isNotEmpty) {
        await ApiService.registerPushToken(token, tokenType: 'apns_voip');
      }
    } catch (e) {
      debugPrint('[CallKit] VoIP token registration skipped: $e');
    }
  }

  /// Registers an OUTGOING call with CallKit. Required, not cosmetic: on
  /// iOS this is what grants the app the call audio session and keeps it
  /// running when the user backgrounds the app or locks the screen
  /// mid-call. Android's equivalent is CallForegroundService.start().
  Future<void> reportOutgoingCall({
    required String roomId,
    required String peerName,
    required bool isVideo,
  }) async {
    if (!_supported) return;
    _activeRoomId = roomId;
    try {
      await _channel.invokeMethod('reportOutgoingCall', {
        'roomId': roomId,
        'peerName': peerName,
        'isVideo': isVideo,
      });
    } catch (e) {
      debugPrint('[CallKit] reportOutgoingCall failed: $e');
    }
  }

  /// Moves the native call UI out of "calling…" once media is flowing, so
  /// the system's own call timer matches the one in BROKA's call screen.
  Future<void> reportConnected(String roomId) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('reportCallConnected', {'roomId': roomId});
    } catch (_) {}
  }

  /// Takes the call out of the native UI. Must be called whenever a call
  /// ends for ANY reason - otherwise iOS keeps showing an active call the
  /// user can't get rid of, and keeps the audio session open.
  Future<void> endCall(String roomId) async {
    if (!_supported) return;
    if (_activeRoomId == roomId) _activeRoomId = null;
    try {
      await _channel.invokeMethod('endCall', {'roomId': roomId});
    } catch (e) {
      debugPrint('[CallKit] endCall failed: $e');
    }
  }

  // ── Native -> Dart ────────────────────────────────────────────────────────

  /// Set by main.dart. Invoked when the user answers from the native
  /// incoming-call UI; routes into the same VoIP screen every other answer
  /// path uses.
  Future<void> Function(Map<String, dynamic> payload)? onAnswered;

  /// Invoked when the user ends the call from the native UI (or CallKit
  /// resets). The call screen listens so it can tear the peer connection
  /// down - otherwise the native UI disappears while the mic stays hot.
  void Function(String roomId)? onEndedByNative;

  /// Invoked when the user mutes from the native UI.
  void Function(String roomId, bool muted)? onMuteChanged;

  Future<dynamic> _onNativeCall(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
    switch (call.method) {
      case 'voipToken':
        final token = args['token'] as String? ?? '';
        if (token.isNotEmpty) {
          await ApiService.registerPushToken(token, tokenType: 'apns_voip');
        }
        return null;

      case 'incomingCall':
        // The phone is already ringing natively at this point - CallKit
        // did that. This arrives so Dart can warm up: confirm the call is
        // still live and pre-fetch its room-scoped token, so tapping
        // Answer connects immediately instead of starting a round trip.
        _activeRoomId = args['roomId'] as String?;
        final listingId = args['listingId'] as String?;
        if (listingId != null) {
          try {
            await ApiService.checkIncomingCall(listingId);
          } catch (_) {}
        }
        return null;

      case 'answerCall':
        final roomId = args['roomId'] as String?;
        if (roomId == null) return null;
        _activeRoomId = roomId;
        // Any local notification we may also have posted is redundant now.
        await NotificationService.instance.cancelIncomingCall(roomId);
        await onAnswered?.call(args);
        return null;

      case 'endCall':
        final roomId = args['roomId'] as String?;
        if (roomId != null) {
          if (_activeRoomId == roomId) _activeRoomId = null;
          onEndedByNative?.call(roomId);
        }
        return null;

      case 'setMuted':
        final roomId = args['roomId'] as String?;
        final muted = args['muted'] as bool? ?? false;
        if (roomId != null) onMuteChanged?.call(roomId, muted);
        return null;
    }
    return null;
  }
}
