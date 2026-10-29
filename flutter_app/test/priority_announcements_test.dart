// Priority announcements: automatic surfacing of unread critical/high
// admin announcements - selection/ordering, per-account per-session
// deferral, the overlay widget, and duplicate foreground call pushes.
//
// Everything is driven through fakes: a scripted CommunicationsRepository,
// captured presentation callbacks, and a MockClient for the call check.
// No Firebase, no network, no production credentials.
import 'dart:async';
import 'dart:convert';

import 'package:broka/core/utils/result.dart';
import 'package:broka/features/communications/data/repositories/communications_repository.dart';
import 'package:broka/features/communications/domain/models/announcement.dart';
import 'package:broka/features/communications/presentation/announcements_state.dart';
import 'package:broka/features/communications/presentation/priority_announcement_coordinator.dart';
import 'package:broka/features/communications/presentation/priority_announcement_dialog.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Announcement _a({
  String id = 'comm-1',
  AnnouncementSeverity severity = AnnouncementSeverity.critical,
  String? publishedAt = '2026-10-28T10:00:00Z',
  String? expiresAt,
  String? readAt,
}) =>
    Announcement(
      id: id,
      title: 'Title $id',
      body: 'Body $id',
      type: AnnouncementType.announcement,
      severity: severity,
      publishedAt: publishedAt == null ? null : DateTime.parse(publishedAt),
      expiresAt: expiresAt == null ? null : DateTime.parse(expiresAt),
      readAt: readAt == null ? null : DateTime.parse(readAt),
    );

class _FakeRepo extends CommunicationsRepository {
  _FakeRepo() : super(client: null);
  List<Announcement> feed = [];
  bool failFeed = false;
  int markReadCalls = 0;

  @override
  Future<Result<AnnouncementPage>> announcements(
      {int limit = 50, int offset = 0}) async {
    if (failFeed) return const Failure('offline');
    return Success(AnnouncementPage(
        items: feed, total: feed.length, limit: limit, offset: offset));
  }

  @override
  Future<Result<AnnouncementRead>> markRead(String id) async {
    markReadCalls++;
    return Success(
        AnnouncementRead(id: id, readAt: DateTime.utc(2026, 10, 28, 12)));
  }

