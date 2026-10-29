// The announcements centre as the user sees it: loading, empty,
// populated and error states, title/body display, read/unread visuals,
// pull-to-refresh, and opening/closing a detail - through the real
// AnnouncementsState and the real ApiClient, with the backend faked at
// the transport (installFakeApi/setFakeRoute, the widget-test seam).
//
// The fake JSON shapes below mirror the backend's CustomerAnnouncementOut
// exactly (id/title/body/communication_type/severity/deep_link/
// published_at/expires_at/read_at/is_read) - if they drift, these tests
// fail, which is the point.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:broka/features/communications/presentation/announcement_detail_screen.dart';
import 'package:broka/features/communications/presentation/announcements_screen.dart';
import 'package:broka/features/communications/presentation/announcements_state.dart';
import 'package:broka/services/api_service.dart';
import 'support/fake_api.dart';

Map<String, dynamic> _announcementJson({
  String id = 'comm-1',
  String title = 'Maintenance tonight',
  String body = 'The app will be down from 2am to 3am EAT.',
  String type = 'maintenance',
  String severity = 'high',
  String? readAt,
}) =>
    {
      'id': id,
      'title': title,
      'body': body,
      'communication_type': type,
      'severity': severity,
      'deep_link': null,
      'published_at': '2026-10-28T10:00:00Z',
      'expires_at': null,
      'read_at': readAt,
      'is_read': readAt != null,
    };

Map<String, dynamic> _pageJson(List<Map<String, dynamic>> items,
        {int? total, int offset = 0}) =>
    {
      'items': items,
      'total': total ?? items.length,
      'limit': 50,
      'offset': offset,
    };

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// Signed in through the same path main.dart uses: the saved session in
/// SharedPreferences. Without it the screen asks the guest to sign in.
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
    setFakeRoute((uri) {
      if (uri.path == '/communications') {
        return _pageJson([
          _announcementJson(),
          _announcementJson(
              id: 'comm-2',
              title: 'New M-Pesa limits',
              body: 'Higher limits for verified sellers.',
              type: 'product_update',
              severity: 'normal',
              readAt: '2026-10-27T09:00:00Z'),
        ]);
      }
      if (uri.path == '/communications/unread-count') {
        return {'unread_count': 1};
      }
      return null;
    });
  });

  tearDown(() {
    ApiService.currentUserId = null;
    setFakeRoute(null);
  });

  Widget app({List<RouteSettings>? pushed}) {
    final state = AnnouncementsState();
    addTearDown(state.dispose);
    return ChangeNotifierProvider<AnnouncementsState>.value(
      value: state,
      child: MaterialApp(
        home: const AnnouncementsScreen(animateBackground: false),
        onGenerateRoute: (settings) {
          pushed?.add(settings);
          return MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('ELSEWHERE')));
        },
      ),
    );
  }

  testWidgets('loading state first, then titles and bodies', (tester) async {
    // A slow feed holds the spinner long enough to see.
    setFakeRoute((uri) {
      if (uri.path == '/communications') {
        return FakeResponse(_pageJson([_announcementJson()]),
            delay: const Duration(milliseconds: 300));
      }
      if (uri.path == '/communications/unread-count') {
        return {'unread_count': 1};
      }
      return null;
    });
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Maintenance tonight'), findsOneWidget);
    expect(find.textContaining('down from 2am'), findsOneWidget);
    // The request went to the real endpoint with pagination params.
    expect(
        fakeRequests.any((r) =>
            r.method == 'GET' &&
            r.uri.path == '/communications' &&
            r.uri.queryParameters['limit'] == '50' &&
            r.uri.queryParameters['offset'] == '0'),
        isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('empty feed explains itself, distinctly from an error',
      (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/communications') return _pageJson([]);
      if (uri.path == '/communications/unread-count') {
        return {'unread_count': 0};
      }
      return null;
    });
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('No announcements'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('a failed feed shows a retryable error', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/communications') {
        return const FakeResponse.error(statusCode: 500);
      }
      if (uri.path == '/communications/unread-count') {
        return {'unread_count': 0};
      }
      return null;
    });
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text("Couldn't load announcements"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // Retry re-requests the feed.
    final before =
        fakeRequests.where((r) => r.uri.path == '/communications').length;
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(
        fakeRequests.where((r) => r.uri.path == '/communications').length,
        greaterThan(before));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('unread and read rows look different', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(tester.takeException(), isNull);
    // comm-1 unread: the gold dot. comm-2 read: none.
    expect(find.byKey(const Key('announcement-unread-dot-comm-1')),
        findsOneWidget);
    expect(find.byKey(const Key('announcement-unread-dot-comm-2')),
        findsNothing);
    // Severity and type ride along.
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Maintenance'), findsOneWidget);
    expect(find.text('Product update'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('pull-to-refresh reloads the feed', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    final before =
        fakeRequests.where((r) => r.uri.path == '/communications').length;
    expect(before, greaterThanOrEqualTo(1));
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, 300), 800);
    await _settle(tester);
    expect(
        fakeRequests.where((r) => r.uri.path == '/communications').length,
        greaterThan(before));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('opening an announcement acknowledges it and shows the detail',
      (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.text('Maintenance tonight'));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    // The detail: full title and body, on the announcements visual system.
    expect(find.byType(AnnouncementDetailScreen), findsOneWidget);
    expect(find.text('Maintenance tonight'), findsOneWidget);
    expect(find.text('The app will be down from 2am to 3am EAT.'),
        findsOneWidget);
    // Opening IS the read: the acknowledgement was posted.
    expect(
        fakeRequests.any((r) =>
            r.method == 'POST' &&
            r.uri.path == '/communications/comm-1/read'),
        isTrue);
    // Back closes the detail to the list.
    // Back closes the detail to the list. The collapsing header's back
    // control is a plain GestureDetector + icon (not a BackButton), so tap
    // it directly rather than tester.pageBack().
    final backButton = find.descendant(
      of: find.byType(AnnouncementDetailScreen),
      matching: find.byIcon(Icons.arrow_back_ios_new_rounded),
    );
    expect(backButton, findsOneWidget);
    await tester.tap(backButton);
    await _settle(tester);
    expect(find.byType(AnnouncementDetailScreen), findsNothing);
    expect(find.text('Maintenance tonight'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('a failed acknowledgement offers a retry, not a false read',
      (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/communications') {
        return _pageJson([_announcementJson()]);
      }
      if (uri.path == '/communications/unread-count') {
        return {'unread_count': 1};
      }
      if (uri.path == '/communications/comm-1/read') {
        return const FakeResponse.error(statusCode: 500);
      }
      return null;
    });
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.text('Maintenance tonight'));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text("Couldn't confirm you've read this"), findsOneWidget);
    // Still unread: the dot is back on the list behind, and retry re-posts.
    final reads = () => fakeRequests
        .where((r) => r.uri.path == '/communications/comm-1/read')
        .length;
    expect(reads(), 1);
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(reads(), 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('the header pill counts unread announcements', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('1 new'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('guests are asked to sign in first', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = null;
    await ApiService.loadSavedSession();
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(tester.takeException(), isNull);
    // The auth prompt sheet, not the feed.
    expect(find.textContaining('Create a free account', findRichText: true),
        findsOneWidget);
    expect(find.text('Maintenance tonight'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
