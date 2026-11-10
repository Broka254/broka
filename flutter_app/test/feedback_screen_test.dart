// The redesigned Feedback & complaints screen: a complaint opened from a
// listing carries the listing and its seller to the team, each submission
// opens in full with the team's reply, a follow-up starts from it, and the
// history filters by progress. Real widgets and the real ApiClient over the
// fake transport, as announcement_feedback_ui_drive_test.dart does.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:broka/features/feedback/domain/models/feedback.dart';
import 'package:broka/features/feedback/presentation/feedback_screen.dart';
import 'package:broka/services/api_service.dart';
import 'support/fake_api.dart';

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

Map<String, dynamic> _page(List<Map<String, dynamic>> items) =>
    {'items': items, 'total': items.length, 'limit': 50, 'offset': 0};

const _resolved = <String, dynamic>{
  'id': 'f-done',
  'kind': 'complaint',
  'category': 'seller_conduct',
  'severity': 'high',
  'subject': 'Seller never showed',
  'body': 'We agreed to meet at 2pm and the seller never came.',
  'status': 'resolved',
  'admin_response': 'We warned the seller.',
  'responded_at': '2026-10-29T10:00:00Z',
  'resolved_at': '2026-10-29T12:00:00Z',
  'created_at': '2026-10-29T09:00:00Z',
};

const _open = <String, dynamic>{
  'id': 'f-open',
  'kind': 'feedback',
  'category': 'suggestion',
  'severity': 'normal',
  'subject': 'Dark mode schedule',
  'body': 'Please dim at night.',
  'status': 'open',
  'created_at': '2026-10-30T09:00:00Z',
};

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

  test('a submission carries what it is about, a short reference and its stage', () {
    final s = FeedbackSubmission.fromJson({
      'id': '3f2a9c1e-77aa-4bb0-9c33-000000000000',
      'subject': 'Fake photos',
      'body': 'Stock images.',
      'status': 'in_progress',
      'severity': 'urgent',
      'related_listing_id': 'listing-7',
      'related_user_id': '  ',
    })!;
    expect(s.reference, '#3F2A9C');
    expect(s.stage, 2);
    expect(s.severityLabel, 'Urgent');
    expect(s.relatedListingId, 'listing-7');
    expect(s.relatedUserId, isNull);
    expect(feedbackStage(FeedbackStatus.closed), 3);
  });

  testWidgets('a complaint about a listing is sent with the listing and seller',
      (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/feedback') {
        const item = {
          'id': 'f-9',
          'kind': 'complaint',
          'category': 'listing',
          'severity': 'normal',
          'subject': 'Fake photos',
          'body': 'Photos are stock images.',
          'status': 'open',
          'created_at': '2026-10-29T09:00:00Z',
        };
        return {...item, ..._page(const [])};
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(
      home: FeedbackScreen(
        animateBackground: false,
        initialKind: 'complaint',
        initialCategory: 'listing',
        relatedListingId: 'listing-7',
        relatedUserId: 'seller-3',
        contextLabel: 'Samsung A54 · KES 25,000',
      ),
    ));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('feedback-context')), findsOneWidget);
    expect(find.text('Samsung A54 · KES 25,000'), findsOneWidget);
    expect(find.text('File complaint'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('feedback-subject')), 'Fake photos');
    await tester.enterText(find.byKey(const Key('feedback-body')), 'Photos are stock images.');
    await tester.dragUntilVisible(
      find.byKey(const Key('feedback-submit')),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const Key('feedback-submit')));
    await _settle(tester);
    final post = fakeRequests.firstWhere((r) => r.method == 'POST' && r.uri.path == '/feedback');
    final json = post.json as Map<String, dynamic>;
    expect(json['kind'], 'complaint');
    expect(json['category'], 'listing');
    expect(json['related_listing_id'], 'listing-7');
    expect(json['related_user_id'], 'seller-3');
    // The confirmation quotes the reference the team will know it by.
    expect(find.textContaining('#F9'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('"not about this" detaches the listing before sending', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/feedback') {
        const item = {
          'id': 'f-10', 'kind': 'complaint', 'category': 'listing', 'severity': 'normal',
          'subject': 'Wrong one', 'body': 'Never mind the listing.', 'status': 'open',
          'created_at': '2026-10-29T09:00:00Z',
        };
        return {...item, ..._page(const [])};
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(
      home: FeedbackScreen(
        animateBackground: false,
        initialKind: 'complaint',
        relatedListingId: 'listing-7',
        contextLabel: 'Samsung A54',
      ),
    ));
    await _settle(tester);
    await tester.tap(find.byTooltip('Not about this'));
    await _settle(tester);
    expect(find.byKey(const Key('feedback-context')), findsNothing);

    await tester.enterText(find.byKey(const Key('feedback-subject')), 'Wrong one');
    await tester.enterText(find.byKey(const Key('feedback-body')), 'Never mind the listing.');
    await tester.dragUntilVisible(
      find.byKey(const Key('feedback-submit')),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const Key('feedback-submit')));
    await _settle(tester);
    final json = fakeRequests
        .firstWhere((r) => r.method == 'POST' && r.uri.path == '/feedback')
        .json as Map<String, dynamic>;
    expect(json['related_listing_id'], isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('a submission opens in full with the reply, and a follow-up starts from it',
      (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/feedback') return _page(const [_resolved]);
      if (uri.path == '/feedback/f-done') return _resolved;
      return null;
    });
    await tester.pumpWidget(
        const MaterialApp(home: FeedbackScreen(animateBackground: false)));
    await _settle(tester);
    expect(tester.takeException(), isNull);

    final card = find.byKey(const Key('feedback-item-f-done'));
    await tester.dragUntilVisible(card, find.byType(CustomScrollView), const Offset(0, -300));
    await _settle(tester);
    expect(find.text('Reply from BROKA'), findsOneWidget);
    await tester.tap(card);
    await _settle(tester);

    // The sheet re-reads the submission and shows every step and the reply.
    expect(fakeRequests.any((r) => r.method == 'GET' && r.uri.path == '/feedback/f-done'), isTrue);
    expect(find.text('Sent to the BROKA team'), findsOneWidget);
    expect(find.text('Resolved'), findsWidgets);
    expect(find.text('Reply from BROKA'), findsNWidgets(2));

    await tester.tap(find.text('Send a follow-up'));
    await _settle(tester);
    expect(find.text('Sent to the BROKA team'), findsNothing);
    expect(find.text('Re: Seller never showed #FDONE'), findsOneWidget);
    expect(find.text('File complaint'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('the history filters by progress', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/feedback') return _page(const [_open, _resolved]);
      return null;
    });
    await tester.pumpWidget(
        const MaterialApp(home: FeedbackScreen(animateBackground: false)));
    await _settle(tester);

    final done = find.byKey(const Key('feedback-filter-done'));
    await tester.dragUntilVisible(done, find.byType(CustomScrollView), const Offset(0, -300));
    await _settle(tester);
    await tester.tap(done);
    await _settle(tester);
    expect(find.byKey(const Key('feedback-item-f-open'), skipOffstage: false), findsNothing);
    expect(find.byKey(const Key('feedback-item-f-done'), skipOffstage: false), findsOneWidget);

    await tester.tap(find.byKey(const Key('feedback-filter-open')));
    await _settle(tester);
    expect(find.byKey(const Key('feedback-item-f-open'), skipOffstage: false), findsOneWidget);
    expect(find.byKey(const Key('feedback-item-f-done'), skipOffstage: false), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