  @override
  Future<Result<int>> unreadCount() async =>
      Success(feed.where((a) => !a.isRead).length);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'user-1';
  });
  tearDown(() => ApiService.currentUserId = null);

  group('PriorityAnnouncements.select', () {
    test('critical before high, newest first, deterministic', () {
      final items = [
        _a(
            id: 'high-old',
            severity: AnnouncementSeverity.high,
            publishedAt: '2026-10-27T10:00:00Z'),
        _a(id: 'crit-old', publishedAt: '2026-10-26T10:00:00Z'),
        _a(
            id: 'high-new',
            severity: AnnouncementSeverity.high,
            publishedAt: '2026-10-28T09:00:00Z'),
        _a(id: 'crit-new', publishedAt: '2026-10-28T10:00:00Z'),
      ];
      expect(PriorityAnnouncements.select(items).map((a) => a.id),
          ['crit-new', 'crit-old', 'high-new', 'high-old']);
      // Same input, shuffled: same output.
      expect(
          PriorityAnnouncements.select(items.reversed.toList())
              .map((a) => a.id),
          ['crit-new', 'crit-old', 'high-new', 'high-old']);
    });

    test('normal and low are never auto-presented', () {
      final items = [
        _a(id: 'n', severity: AnnouncementSeverity.normal),
        _a(id: 'l', severity: AnnouncementSeverity.low),
        _a(id: 'h', severity: AnnouncementSeverity.high),
      ];
      expect(PriorityAnnouncements.select(items).map((a) => a.id), ['h']);
    });

    test('read and expired are excluded', () {
      final items = [
        _a(id: 'read', readAt: '2026-10-28T11:00:00Z'),
        _a(id: 'expired', expiresAt: '2026-10-28T10:30:00Z'),
        _a(id: 'live', expiresAt: '2026-10-29T10:00:00Z'),
      ];
      expect(
          PriorityAnnouncements.select(items,
                  now: DateTime.utc(2026, 10, 28, 11))
              .map((a) => a.id),
          ['live']);
    });
  });

  group('PriorityAnnouncementCoordinator', () {
    Future<bool> runCheck(
      PriorityAnnouncementCoordinator c,
      List<Announcement> feed, {
      List<List<Announcement>>? presented,
      bool refreshOk = true,
      bool canPresent = true,
      String? account = 'user-1',
    }) =>
        c.checkAndPresent(
          accountId: account,
          refreshFeed: () async => refreshOk,
          feed: () => feed,
          canPresent: () => canPresent,
          present: (eligible) async => presented?.add(eligible),
        );

    test('presents eligible notices after a successful refresh', () async {
      final c = PriorityAnnouncementCoordinator();
      final presented = <List<Announcement>>[];
      final shown = await runCheck(c, [_a(id: 'c1')], presented: presented);
      expect(shown, isTrue);
      expect(presented.single.single.id, 'c1');
    });

    test('a failed refresh presents nothing and marks nothing seen', () async {
      final c = PriorityAnnouncementCoordinator();
      final presented = <List<Announcement>>[];
      expect(
          await runCheck(c, [_a(id: 'c1')],
              presented: presented, refreshOk: false),
          isFalse);
      expect(presented, isEmpty);
      // Retry with a working feed still presents it.
      expect(await runCheck(c, [_a(id: 'c1')], presented: presented), isTrue);
    });

    test('no presentation while the UI is not safe, and none consumed',
        () async {
      final c = PriorityAnnouncementCoordinator();
      final presented = <List<Announcement>>[];
      expect(
          await runCheck(c, [_a(id: 'c1')],
              presented: presented, canPresent: false),
          isFalse);
      expect(await runCheck(c, [_a(id: 'c1')], presented: presented), isTrue);
    });

    test('deferral suppresses for the session, not the next cold start',
        () async {
      final feed = [_a(id: 'c1')];
      final first = PriorityAnnouncementCoordinator();
      final presented = <List<Announcement>>[];
      await runCheck(first, feed, presented: presented);
      first.defer('c1');
      expect(await runCheck(first, feed, presented: presented), isFalse);
      expect(presented, hasLength(1));
      // A new coordinator is a new cold-start session.
      final nextLaunch = PriorityAnnouncementCoordinator();
      expect(await runCheck(nextLaunch, feed, presented: presented), isTrue);
      expect(presented, hasLength(2));
      // Same for an explicit session reset.
      first.resetSession();
      expect(await runCheck(first, feed, presented: presented), isTrue);
    });

    test('a new critical is not blocked by a deferred high', () async {
      final high = _a(id: 'h1', severity: AnnouncementSeverity.high);
      final c = PriorityAnnouncementCoordinator();
      final presented = <List<Announcement>>[];
      await runCheck(c, [high], presented: presented);
      c.defer('h1');
      final crit = _a(id: 'c9', publishedAt: '2026-10-28T12:00:00Z');
      expect(await runCheck(c, [high, crit], presented: presented), isTrue);
      expect(presented.last.single.id, 'c9');
    });

    test('switching accounts clears suppression and stale checks die',
        () async {
      final c = PriorityAnnouncementCoordinator();
      final presented = <List<Announcement>>[];
      await runCheck(c, [_a(id: 'c1')], presented: presented);
      c.defer('c1');
      c.syncAccount('user-2');
      expect(c.isDeferred('c1'), isFalse);
      expect(c.accountId, 'user-2');
      c.syncAccount(null);
      expect(c.accountId, isNull);
      expect(
          await runCheck(c, [_a(id: 'c1')],
              presented: presented, account: null),
          isFalse);
    });

    test('the presentation lock admits one overlay at a time', () async {
      final c = PriorityAnnouncementCoordinator();
      expect(c.tryStartPresenting(), isTrue);
      expect(c.tryStartPresenting(), isFalse);
      c.stopPresenting();
      expect(c.tryStartPresenting(), isTrue);
      c.stopPresenting();
    });
  });

  group('with AnnouncementsState (startup path)', () {
    test('refresh proves the feed; priority follows server read state',
        () async {
      final repo = _FakeRepo()
        ..feed = [
          _a(id: 'c1'),
          _a(id: 'n1', severity: AnnouncementSeverity.normal)
        ];
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      expect(await state.refresh(), isTrue);
      expect(state.priorityAnnouncements.map((a) => a.id), ['c1']);
      // Deferring never marks read.
      final c = PriorityAnnouncementCoordinator();
      c.defer('c1');
      expect(state.items.first.isRead, isFalse);
      expect(repo.markReadCalls, 0);
      // Opening (the detail route's behaviour) does.
      expect(await state.markRead(state.items.first), isTrue);
      expect(state.priorityAnnouncements, isEmpty);
    });

    test('a failed refresh is not an empty feed', () async {
      final repo = _FakeRepo()..failFeed = true;
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      expect(await state.refresh(), isFalse);
    });
  });

  group('PriorityAnnouncementDialog', () {
    Future<void> pumpDialog(
      WidgetTester tester, {
      required List<Announcement> items,
      void Function(Announcement)? onRead,
      VoidCallback? onRemind,
      VoidCallback? onViewAll,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showPriorityAnnouncementDialog(
                  context,
                  announcements: items,
                  // Mirror main.dart: the action closes the overlay, then
                  // acts. Read-state changes happen in the detail route,
                  // never here.
                  onRead: (a) {
                    Navigator.of(context).pop();
                    onRead?.call(a);
                  },
                  onRemindLater: () {
                    Navigator.of(context).pop();
                    onRemind?.call();
                  },
                  onViewAll: () {
                    Navigator.of(context).pop();
                    onViewAll?.call();
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows when eligible, with critical styling', (tester) async {
      await pumpDialog(tester, items: [_a(id: 'c1')]);
      expect(find.byKey(const Key('priority-announcement-dialog')),
          findsOneWidget);
      expect(find.text('CRITICAL'), findsOneWidget);
      expect(find.byKey(const Key('priority-icon-critical')), findsOneWidget);
      expect(find.text('Title c1'), findsOneWidget);
      expect(find.text('Read announcement'), findsOneWidget);
      expect(find.text('Remind me later'), findsOneWidget);
    });

    testWidgets('high priority is prominent but less urgent', (tester) async {
      await pumpDialog(tester,
          items: [_a(id: 'h1', severity: AnnouncementSeverity.high)]);
      expect(find.text('HIGH PRIORITY'), findsOneWidget);
      expect(find.text('CRITICAL'), findsNothing);
      expect(find.byKey(const Key('priority-icon-high')), findsOneWidget);
    });

    testWidgets('several notices are one dialog with a count', (tester) async {
      await pumpDialog(tester, items: [
        _a(id: 'c1'),
        _a(id: 'h1', severity: AnnouncementSeverity.high),
        _a(id: 'h2', severity: AnnouncementSeverity.high),
      ]);
      expect(find.byKey(const Key('priority-announcement-dialog')),
          findsOneWidget);
      expect(find.text('+ 2 more important notices waiting'), findsOneWidget);
    });

    testWidgets('Read passes the actual announcement; Remind just closes',
        (tester) async {
      Announcement? read;
      var reminded = 0;
      await pumpDialog(tester,
          items: [_a(id: 'c1')],
          onRead: (a) => read = a,
          onRemind: () => reminded++);
      await tester.tap(find.byKey(const Key('priority-read-button')));
      await tester.pumpAndSettle();
      expect(read?.id, 'c1');

      await pumpDialog(tester,
          items: [_a(id: 'c1')], onRemind: () => reminded++);
      await tester.tap(find.byKey(const Key('priority-remind-button')));
      await tester.pumpAndSettle();
      expect(reminded, 1);
    });

    testWidgets('fits a small Android screen without overflow', (tester) async {
      tester.view.physicalSize = const Size(640, 1136);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await pumpDialog(tester, items: [
        _a(id: 'c1'),
        _a(id: 'h1', severity: AnnouncementSeverity.high),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('priority-announcement-dialog')),
          findsOneWidget);
      expect(find.byKey(const Key('priority-read-button')), findsOneWidget);
    });
  });

  group('foreground incoming-call pushes', () {
    test('concurrent duplicates verify and ring only once', () async {
      var pendingChecks = 0;
      final mock = MockClient((req) async {
        if (req.url.path.contains('/calls/pending/')) {
          pendingChecks++;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response(
              jsonEncode({
                'has_call': true,
                'room_id': 'room-1',
                'call_token': 'ct',
              }),
              200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{}', 200);
      });
      final payload = <String, dynamic>{
        'type': 'incoming_call',
        'roomId': 'room-1',
        'listingId': 'listing-1',
        'callerName': 'Buyer',
        'callToken': 'ct',
      };
      await http.runWithClient(
        () => Future.wait([
          NotificationService.instance.handleForegroundFcmMessage(payload),
          NotificationService.instance
              .handleForegroundFcmMessage(Map.of(payload)),
        ]),
        () => mock,
      );
      expect(pendingChecks, 1);
      expect(NotificationService.instance.foregroundCallsInFlight, 0);
    });
  });
}
