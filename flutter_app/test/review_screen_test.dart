// Leaving a review (2026-09-30). The screen called /reviews/my-deals and
// counted the backend's 201 on submit as a failure: no deal ever listed, and
// a review that did post showed an error, then "already reviewed" on retry.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/reviews/presentation/review_prompt.dart';
import 'package:broka/screens/review_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _deal(String id, String listing, {bool reviewed = false}) => {
      'deal_id': id, 'seller_id': 'seller-1', 'seller_name': 'Grace Akinyi',
      'listing_name': listing, 'agreed_price': 32000, 'created_at': '2026-09-01T10:00:00',
      'completed_at': '2026-09-03T10:00:00', 'already_reviewed': reviewed,
    };

void main() {
  setUpAll(installFakeApi);

  setUp(() async {
    SharedPreferences.setMockInitialValues({'auth_token': 'tok', 'user_id': 'buyer-1'});
    await ApiService.loadSavedSession();
    clearFakeRequests();
  });

  tearDown(() => setFakeRoute(null));

  Future<void> open(WidgetTester tester, Map<String, dynamic> args) async {
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (s) => MaterialPageRoute(
        settings: RouteSettings(name: '/review', arguments: args),
        builder: (_) => const ReviewScreen(animateBackground: false),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets("lists the buyer's completed deals with this seller", (tester) async {
    setFakeRoute((uri) => uri.path == '/reviews/my-deals'
        ? {'deals': [_deal('d1', 'Samsung A54'), _deal('d2', 'JBL Flip 6'),
                     _deal('d3', 'Old charger', reviewed: true)]}
        : null);
    await open(tester, {'seller_id': 'seller-1', 'seller_name': 'Grace Akinyi'});

    final ask = fakeRequests.singleWhere((r) => r.uri.path == '/reviews/my-deals');
    expect(ask.uri.queryParameters['seller_id'], 'seller-1');
    expect(find.text('Samsung A54'), findsOneWidget);
    expect(find.text('JBL Flip 6'), findsOneWidget);
    // Reviewed already: not offered again.
    expect(find.text('Old charger'), findsNothing);
  });

  testWidgets('a review the backend accepts (201) is shown as posted', (tester) async {
    setFakeRoute((uri) => uri.path == '/reviews/'
        ? const FakeResponse({'id': 'r1', 'deal_id': 'd1', 'rating': 4}, statusCode: 201)
        : null);
    await open(tester, {'seller_id': 'seller-1', 'seller_name': 'Grace Akinyi',
                        'deal_id': 'd1', 'listing_name': 'Samsung A54'});

    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'As described.');
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pumpAndSettle();

    final post = fakeRequests.singleWhere((r) => r.method == 'POST');
    expect(post.uri.path, '/reviews/');
    expect(post.json, {'deal_id': 'd1', 'rating': 4, 'comment': 'As described.'});
    expect(find.text('Review Submitted! 🌟'), findsOneWidget);
  });

  testWidgets("the backend's refusal is shown as it says it", (tester) async {
    setFakeRoute((uri) => uri.path == '/reviews/'
        ? const FakeResponse({'detail': 'You have already reviewed this deal'}, statusCode: 409)
        : null);
    await open(tester, {'seller_id': 'seller-1', 'deal_id': 'd1'});
    await tester.tap(find.byIcon(Icons.star_outline_rounded).first);
    await tester.pump();
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pumpAndSettle();
    expect(find.text('You have already reviewed this deal'), findsOneWidget);
  });

  group('opened from the "Deal Complete" notification', () {
    testWidgets('the notification opens the review screen for its deal', (tester) async {
      final key = GlobalKey<NavigatorState>();
      NotificationService.instance.navigatorKey = key;
      RouteSettings? opened;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        home: const SizedBox(),
        onGenerateRoute: (s) {
          opened = s;
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
      ));
      // What api/core/push_subscribers.py sends the buyer on release.
      await NotificationService.instance.navigateFromPayload({
        'type': 'deal_status', 'deal_id': 'd1', 'status': 'released', 'screen': 'review',
      });
      await tester.pump();
      expect(opened?.name, '/review');
      expect(opened?.arguments, {'deal_id': 'd1'});
    });

    testWidgets('with only the deal id, it finds out who and what', (tester) async {
      setFakeRoute((uri) => uri.path == '/reviews/my-deals'
          ? {'deals': [_deal('d1', 'Samsung A54')]}
          : null);
      await open(tester, {'deal_id': 'd1'});
      expect(find.text('Rate Grace Akinyi'), findsOneWidget);
      expect(find.text('Samsung A54'), findsOneWidget);
      expect(find.byKey(const Key('submit-review')), findsOneWidget);
    });

    testWidgets('a deal already reviewed says so', (tester) async {
      setFakeRoute((uri) => uri.path == '/reviews/my-deals'
          ? {'deals': [_deal('d1', 'Samsung A54', reviewed: true)]}
          : null);
      await open(tester, {'deal_id': 'd1'});
      expect(find.byKey(const Key('review-closed')), findsOneWidget);
      expect(find.textContaining("You've already reviewed Grace Akinyi"), findsOneWidget);
      expect(find.byKey(const Key('submit-review')), findsNothing);
    });
  });

  group('asked when the deal completes', () {
    final opened = <RouteSettings>[];
    setUp(opened.clear);

    Future<void> prompt(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) => TextButton(
          onPressed: () => promptReviewIfDue(context, dealId: 'd1', sellerId: 'seller-1'),
          child: const Text('released'),
        )),
        onGenerateRoute: (s) {
          opened.add(s);
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
      ));
      await tester.tap(find.text('released'));
      await tester.pumpAndSettle();
    }

    testWidgets('a completed, unreviewed deal is offered for review', (tester) async {
      setFakeRoute((uri) => uri.path == '/reviews/my-deals'
          ? {'deals': [_deal('d1', 'Samsung A54')]}
          : null);
      await prompt(tester);
      expect(find.byKey(const Key('review-prompt')), findsOneWidget);
      expect(find.text('Rate Grace Akinyi'), findsOneWidget);
      await tester.tap(find.byKey(const Key('review-prompt-rate')));
      await tester.pumpAndSettle();
      // The review opens on that deal, straight to the form.
      expect(opened.single.name, '/review');
      expect(opened.single.arguments, {
        'deal_id': 'd1', 'seller_id': 'seller-1',
        'seller_name': 'Grace Akinyi', 'listing_name': 'Samsung A54',
      });
    });

    testWidgets('nothing is asked for a deal already reviewed, or not yet released', (tester) async {
      setFakeRoute((uri) => uri.path == '/reviews/my-deals'
          ? {'deals': [_deal('d1', 'Samsung A54', reviewed: true)]}
          : null);
      await prompt(tester);
      expect(find.byKey(const Key('review-prompt')), findsNothing);

      setFakeRoute((uri) => uri.path == '/reviews/my-deals' ? {'deals': []} : null);
      await prompt(tester);
      expect(find.byKey(const Key('review-prompt')), findsNothing);
      expect(opened, isEmpty);
    });
  });
}
