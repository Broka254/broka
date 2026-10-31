// Public-UI drive for the announcement lifecycle and feedback flows:
// date/time display, unread badge + mark-all-read, All/Unread/Important
// filters, delete/dismiss, feedback + complaint submission, and the
// priority dialog's close action - all through real widgets and the real
// ApiClient over the fake transport.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:broka/features/communications/domain/models/announcement.dart';
import 'package:broka/features/communications/presentation/announcements_screen.dart';
import 'package:broka/features/communications/presentation/announcements_state.dart';
import 'package:broka/features/communications/presentation/priority_announcement_dialog.dart';
import 'package:broka/features/feedback/presentation/feedback_screen.dart';
import 'package:broka/services/api_service.dart';
import 'support/fake_api.dart';

Map<String, dynamic> _ann({
  String id = 'comm-1',
  String title = 'Maintenance tonight',
  String severity = 'critical',
  String? readAt,
  DateTime? publishedAt,
  DateTime? expiresAt,
}) {
  // The card counts down from the wall clock ("Expires in N days" only
  // while two or more days are left), so fixed 2026 dates turned this
  // test into a calendar time bomb: from Oct 31 the fixture read
  // "Expires tomorrow" and the test failed. Ride relative to the run.
  final now = DateTime.now().toUtc();
  return {
    'id': id,
    'title': title,
    'body': 'The app will be down from 2am to 3am EAT.',
    'communication_type': 'maintenance',
    'severity': severity,
    'deep_link': null,
    'published_at':
        (publishedAt ?? now.subtract(const Duration(days: 3)))
            .toIso8601String(),
    'expires_at':
        (expiresAt ?? now.add(const Duration(days: 5))).toIso8601String(),
    'read_at': readAt,
    'is_read': readAt != null,
  };
}

Map<String, dynamic> _page(List<Map<String, dynamic>> items) =>
    {'items': items, 'total': items.length, 'limit': 50, 'offset': 0};

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _signIn() async {
  SharedPreferences.setMockInitialValues({
    'auth_token': 'test-token',
    'user_id': 'user-1',
  });
  ApiService.currentUserId = 'user-1';
  await ApiService.loadSavedSession();
}

