// The keyboard covering the chat (reported from a phone, 2026-11-13, with
// screenshots): opening it shrank the message list from the bottom, and the
// list kept its scroll offset, so the messages being answered slid under
// the composer and the keyboard. KeepLatestInView keeps the newest message
// in view as the list shrinks - and leaves alone someone reading back.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/keep_latest_in_view.dart';

import 'support/fake_api.dart';

String _iso(DateTime t) => t.toUtc().toIso8601String();

void main() {
  setUpAll(() {
    installFakeApi();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'com.llfbandit.record/messages',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'buyer-1';
    ApiService.currentUserName = 'Amina Wanjiru';
    clearFakeRequests();
  });

  Widget chat() => MaterialApp(
        onGenerateRoute: (_) => MaterialPageRoute(
          settings: RouteSettings(arguments: {
            'listing': Listing.fromJson({
              ...fakeListingJson(1),
              'listing_type': 'fixed',
              'status': 'active',
            }),
            'role': 'buyer',
          }),
          builder: (_) => const NegotiationScreen(animateBackground: false),
        ),
      );

  void longThread() {
    final start = DateTime.now().subtract(const Duration(hours: 2));
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return [
          for (var i = 0; i < 30; i++)
            {
              'role': i.isEven ? 'seller' : 'buyer',
              'content': 'Message number $i',
              'id': 'm$i',
              'created_at': _iso(start.add(Duration(minutes: i))),
            },
        ];
      }
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });
  }

  double composerTop(WidgetTester tester) =>
      tester.getRect(find.byKey(const Key('direct-chat-composer'))).top;

  testWidgets('the newest message stays above the composer as the keyboard opens',
      (tester) async {
    addTearDown(tester.view.reset);
    longThread();
    await tester.pumpWidget(chat());
    await _settle(tester);
    expect(find.byType(KeepLatestInView), findsOneWidget);
    expect(tester.getRect(find.text('Message number 29')).bottom,
        lessThanOrEqualTo(composerTop(tester)));

    await tester.tap(find.byKey(const Key('direct-chat-composer')));
    // The keyboard slides up over a few frames.
    for (final inset in [300.0, 600.0, 900.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _settle(tester);

    expect(tester.getRect(find.text('Message number 29')).bottom,
        lessThanOrEqualTo(composerTop(tester)),
        reason: 'the message being answered is not under the composer or the keyboard');
  });

  testWidgets('someone reading back is not pulled to the bottom', (tester) async {
    addTearDown(tester.view.reset);
    longThread();
    await tester.pumpWidget(chat());
    await _settle(tester);

    // Scroll up to the start of the thread.
    await tester.fling(find.text('Message number 25'), const Offset(0, 4000), 4000);
    await _settle(tester);
    expect(find.text('Message number 0'), findsOneWidget);
    final top = tester.getRect(find.text('Message number 0')).top;

    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await _settle(tester);

    expect(tester.getRect(find.text('Message number 0')).top, top);
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
