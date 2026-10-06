// The direct chat's call cards and header, as reported from a seller's
// phone (2026-10-06):
//
//  * "Call from You · 4d ago" sat under today's "Yooh". The chat socket
//    replays the thread on every connect, and the poll returns all of it;
//    anything the screen had not seen yet went to the bottom, however old.
//  * "Call from Buyer" carried an outgoing arrow although the call came
//    in; "Call cancelled from You" was red for a call the user hung up on;
//    and the buyer the header calls Arnold was "Buyer" on every card.
//  * A green dot beside "Active 22h ago": the dot was this phone's chat
//    socket, not the other person's presence.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/main.dart' show BrokaColors;
import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';

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
    ApiService.currentUserId = 'seller-1';
    ApiService.currentUserName = 'Xavier Bravin';
    clearFakeRequests();
  });

  // The seller's side of Arnold's thread.
  Widget chat() => MaterialApp(
        onGenerateRoute: (_) => MaterialPageRoute(
          settings: RouteSettings(arguments: {
            'listing': Listing.fromJson({
              ...fakeListingJson(1),
              'listing_type': 'fixed',
              'status': 'active',
            }),
            'role': 'seller',
            'buyer_id': 'buyer-1',
          }),
          builder: (_) => const NegotiationScreen(animateBackground: false),
        ),
      );

  final now = DateTime.now();
  Map<String, dynamic> call(String id, String role, String outcome, Duration ago,
          {String type = 'audio', int? secs}) =>
      {'id': id, 'role': role, 'msg_type': 'call', 'content': outcome,
       'call_type': type, 'duration_secs': secs, 'created_at': _iso(now.subtract(ago))};
  Map<String, dynamic> text(String id, String role, String words, Duration ago) =>
      {'id': id, 'role': role, 'content': words, 'created_at': _iso(now.subtract(ago))};

  void backend({required Object Function() history, bool online = false}) {
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') return history();
      if (p == '/auth/user/buyer-1') {
        return {
          'id': 'buyer-1',
          'name': 'Arnold',
          'is_online': online,
          'last_seen_label': online ? 'Active now' : 'Active 22h ago',
        };
      }
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });
  }

  double top(WidgetTester tester, String words) => tester.getTopLeft(find.text(words)).dy;

  testWidgets('an old call that reaches the screen late goes where it happened, not at the bottom',
      (tester) async {
    var polls = 0;
    backend(history: () {
      polls++;
      return [
        text('m1', 'seller', 'Hey', const Duration(days: 3)),
        text('m2', 'seller', 'Yooh', const Duration(minutes: 1)),
        // Not in the first answer - the socket's replay, or a poll, brings
        // it once the thread is already on screen.
        if (polls > 1) call('c1', 'seller', 'completed', const Duration(days: 4), secs: 75),
      ];
    });

    await tester.pumpWidget(chat());
    await _settle(tester);
    expect(find.text('Outgoing call'), findsNothing);

    await tester.pump(const Duration(seconds: 5)); // the 4-second poll
    await _settle(tester);
    expect(find.text('Outgoing call'), findsOneWidget);
    expect(top(tester, 'Outgoing call'), lessThan(top(tester, 'Hey')),
        reason: 'four days ago is before three days ago');
    expect(top(tester, 'Hey'), lessThan(top(tester, 'Yooh')));
  });

  testWidgets('a cache saved out of order reads in order', (tester) async {
    // What the old screen cached: an old call appended after a new message.
    SharedPreferences.setMockInitialValues({
      'chat_cache_v1_direct_listing-1_buyer-1': jsonEncode([
        text('m2', 'seller', 'Yooh', const Duration(minutes: 1)),
        call('c1', 'seller', 'completed', const Duration(days: 4)),
      ]),
    });
    // Offline: the cache is all there is.
    backend(history: () => const FakeResponse.error());

    await tester.pumpWidget(chat());
    await _settle(tester);
    expect(find.text('Outgoing call'), findsOneWidget);
    expect(top(tester, 'Outgoing call'), lessThan(top(tester, 'Yooh')));
  });

  testWidgets('each card says which way the call went and how it ended', (tester) async {
    backend(history: () => [
      call('c1', 'buyer', 'completed', const Duration(days: 4), secs: 75),
      call('c2', 'seller', 'cancelled', const Duration(days: 2)),
      call('c3', 'buyer', 'cancelled', const Duration(hours: 5), type: 'video'),
      call('c4', 'buyer', 'declined', const Duration(hours: 3)),
      call('c5', 'seller', 'missed', const Duration(hours: 1)),
    ]);
    await tester.pumpWidget(chat());
    await _settle(tester);

    // Arnold called and I answered: incoming, not the outgoing arrow.
    expect(find.text('Incoming call'), findsNWidgets(2));
    expect(find.text('1:15 · 4d ago'), findsOneWidget);
    expect(find.byIcon(Icons.call_received_rounded), findsNWidgets(2));
    // I rang and hung up first: my own cancelled call, not an alarm.
    expect(find.text('Cancelled · 2d ago'), findsOneWidget);
    expect(find.text('No answer · 1h ago'), findsOneWidget);
    expect(find.text('Outgoing call'), findsNWidgets(2));
    expect(find.byIcon(Icons.call_made_rounded), findsNWidgets(2));
    // Arnold rang and gave up before I answered: missed, to me.
    expect(find.text('Missed video call'), findsOneWidget);
    expect(find.text('5h ago'), findsOneWidget);
    expect(find.byIcon(Icons.call_missed_rounded), findsOneWidget);
    final missedTitle = tester.widget<Text>(find.text('Missed video call'));
    expect(missedTitle.style!.color, BrokaColors.danger);
    expect(find.text('You declined · 3h ago'), findsOneWidget);
    // A call back on the calls that came in and were not answered only.
    expect(find.text('Call back'), findsNWidgets(2));

    expect(find.textContaining('from Buyer'), findsNothing);
    expect(find.textContaining('from You'), findsNothing);
  });

  testWidgets("the header's dot is the other person's presence", (tester) async {
    backend(history: () => <Object>[], online: false);
    await tester.pumpWidget(chat());
    await _settle(tester);
    expect(find.text('Active 22h ago'), findsOneWidget);
    expect(dotColour(tester), BrokaColors.textLow);
    expect(find.text('Message Arnold'), findsOneWidget);
  });

  testWidgets("the header's dot is green while they are online", (tester) async {
    backend(history: () => <Object>[], online: true);
    await tester.pumpWidget(chat());
    await _settle(tester);
    expect(find.text('Active now'), findsOneWidget);
    expect(dotColour(tester), BrokaColors.neonGreen);
  });
}

Color? dotColour(WidgetTester tester) {
  final dot = tester.widget<Container>(find.byKey(const Key('direct-chat-presence-dot')));
  return (dot.decoration as BoxDecoration?)?.color;
}

/// pumpAndSettle never returns (the constellation and typing dots animate).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
