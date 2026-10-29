// Announcement push routing: the service_communication payload the backend
// sends (service._push_data) - recognition, foreground presentation,
// tap routing to list/detail, guest stash-and-resume, dedup, and no
// regressions to the existing chat/call/deal payloads.
//
// Follows the missed_call_notification_test.dart seam: the
// flutter_local_notifications method channel is mocked, shown payloads are
// captured, and navigation is asserted through onGenerateRoute.
import 'dart:convert';

import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _push({
  String? id = 'comm-1',
  String type = 'service_communication',
  String? title = 'Maintenance tonight',
  String? body = 'Down from 2am to 3am EAT.',
  String? severity = 'high',
}) =>
    {
      'type': type,
      if (id != null) 'communication_id': id,
      'communication_type': 'maintenance',
      if (severity != null) 'severity': severity,
      'screen': 'service_communications',
      if (title != null) 'title': title,
      if (body != null) 'body': body,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final shown = <Map<String, dynamic>>[];
  final cancelled = <Object?>[];

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global'
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'show') {
        shown.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      if (call.method == 'cancel') cancelled.add(call.arguments);
      return null;
    });
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
    debugDefaultTargetPlatformOverride = null;
  });

  setUp(() {
    shown.clear();
    cancelled.clear();
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'user-1';
    NotificationService.instance.isAnnouncementsOnScreen = null;
    NotificationService.instance.onAnnouncementsChanged = null;
    NotificationService.instance.consumePendingAnnouncementTap();
  });

  tearDown(() {
    ApiService.currentUserId = null;
    NotificationService.instance.isAnnouncementsOnScreen = null;
    NotificationService.instance.onAnnouncementsChanged = null;
  });

  String? tagOf(Map<String, dynamic> shownCall) =>
      (shownCall['platformSpecifics'] as Map?)?['tag'] as String?;

  Future<RouteSettings?> tap(
      WidgetTester tester, Map<String, dynamic> payload) async {
    final nav = GlobalKey<NavigatorState>();
    RouteSettings? opened;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const SizedBox(),
      onGenerateRoute: (settings) {
        opened = settings;
        return MaterialPageRoute(
            settings: settings, builder: (_) => const SizedBox());
      },
    ));
    NotificationService.instance.navigatorKey = nav;
    await NotificationService.instance.navigateFromPayload(payload);
    await tester.pump();
    return opened;
  }

  group('foreground handling', () {
    testWidgets('a valid push is shown once, tagged per announcement',
        (tester) async {
      var refreshed = 0;
      NotificationService.instance.onAnnouncementsChanged = () => refreshed++;
      await NotificationService.instance.showAnnouncementFromPush(_push());
      expect(shown, hasLength(1));
      expect(shown.single['title'], 'Maintenance tonight');
      expect(shown.single['body'], 'Down from 2am to 3am EAT.');
      expect(tagOf(shown.single), 'announcement_comm-1');
      // The feed/badge refresh - receiving is not reading, but it is news.
      expect(refreshed, 1);
      // A re-sent push updates rather than stacking: same tag, and the
      // foreground handler draws nothing the second time.
      await NotificationService.instance.showAnnouncementFromPush(_push());
      expect(shown, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a push for an already-announced id draws nothing',
        (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await NotificationService.markAnnouncementAnnounced(prefs, 'comm-1');
      await NotificationService.instance.showAnnouncementFromPush(_push());
      expect(shown, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('while the centre is open the feed refreshes quietly',
        (tester) async {
      var refreshed = 0;
      NotificationService.instance.isAnnouncementsOnScreen = () => true;
      NotificationService.instance.onAnnouncementsChanged = () => refreshed++;
      await NotificationService.instance.showAnnouncementFromPush(_push());
      expect(shown, isEmpty);
      expect(refreshed, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('missing or blank ids are dropped, never shown', (tester) async {
      await NotificationService.instance
          .showAnnouncementFromPush(_push(id: null));
      await NotificationService.instance
          .showAnnouncementFromPush(_push(id: '  '));
      await NotificationService.instance
          .showAnnouncementFromPush({'type': 'service_communication'});
      expect(shown, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('missing title/body fall back to generic copy', (tester) async {
      await NotificationService.instance.showAnnouncementFromPush(
          _push(title: null, body: null));
      expect(shown, hasLength(1));
      expect(shown.single['title'], 'News from BROKA');
      expect(shown.single['body'], 'Tap to read the announcement.');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('low severity arrives silently, critical at max priority',
        (tester) async {
      await NotificationService.instance
          .showAnnouncementFromPush(_push(severity: 'low'));
      final android = shown.single['platformSpecifics'] as Map;
      expect(android['silent'], isTrue);
      shown.clear();
      await NotificationService.instance.showAnnouncementFromPush(
          _push(id: 'comm-2', severity: 'critical'));
      final critical = shown.single['platformSpecifics'] as Map;
      expect(critical['priority'], 2); // Priority.max
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the payload carries only type and id', (tester) async {
      await NotificationService.instance.showAnnouncementFromPush(_push());
      final payload =
          jsonDecode(shown.single['payload'] as String) as Map<String, dynamic>;
      expect(payload, {
        'type': 'service_communication',
        'communication_id': 'comm-1',
      });
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('other types still route to their own handlers', (tester) async {
      // Unknown types are silently dropped, exactly as before - the new
      // branch must not catch them.
      await NotificationService.instance
          .handleForegroundFcmMessage({'type': 'something_new'});
      await NotificationService.instance
          .handleForegroundFcmMessage({'type': 'deal_status'});
      expect(shown, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('tap routing', () {
    testWidgets('a valid id opens the announcement detail', (tester) async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'test-token',
        'user_id': 'user-1',
      });
      await ApiService.loadSavedSession();
      final opened = await tap(tester, _push());
      expect(opened?.name, '/announcement-detail');
      expect(opened?.arguments, {'id': 'comm-1'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a missing id falls back to the list', (tester) async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'test-token',
        'user_id': 'user-1',
      });
      await ApiService.loadSavedSession();
      final opened = await tap(tester, _push(id: null));
      expect(opened?.name, '/announcements');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a blank id falls back to the list', (tester) async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'test-token',
        'user_id': 'user-1',
      });
      await ApiService.loadSavedSession();
      final opened = await tap(tester, _push(id: 'None'));
      expect(opened?.name, '/announcements');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('guests sign in first, then land on the announcement',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await ApiService.loadSavedSession();
      final opened = await tap(tester, _push());
      expect(opened?.name, '/auth');
      // The destination survives sign-in, consumed exactly once.
      final pending = NotificationService.instance
          .consumePendingAnnouncementTap();
      expect(pending.hasTap, isTrue);
      expect(pending.communicationId, 'comm-1');
      final again = NotificationService.instance
          .consumePendingAnnouncementTap();
      expect(again.hasTap, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a guest tap with no id lands on the list after sign-in',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await ApiService.loadSavedSession();
      final opened = await tap(tester, _push(id: null));
      expect(opened?.name, '/auth');
      final pending = NotificationService.instance
          .consumePendingAnnouncementTap();
      expect(pending.hasTap, isTrue);
      expect(pending.communicationId, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('chat, call and deal payloads route as before', (tester) async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'test-token',
        'user_id': 'user-1',
      });
      await ApiService.loadSavedSession();
      final chat = await tap(tester, {
        'type': 'missed_call',
        'listingId': 'listing-1',
        'buyerId': 'buyer-1',
        'myRole': 'seller',
      });
      expect(chat?.name, '/direct-chat');
      final summary = await tap(tester, {'type': 'inbox_summary'});
      expect(summary?.name, '/inbox');
      final unknown = await tap(tester, {'type': 'something_new'});
      expect(unknown, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('announced tracking', () {
    test('recordAnnouncementAnnounced dedups across isolates', () async {
      await NotificationService.recordAnnouncementAnnounced(
          {'type': 'service_communication', 'communication_id': 'comm-9'});
      final prefs = await SharedPreferences.getInstance();
      expect(
          NotificationService.wasAnnouncementAnnounced(prefs, 'comm-9'),
          isTrue);
      expect(
          NotificationService.wasAnnouncementAnnounced(prefs, 'comm-1'),
          isFalse);
    });

    test('recordAnnouncementAnnounced ignores missing ids', () async {
      await NotificationService.recordAnnouncementAnnounced(
          {'type': 'service_communication'});
      final prefs = await SharedPreferences.getInstance();
      expect(NotificationService.announcedAnnouncementIds(prefs), isEmpty);
    });

    test('the announced list keeps the newest twenty', () async {
      final prefs = await SharedPreferences.getInstance();
      for (var i = 0; i < 25; i++) {
        await NotificationService.markAnnouncementAnnounced(prefs, 'comm-$i');
      }
      final ids = NotificationService.announcedAnnouncementIds(prefs);
      expect(ids, hasLength(20));
      expect(ids.first, 'comm-5');
      expect(ids.last, 'comm-24');
    });

    test('announcement tags are stable per id', () {
      expect(NotificationService.announcementTag('comm-1'),
          'announcement_comm-1');
    });
  });
}