void main() {
  setUpAll(installFakeApi);

  setUp(() async {
    await _signIn();
    clearFakeRequests();
  });

  tearDown(() {
    ApiService.currentUserId = null;
    setFakeRoute(null);
  });

  Widget announcementsApp(AnnouncementsState state) =>
      ChangeNotifierProvider<AnnouncementsState>.value(
        value: state,
        child: const MaterialApp(
          home: AnnouncementsScreen(animateBackground: false),
        ),
      );

  testWidgets('date/time, badge, filters, mark-all-read and delete',
      (tester) async {
    var unread = 1;
    // One instant for every fixture and expectation: published 3 days
    // ago ("3d ago"), expiring in 5 ("Expires in ..."), read 4 days ago.
    final now = DateTime.now().toUtc();
    final publishedAt = now.subtract(const Duration(days: 3));
    final expiresAt = now.add(const Duration(days: 5));
    final readAt = now.subtract(const Duration(days: 4)).toIso8601String();
    setFakeRoute((uri) {
      if (uri.path == '/communications') {
        return _page([
          _ann(publishedAt: publishedAt, expiresAt: expiresAt),
          _ann(
              id: 'comm-2',
              title: 'New M-Pesa limits',
              severity: 'normal',
              readAt: readAt,
              publishedAt: publishedAt,
              expiresAt: expiresAt),
        ]);
      }
      if (uri.path == '/communications/unread-count') {
        return {'unread_count': unread};
      }
      if (uri.path == '/communications/read-all') {
        unread = 0;
        return {'marked_read': 1};
      }
      if (uri.path.startsWith('/communications/')) {
        return {'id': 'comm-1', 'dismissed': true};
      }
      return null;
    });

    final state = AnnouncementsState();
    addTearDown(state.dispose);
    final frames = Stopwatch()..start();
    await tester.pumpWidget(announcementsApp(state));
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    frames.stop();
    debugPrint('[perf] announcements 30 frames in ${frames.elapsedMilliseconds}ms');
    expect(frames.elapsedMilliseconds, lessThan(15000));
    await _settle(tester);
    expect(tester.takeException(), isNull);

    // Full local date + time and relative age are both on the card.
    // The date is derived from the fixture instant above (rendered in
    // local time, as the card does), never a fixed calendar string.
    final local = publishedAt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    expect(
        find.textContaining(
            '${months[local.month - 1]} ${local.day}, ${local.year}'),
        findsWidgets);
    expect(find.textContaining('3d ago)'), findsWidgets);
    expect(find.textContaining('Expires in'), findsWidgets);

    // Filters narrow the feed (before anything is marked read).
    expect(find.text('1 new'), findsOneWidget);
    await tester.tap(find.text('Unread'));
    await _settle(tester);
    expect(find.text('New M-Pesa limits'), findsNothing);
    expect(find.text('Maintenance tonight'), findsOneWidget);
    await tester.tap(find.text('Important'));
    await _settle(tester);
    expect(find.text('Maintenance tonight'), findsOneWidget);
    await tester.tap(find.text('All'));
    await _settle(tester);
    expect(find.text('New M-Pesa limits'), findsOneWidget);

    // Mark-all-read through the header control clears the badge, and the
    // Unread filter then correctly has nothing left to show.
    await tester.tap(find.byKey(const Key('announcements-mark-all-read')));
    await _settle(tester);
    expect(
        fakeRequests.any(
            (r) => r.method == 'POST' && r.uri.path == '/communications/read-all'),
        isTrue);
    expect(find.text('1 new'), findsNothing);
    await tester.tap(find.text('Unread'));
    await _settle(tester);
    expect(find.text('Maintenance tonight'), findsNothing);
    await tester.tap(find.text('All'));
    await _settle(tester);
    expect(find.text('Maintenance tonight'), findsOneWidget);

    // Delete via the card action, confirmed in the dialog.
    await tester.tap(find.byKey(const Key('announcement-delete-comm-1')));
    await _settle(tester);
    expect(find.text('Delete this announcement?'), findsOneWidget);
    await tester.tap(find.text('Delete').last);
    await _settle(tester);
    expect(
        fakeRequests.any((r) =>
            r.method == 'DELETE' && r.uri.path == '/communications/comm-1'),
        isTrue);
    expect(find.text('Maintenance tonight'), findsNothing);
    expect(find.text('Announcement deleted'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('feedback then complaint submission with category/severity',
      (tester) async {
    // The fake transport is method-blind, so one merged shape answers
    // both POST /feedback (parsed as a submission) and GET /feedback
    // (parsed as a page): each parser reads only its own keys.
    setFakeRoute((uri) {
      if (uri.path == '/feedback') {
        const item = {
          'id': 'f-new',
          'kind': 'feedback',
          'category': 'general',
          'severity': 'normal',
          'subject': 'Dark mode schedule',
          'body': 'Please dim at night.',
          'status': 'open',
          'admin_response': null,
          'created_at': '2026-10-29T09:00:00Z',
        };
        return {
          ...item,
          'items': [item],
          'total': 1,
          'limit': 50,
          'offset': 0,
        };
      }
      return null;
    });
    await tester.pumpWidget(
        const MaterialApp(home: FeedbackScreen(animateBackground: false)));
    await _settle(tester);
    expect(tester.takeException(), isNull);

    await tester.enterText(
        find.byKey(const Key('feedback-subject')), 'Dark mode schedule');
    await tester.enterText(
        find.byKey(const Key('feedback-body')), 'Please dim at night.');
    await tester.dragUntilVisible(
      find.byKey(const Key('feedback-submit')),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const Key('feedback-submit')));
    await _settle(tester);
    final feedbackPost = fakeRequests.firstWhere(
        (r) => r.method == 'POST' && r.uri.path == '/feedback');
    final feedbackJson = feedbackPost.json as Map<String, dynamic>;
    expect(feedbackJson['kind'], 'feedback');
    expect(feedbackJson['subject'], 'Dark mode schedule');
    expect(find.textContaining('Thanks'), findsWidgets);

    // Switch to a complaint, pick category and severity, file it.
    clearFakeRequests();
    await tester.dragUntilVisible(
      find.byKey(const Key('feedback-kind-complaint')),
      find.byType(CustomScrollView),
      const Offset(0, 300),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const Key('feedback-kind-complaint')));
    await _settle(tester);
    await tester.dragUntilVisible(
      find.byKey(const Key('feedback-category')),
      find.byType(CustomScrollView),
      const Offset(0, 300),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const Key('feedback-category')));
    await _settle(tester);
    await tester.dragUntilVisible(
      find.text('A seller'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.text('A seller').last);
    await _settle(tester);
    await tester.tap(find.text('Urgent'));
    await tester.enterText(
        find.byKey(const Key('feedback-subject')), 'Seller was abusive');
    await tester.enterText(
        find.byKey(const Key('feedback-body')), 'Insults in chat.');
    await tester.dragUntilVisible(
      find.byKey(const Key('feedback-submit')),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const Key('feedback-submit')));
    await _settle(tester);
    final complaintPost = fakeRequests.firstWhere(
        (r) => r.method == 'POST' && r.uri.path == '/feedback');
    final complaintJson = complaintPost.json as Map<String, dynamic>;
    expect(complaintJson['kind'], 'complaint');
    expect(complaintJson['category'], 'seller_conduct');
    expect(complaintJson['severity'], 'urgent');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('priority dialog close defers via Remind me later',
      (tester) async {
    var reminded = 0;
    final announcement = Announcement(
      id: 'p1',
      title: 'Server maintenance',
      body: 'Temporary disruption expected.',
      type: AnnouncementType.maintenance,
      severity: AnnouncementSeverity.critical,
      publishedAt: DateTime.utc(2026, 10, 29, 16, 45),
      expiresAt: DateTime.utc(2026, 11, 28, 16, 45),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPriorityAnnouncementDialog(
              context,
              announcements: [announcement],
              onRead: (_) {},
              onRemindLater: () {
                reminded++;
                Navigator.of(context).pop();
              },
              onViewAll: () {},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(find.byKey(const Key('priority-announcement-dialog')),
        findsOneWidget);
    expect(find.textContaining('Oct 29, 2026'), findsWidgets);
    expect(find.textContaining('4:45 PM'), findsWidgets);
    await tester.tap(find.byKey(const Key('priority-close-button')));
    await _settle(tester);
    expect(reminded, 1);
    expect(find.byKey(const Key('priority-announcement-dialog')),
        findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
