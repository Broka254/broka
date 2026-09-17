// BROKA — Automatic OTP capture (Android SMS Retriever API).
//
// Why this exists
// ───────────────
// The OTP screen used to rely on `AutofillHints.oneTimeCode` inside an
// `AutofillGroup`. On Android that routes through the platform Autofill
// framework, which:
//   • asks the user to confirm ("Autofill?") before filling anything, and
//   • only offers at all when an autofill service is configured, has the SMS
//     permission, and happens to parse the message — so in practice it worked
//     on some handsets and silently did nothing on others.
// That is the reported behaviour: sometimes it pastes, sometimes it doesn't,
// and there is always a prompt.
//
// The SMS Retriever API is the mechanism built for this exact job. The app
// gets the message contents directly from Google Play Services, with:
//   • no SMS permission,
//   • no prompt and no user interaction whatsoever, and
//   • no access to any message other than the one addressed to this app.
//
// The trade is that the OTP SMS must end with an 11-character hash derived
// from the app's package name and signing certificate. [appSignature] reads
// that hash off the device and the client sends it up with the OTP request,
// so debug, release and Play-signed builds each get a message they can match
// without anyone maintaining a build-time constant.
//
// iOS needs none of this — the keyboard offers an incoming code as a
// QuickType suggestion natively — so every method here is a safe no-op there.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SmsAutofillService {
  SmsAutofillService._();

  static const MethodChannel _method =
      MethodChannel('com.broka.app/sms_retriever');
  static const EventChannel _events =
      EventChannel('com.broka.app/sms_retriever_events');

  static Stream<String>? _codeStream;

  /// True only where the SMS Retriever is available.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// The 11-character app-signature hash this build's OTP SMS must end with.
  ///
  /// Returns null on iOS, or if Play Services is unavailable. A null result
  /// is not an error: the server then sends its ordinary human-readable SMS
  /// and the user types the code, exactly as before.
  static Future<String?> appSignature() async {
    if (!isSupported) return null;
    try {
      return await _method.invokeMethod<String>('getAppSignature');
    } on PlatformException catch (e) {
      debugPrint('[sms_autofill] app signature unavailable: ${e.message}');
      return null;
    } on MissingPluginException {
      // Older host build without the native side wired up.
      return null;
    }
  }

  /// Begins listening for the OTP SMS and emits the extracted code.
  ///
  /// Play Services stops listening on its own after five minutes, which is
  /// longer than the code stays valid, so there is no case where this
  /// outlives its usefulness. Call [stop] when leaving the screen anyway.
  ///
  /// The stream is broadcast and cached, so calling this twice (a resend,
  /// say) attaches to the existing retriever rather than racing a second one.
  static Stream<String> codes() {
    if (!isSupported) return const Stream<String>.empty();
    return _codeStream ??= _events
        .receiveBroadcastStream()
        .map((e) => e?.toString() ?? '')
        .where((c) => c.isNotEmpty)
        .asBroadcastStream();
  }

  /// Arms the retriever for the next incoming message.
  ///
  /// Must be called each time a code is requested: one `startSmsRetriever`
  /// covers exactly one message, so a resend needs a fresh arm or the second
  /// SMS is never delivered to the app.
  static Future<bool> start() async {
    if (!isSupported) return false;
    try {
      return await _method.invokeMethod<bool>('start') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[sms_autofill] could not start retriever: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Tears down the native receiver. Safe to call when never started.
  static Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _method.invokeMethod<void>('stop');
    } on PlatformException catch (_) {
      // Nothing to do — the receiver is already gone.
    } on MissingPluginException {
      // Native side not present.
    }
  }
}
