// Getting people to let BROKA reach them (2026-10-09). Notifications were
// asked for once at start-up and background running once per install; a
// "no" was final and nothing said what it cost. The reminder
// (widgets/delivery_nudge.dart) shows on Home, the Inbox and a listing just
// posted, and Settings says whether each is on.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/settings_screen.dart';
import 'package:broka/services/delivery_access.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:broka/widgets/delivery_nudge.dart';

import 'support/fake_api.dart';

class _FakeAccess extends DeliveryAccess {
  _FakeAccess(this.state);

  DeliveryState? state;
  bool snoozed = false;
  int fixes = 0;
  int notificationAsks = 0;
  int backgroundAsks = 0;

  static const allGood = DeliveryState(notificationsAllowed: true, backgroundAllowed: true);

  @override
  Future<DeliveryState?> check() async => state;

  @override
  Future<void> fix(DeliveryState s) async {
    fixes++;
    state = allGood;
  }

  @override
  Future<void> allowNotifications() async {
    notificationAsks++;
    state = DeliveryState(notificationsAllowed: true, backgroundAllowed: state!.backgroundAllowed);
  }

  @override
  Future<void> allowBackground() async {
    backgroundAsks++;
    state = DeliveryState(notificationsAllowed: state!.notificationsAllowed, backgroundAllowed: true);
  }

  @override
  Future<bool> isSnoozed() async => snoozed;

  @override
  Future<void> snooze() async => snoozed = true;
}

const _notificationsOff = DeliveryState(notificationsAllowed: false, backgroundAllowed: true);
const _backgroundHeld = DeliveryState(notificationsAllowed: true, backgroundAllowed: false);

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalPollerService.instance.unreadTotal.value = 0;
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));
    await tester.pump();
    await tester.pump();
  }

  group('the reminder', () {
    testWidgets('notifications off: says what it costs, and turns them on', (tester) async {
      final access = _FakeAccess(_notificationsOff);
      GlobalPollerService.instance.unreadTotal.value = 3;
      await pump(tester, DeliveryNudge(access: access));

      expect(find.text('Notifications are off'), findsOneWidget);
      expect(find.textContaining("You have 3 unread messages BROKA couldn't tell you about"), findsOneWidget);
      await tester.tap(find.byKey(const Key('delivery-nudge-turn-on')));
      await tester.pump();
      await tester.pump();
      expect(access.fixes, 1);
      // Fixed: it goes.
      expect(find.byKey(const Key('delivery-nudge')), findsNothing);
    });

    testWidgets('"Later" puts it away - for days, not for good', (tester) async {
      final access = _FakeAccess(_notificationsOff);
      await pump(tester, DeliveryNudge(access: access));
      await tester.tap(find.byKey(const Key('delivery-nudge-later')));
      await tester.pump();
      expect(find.byKey(const Key('delivery-nudge')), findsNothing);
      expect(access.snoozed, isTrue);
      expect(DeliveryAccess.snoozeFor, const Duration(days: 3));
    });

    testWidgets('battery saving holding BROKA back is its own reminder, with Autostart', (tester) async {
      await pump(tester, DeliveryNudge(access: _FakeAccess(_backgroundHeld)));
      expect(find.text('Your phone may be holding BROKA back'), findsOneWidget);
      expect(find.textContaining('Autostart'), findsOneWidget);
      expect(find.text('Allow'), findsOneWidget);
    });

    testWidgets('nothing when all is well, or when it cannot be told', (tester) async {
      await pump(tester, DeliveryNudge(access: _FakeAccess(_FakeAccess.allGood)));
      expect(find.byKey(const Key('delivery-nudge')), findsNothing);
      await pump(tester, DeliveryNudge(access: _FakeAccess(null)));
      expect(find.byKey(const Key('delivery-nudge')), findsNothing);
    });

    testWidgets('a listing just posted: speaks to the seller, and shows even when snoozed', (tester) async {
      final access = _FakeAccess(_notificationsOff)..snoozed = true;
      await pump(tester, DeliveryNudge.listingLive(access: access));
      expect(find.text('Hear from buyers the moment they write'), findsOneWidget);
      expect(find.byKey(const Key('delivery-nudge-later')), findsNothing);
    });

    test('the real snooze is remembered', () async {
      final access = DeliveryAccess();
      expect(await access.isSnoozed(), isFalse);
      await access.snooze();
      expect(await access.isSnoozed(), isTrue);
    });
  });

  group('Settings', () {
    Future<void> open(WidgetTester tester, _FakeAccess access) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: SettingsScreen(animateBackground: false, access: access)));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('says notifications are off, and a tap turns them on', (tester) async {
      final access = _FakeAccess(const DeliveryState(notificationsAllowed: false, backgroundAllowed: false));
      await open(tester, access);
      await tester.scrollUntilVisible(find.byKey(const Key('settings-background')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const Key('settings-notifications-off')), findsOneWidget);
      expect(find.text('OFF'), findsNWidgets(2));

      await tester.tap(find.byKey(const Key('settings-notifications-off')));
      await tester.pump();
      await tester.pump();
      expect(access.notificationAsks, 1);
      expect(find.byKey(const Key('settings-notifications-off')), findsNothing);

      await tester.tap(find.byKey(const Key('settings-background')));
      await tester.pump();
      await tester.pump();
      expect(access.backgroundAsks, 1);
      expect(find.text('ON'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
