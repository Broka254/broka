// Can BROKA reach this phone while the app is closed? (2026-10-09)
//
// Two things decide it: whether notifications are allowed, and - on Android
// - whether the phone's battery optimisation holds BROKA back. Each was
// asked once (notifications at start-up, background running once per
// install) and a "no" was final: the app never asked again or said what it
// cost, and a seller whose buyers' messages never arrived had no way to
// know why. DeliveryNudge (widgets/delivery_nudge.dart) puts it in front of
// them where it matters - Home, the Inbox, a listing just posted - and
// Settings shows the state of each.

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What stands between BROKA and this phone with the app closed.
class DeliveryState {
  const DeliveryState({required this.notificationsAllowed, required this.backgroundAllowed});

  final bool notificationsAllowed;

  /// Not held back by battery optimisation. Always true off Android.
  final bool backgroundAllowed;

  bool get allGood => notificationsAllowed && backgroundAllowed;
}

class DeliveryAccess {
  DeliveryAccess();

  /// The one the app uses; a test puts a fake here.
  static DeliveryAccess instance = DeliveryAccess();

  /// How long "Later" puts the reminder away. Days, not forever: a "no" at
  /// a busy moment used to mean never hearing about it again.
  static const snoozeFor = Duration(days: 3);
  static const _snoozeKey = 'delivery_nudge_snoozed_until';

  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  /// Null where it can't be told (a platform without these settings, or a
  /// plugin that fails): nothing is shown rather than a guess.
  Future<DeliveryState?> check() async {
    try {
      final notifications = await Permission.notification.status;
      final background = !_android || await Permission.ignoreBatteryOptimizations.isGranted;
      return DeliveryState(
        notificationsAllowed: notifications.isGranted || notifications.isProvisional,
        backgroundAllowed: background,
      );
    } catch (e) {
      debugPrint('[DeliveryAccess] check failed: $e');
      return null;
    }
  }

  /// Notifications: asked again while Android still shows its dialog; once
  /// it won't (refused twice, or switched off in settings before Android
  /// 13, where there is no dialog at all), BROKA's page in the phone's
  /// settings opens - the person just tapped "Turn on".
  Future<void> allowNotifications() async {
    try {
      final status = await Permission.notification.request();
      if (status.isPermanentlyDenied || status.isDenied || status.isRestricted) {
        await openAppSettings();
      }
    } catch (e) {
      debugPrint('[DeliveryAccess] notifications request failed: $e');
    }
  }

  /// Background running: Android's own "let it run in the background?"
  /// dialog, or the app's settings page where the phone won't show it. Not
  /// after a "Deny" in that dialog - that is an answer.
  Future<void> allowBackground() async {
    if (!_android) return;
    try {
      final status = await Permission.ignoreBatteryOptimizations.request();
      if (status.isPermanentlyDenied || status.isRestricted) await openAppSettings();
    } catch (e) {
      debugPrint('[DeliveryAccess] background request failed: $e');
    }
  }

  /// Whatever [state] says is off, notifications first.
  Future<void> fix(DeliveryState state) async {
    if (!state.notificationsAllowed) await allowNotifications();
    if (!state.backgroundAllowed) await allowBackground();
  }

  Future<bool> isSnoozed() async {
    try {
      final until = (await SharedPreferences.getInstance()).getInt(_snoozeKey) ?? 0;
      return DateTime.now().millisecondsSinceEpoch < until;
    } catch (_) {
      return false;
    }
  }

  Future<void> snooze() async {
    try {
      await (await SharedPreferences.getInstance()).setInt(
          _snoozeKey, DateTime.now().add(snoozeFor).millisecondsSinceEpoch);
    } catch (_) {}
  }
}
