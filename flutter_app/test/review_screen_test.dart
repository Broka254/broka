// Leaving a review (2026-09-30). The screen called /reviews/my-deals and
// counted the backend's 201 on submit as a failure: no deal ever listed, and
// a review that did post showed an error, then "already reviewed" on retry.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/reviews/domain/models/review.dart';
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
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        return const FakeResponse({'id': 'r1', 'deal_id': 'd1', 'rating': 4},
            statusCode: 201);
      }
      return null;
    });
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

  testWidgets('a duplicate is closed with the already-reviewed state, not an error', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        return const FakeResponse(
            {'detail': 'You have already reviewed this deal'},
            statusCode: 409);
      }
      return null;
    });
    await open(tester, {'seller_id': 'seller-1', 'deal_id': 'd1'});
    await tester.tap(find.byIcon(Icons.star_outline_rounded).first);
    await tester.pump();
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pumpAndSettle();
    // Retrying a 409 can never succeed: the form closes and the buyer is
    // told the review already exists, rather than being invited to try again.
    expect(find.byKey(const Key('review-closed')), findsOneWidget);
    expect(find.text("You've already reviewed this deal. Thank you!"), findsOneWidget);
    expect(find.byKey(const Key('submit-review')), findsNothing);
  });

  testWidgets('a duplicate makes the caller refresh its stale eligibility', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        return const FakeResponse(
            {'detail': 'You have already reviewed this deal'},
            statusCode: 409);
      }
      return null;
    });

    Object? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(
        onPressed: () async {
          result = await Navigator.pushNamed(context, '/review', arguments: {
            'seller_id': 'seller-1', 'deal_id': 'd1',
          });
        },
        child: const Text('open review'),
      )),
      onGenerateRoute: (settings) => MaterialPageRoute(
        settings: settings,
        builder: (_) => const ReviewScreen(animateBackground: false),
      ),
    ));
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.star_outline_rounded).first);
    await tester.pump();
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pumpAndSettle();
    // Android's back gesture is another exit from the closed state. It must
    // return the same refresh signal as the Done button.
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // The review was written by another request/device. The store or profile
    // behind this screen must reload instead of keeping its old "Rate" button.
    expect(handled, isTrue);
    expect(result, isTrue);
  });

  testWidgets('system back after a posted review refreshes the caller', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        return const FakeResponse({'id': 'r1'}, statusCode: 201);
      }
      return null;
    });

    Object? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(
        onPressed: () async {
          result = await Navigator.pushNamed(context, '/review', arguments: {
            'seller_id': 'seller-1', 'deal_id': 'd1',
          });
        },
        child: const Text('open review'),
      )),
      onGenerateRoute: (settings) => MaterialPageRoute(
        settings: settings,
        builder: (_) => const ReviewScreen(animateBackground: false),
      ),
    ));
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3));
    await tester.pump();
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pumpAndSettle();
    expect(find.text('Review Submitted! 🌟'), findsOneWidget);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(result, isTrue);
  });

  testWidgets('leaving during a submission waits for the response before refreshing',
      (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        // The caller must not reload while this is still unresolved: the
        // review row may not exist yet, and it would keep its stale Rate
        // button even after the server commits.
        return const FakeResponse({'id': 'r1'},
            statusCode: 201, delay: Duration(seconds: 1));
      }
      return null;
    });

    Object? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(
        onPressed: () async {
          result = await Navigator.pushNamed(context, '/review', arguments: {
            'seller_id': 'seller-1', 'deal_id': 'd1',
          });
        },
        child: const Text('open review'),
      )),
      onGenerateRoute: (settings) => MaterialPageRoute(
        settings: settings,
        builder: (_) => const ReviewScreen(animateBackground: false),
      ),
    ));
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3));
    await tester.pump();
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pump();
    expect(find.text('Submitting your review…'), findsOneWidget);

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    expect(handled, isTrue);
    // The request is in flight, so the screen waits and explains why.
    expect(result, isNull);
    expect(find.text('Submitting your review…'), findsOneWidget);
    expect(find.text("We'll close this screen once your review is saved."),
        findsOneWidget);

    // Once the server confirms, the deferred back action completes with the
    // refresh signal the caller needs.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('a failed in-flight submission keeps the form despite a back request',
      (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        return const FakeResponse.error(
            statusCode: 503, delay: Duration(seconds: 1));
      }
      return null;
    });

    Object? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(
        onPressed: () async {
          result = await Navigator.pushNamed(context, '/review', arguments: {
            'seller_id': 'seller-1', 'deal_id': 'd1',
          });
        },
        child: const Text('open review'),
      )),
      onGenerateRoute: (settings) => MaterialPageRoute(
        settings: settings,
        builder: (_) => const ReviewScreen(animateBackground: false),
      ),
    ));
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3));
    await tester.pump();
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pump();
    expect(find.text('Submitting your review…'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(result, isNull);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byKey(const Key('submit-review')), findsOneWidget);
    expect(find.textContaining("Couldn't submit your review"), findsOneWidget);
  });

  testWidgets('a comment past the limit is refused, never silently cut', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        return const FakeResponse({'id': 'r1'}, statusCode: 201);
      }
      return null;
    });
    await open(tester, {'seller_id': 'seller-1', 'deal_id': 'd1'});
    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'x' * (maxReviewCommentLength + 1));
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pumpAndSettle();

    // The whole comment is still in the field: nothing truncated it.
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text.length,
        maxReviewCommentLength + 1);
    expect(find.textContaining('The limit is 500'), findsOneWidget);
    expect(fakeRequests.where((r) => r.method == 'POST'), isEmpty);

    // At the limit, exactly, it posts - trimmed.
    await tester.enterText(
        find.byType(TextField), '  ${'y' * maxReviewCommentLength}  ');
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pumpAndSettle();
    final post = fakeRequests.singleWhere((r) => r.method == 'POST');
    expect((post.json as Map)['comment'], 'y' * maxReviewCommentLength);
  });

  testWidgets('the limit counts Unicode code points, as the API does', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        return const FakeResponse({'id': 'r1'}, statusCode: 201);
      }
      return null;
    });
    await open(tester, {'seller_id': 'seller-1', 'deal_id': 'd1'});
    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3));
    await tester.pump();

    // 300 emoji are 300 code points (the API's count) but 600 UTF-16 units.
    // The old client check rejected a comment the backend accepts.
    final comment = List.filled(300, '🌟').join();
    await tester.enterText(find.byType(TextField), comment);
    await tester.pump();
    // The visible counter uses the same unit as the check: 300, not the
    // 600 UTF-16 units the field's built-in counter reported.
    expect(find.text('300/500'), findsOneWidget);
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pumpAndSettle();

    final post = fakeRequests.singleWhere((r) => r.method == 'POST');
    expect((post.json as Map)['comment'], comment);
    expect(find.text('Review Submitted! 🌟'), findsOneWidget);
  });

  testWidgets('a double tap submits once', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        return const FakeResponse({'id': 'r1'}, statusCode: 201,
            delay: Duration(milliseconds: 300));
      }
      return null;
    });
    await open(tester, {'seller_id': 'seller-1', 'deal_id': 'd1'});
    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3));
    await tester.pump();
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'), warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(fakeRequests.where((r) => r.method == 'POST'), hasLength(1));
    expect(find.text('Review Submitted! 🌟'), findsOneWidget);
  });

  testWidgets('a failed submission keeps the form and says what happened', (tester) async {
    setFakeRoute((uri) {
      if (uri.path == '/reviews/my-deals') {
        return {'deals': [_deal('d1', 'Samsung A54')]};
      }
      if (uri.path == '/reviews/') {
        return const FakeResponse.error(statusCode: 503);
      }
      return null;
    });
    await open(tester, {'seller_id': 'seller-1', 'deal_id': 'd1'});
    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3));
    await tester.pump();
    await tester.ensureVisible(find.text('Submit Review'));
    await tester.tap(find.text('Submit Review'));
    await tester.pumpAndSettle();

    // The buyer can try again with the words they wrote still in the form;
    // a network failure must not look like a posted review or erase input.
    expect(find.byKey(const Key('submit-review')), findsOneWidget);
    expect(find.text('Review Submitted! 🌟'), findsNothing);
    expect(find.textContaining("Couldn't submit your review"), findsOneWidget);
    expect(find.textContaining(RegExp('try again', caseSensitive: false)),
        findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('directly opened on a reviewed deal, it never shows the form', (tester) async {
    setFakeRoute((uri) => uri.path == '/reviews/my-deals'
        ? {'deals': [_deal('d1', 'Samsung A54', reviewed: true)]}
        : null);
    await open(tester, {
      'seller_id': 'seller-1',
      'seller_name': 'Grace Akinyi',
      'deal_id': 'd1',
      'listing_name': 'Samsung A54',
    });

    expect(find.byKey(const Key('review-closed')), findsOneWidget);
    expect(find.textContaining("You've already reviewed Grace Akinyi"), findsOneWidget);
    expect(find.byKey(const Key('submit-review')), findsNothing);
    expect(fakeRequests.where((r) => r.method == 'POST'), isEmpty);
  });

  testWidgets('a stale reviewed deal tells its caller to refresh eligibility',
      (tester) async {
    setFakeRoute((uri) => uri.path == '/reviews/my-deals'
        ? {'deals': [_deal('d1', 'Samsung A54', reviewed: true)]}
        : null);

    Object? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(
        onPressed: () async {
          result = await Navigator.pushNamed(context, '/review', arguments: {
            'seller_id': 'seller-1', 'deal_id': 'd1',
          });
        },
        child: const Text('open review'),
      )),
      onGenerateRoute: (settings) => MaterialPageRoute(
        settings: settings,
        builder: (_) => const ReviewScreen(animateBackground: false),
      ),
    ));
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-closed')), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('a failed eligibility check offers a retry, not a submittable form',
      (tester) async {
    setFakeRoute((uri) =>
        uri.path == '/reviews/my-deals' ? const FakeResponse.error() : null);
    await open(tester, {
      'seller_id': 'seller-1',
      'seller_name': 'Grace Akinyi',
      'deal_id': 'd1',
    });

    expect(find.byKey(const Key('review-load-error')), findsOneWidget);
    expect(find.byKey(const Key('submit-review')), findsNothing);
    expect(find.textContaining("Couldn't check this deal"), findsOneWidget);

    setFakeRoute((uri) => uri.path == '/reviews/my-deals'
        ? {'deals': [_deal('d1', 'Samsung A54')]}
        : null);
    await tester.tap(find.byKey(const Key('review-load-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('submit-review')), findsOneWidget);
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
