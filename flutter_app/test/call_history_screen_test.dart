// Calls (2026-10-02): every call with a buyer or seller, newest first, on
// Home's visual system. Calls were only ever cards inside each chat, so
// finding a missed call meant opening every conversation.
import 'dart:io';

import 'package:broka/features/calls/domain/call_record.dart';
import 'package:broka/features/calls/presentation/call_history_screen.dart';
import 'package:broka/screens/inbox_screen.dart';
import 'package:broka/screens/menu_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/collapsing_screen_header.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';

String _iso(DateTime local) => local.toUtc().toIso8601String();

Map<String, dynamic> _history() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 12, 5);
  final yesterday = today.subtract(const Duration(days: 1));
  return {
    'calls': [
      {
        'id': 'c1', 'listing_id': 'listing-1', 'listing_name': 'Airtel 5G router',
        'buyer_id': 'buyer-7', 'my_role': 'seller', 'peer_id': 'buyer-7',
        'direction': 'incoming', 'outcome': 'cancelled', 'missed': true,
        'call_type': 'audio', 'duration_secs': null, 'created_at': _iso(today),
      },
      {
        'id': 'c2', 'listing_id': 'listing-1', 'listing_name': 'Airtel 5G router',
        'buyer_id': 'buyer-7', 'my_role': 'seller', 'peer_id': 'buyer-7',
        'direction': 'outgoing', 'outcome': 'completed', 'missed': false,
        'call_type': 'video', 'duration_secs': 135, 'created_at': _iso(yesterday),
      },
      {
        'id': 'c3', 'listing_id': 'listing-2', 'listing_name': 'HP EliteBook',
        'buyer_id': 'seller-me', 'my_role': 'buyer', 'peer_id': 'seller-2',
        'direction': 'outgoing', 'outcome': 'missed', 'missed': false,
        'call_type': 'audio', 'duration_secs': null, 'created_at': _iso(yesterday),
      },
    ],
    'people': {
      'buyer-7': {'name': 'Amina Wanjiru', 'photo': null, 'is_online': true},
      'seller-2': {'name': 'Grace Akinyi', 'photo': null, 'is_online': false},
    },
    'next_before': null,
  };
}

void main() {
  setUpAll(() async {
    installFakeApi();
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts';
    if (Directory(fonts).existsSync()) {
      final roboto = FontLoader('Roboto');
      for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
        roboto.addFont(Future.value(ByteData.view(File('$fonts/$f').readAsBytesSync().buffer)));
      }
      await roboto.load();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'seller-me';
    clearFakeRequests();
    setFakeRoute((uri) {
      if (uri.path == '/calls/history') return _history();
      if (uri.path == '/calls/initiate') {
        return {'status': 'sent', 'room_id': 'room-9', 'call_token': 't'};
      }
      return null;
    });
  });

  final pushed = <RouteSettings>[];
  Widget app() => MaterialApp(
        home: const CallHistoryScreen(animateBackground: false),
        onGenerateRoute: (settings) {
          pushed.add(settings);
          return MaterialPageRoute(builder: (_) => const Scaffold(body: Text('PUSHED')));
        },
      );

  group('what a call says', () {
    CallRecord record(Map<String, dynamic> j) =>
        CallHistoryPage.fromJson({'calls': [j], 'people': {}}).calls.single;
    Map<String, dynamic> base(String direction, String outcome, {bool missed = false, int? secs}) => {
          'id': 'x', 'listing_id': 'l', 'buyer_id': 'b', 'peer_id': 'p', 'my_role': 'buyer',
          'direction': direction, 'outcome': outcome, 'missed': missed, 'duration_secs': secs,
        };

    test('from the side of the person reading it', () {
      expect(record(base('incoming', 'cancelled', missed: true)).summary, 'Missed');
      expect(record(base('outgoing', 'missed')).summary, 'No answer');
      expect(record(base('outgoing', 'cancelled')).summary, 'Cancelled');
      expect(record(base('outgoing', 'declined')).summary, 'Declined');
      expect(record(base('incoming', 'declined')).summary, 'You declined');
      expect(record(base('incoming', 'completed', secs: 75)).summary, '1:15');
      expect(record(base('incoming', 'completed')).summary, 'Answered');
      expect(formatCallDuration(3725), '1:02:05');
    });

    test("someone with no name is called by their side of the deal", () {
      expect(record(base('incoming', 'completed')).peerDisplayName, 'Seller');
      expect(record({...base('incoming', 'completed'), 'my_role': 'seller'}).peerDisplayName, 'Buyer');
    });

    test('a call missing what identifies it is dropped, not shown broken', () {
      final page = CallHistoryPage.fromJson({
        'calls': [
          {'id': 'x'},
          base('incoming', 'completed'),
        ],
        'people': {},
      });
      expect(page.calls, hasLength(1));
    });
  });

  testWidgets("on Home's visual system, newest first, by day", (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(find.text('CALLS'), findsOneWidget);
    expect(find.text('1 missed'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('Amina Wanjiru'), findsNWidgets(2));
    expect(find.text('Grace Akinyi'), findsOneWidget);
    expect(find.text('Incoming · Missed'), findsOneWidget);
    expect(find.text('Outgoing · 2:15'), findsOneWidget);
    expect(find.text('Outgoing · No answer'), findsOneWidget);
    expect(find.text('Buyer · Airtel 5G router'), findsNWidgets(2));
    expect(find.text('Seller · HP EliteBook'), findsOneWidget);
    expect(find.text('12:05'), findsWidgets);
  });

  testWidgets('Missed shows only the calls the user missed', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.text('Missed (1)'));
    await _settle(tester);
    expect(find.text('Incoming · Missed'), findsOneWidget);
    expect(find.text('Grace Akinyi'), findsNothing);
    expect(find.text('Outgoing · 2:15'), findsNothing);
  });

  testWidgets('a call opens the chat it happened in', (tester) async {
    pushed.clear();
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.text('Seller · HP EliteBook'));
    await _settle(tester);
    expect(pushed.last.name, '/direct-chat');
    expect(pushed.last.arguments,
        {'listingId': 'listing-2', 'role': 'buyer', 'buyer_id': 'seller-me'});
  });

  testWidgets('calling back rings the same person, the same kind of call', (tester) async {
    pushed.clear();
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.byKey(const Key('call-back-c2')));
    await _settle(tester);

    final sent = fakeRequests.singleWhere((r) => r.uri.path == '/calls/initiate').json as Map;
    expect(sent['listing_id'], 'listing-1');
    expect(sent['call_type'], 'video');
    expect(sent['callee_id'], 'buyer-7', reason: 'a seller has to say which buyer');
    final call = pushed.singleWhere((r) => r.name == '/voip-call').arguments as Map;
    expect(call['peerName'], 'Amina Wanjiru');
    expect(call['peerId'], 'buyer-7');
    expect(call['isCaller'], isTrue);
  });

  testWidgets('no calls yet says so', (tester) async {
    setFakeRoute((uri) => uri.path == '/calls/history'
        ? {'calls': <Object?>[], 'people': <String, Object?>{}, 'next_before': null}
        : null);
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.byType(BrokaEmptyState), findsOneWidget);
    expect(find.text('No calls yet'), findsOneWidget);
  });

  testWidgets('a failed load offers a retry, and the retry loads', (tester) async {
    var fail = true;
    setFakeRoute((uri) {
      if (uri.path != '/calls/history') return null;
      return fail ? const FakeResponse.error() : _history();
    });
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.text("Couldn't load your calls"), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(find.text('Grace Akinyi'), findsOneWidget);
  });

  testWidgets('the next page loads when the list is scrolled to its end', (tester) async {
    final first = _history();
    setFakeRoute((uri) {
      if (uri.path != '/calls/history') return null;
      if (uri.queryParameters['before'] == null) return {...first, 'next_before': 'cursor-1'};
      return {
        'calls': [
          {
            'id': 'c9', 'listing_id': 'listing-3', 'listing_name': 'Bike',
            'buyer_id': 'seller-me', 'my_role': 'buyer', 'peer_id': 'seller-3',
            'direction': 'incoming', 'outcome': 'completed', 'missed': false,
            'call_type': 'audio', 'duration_secs': 10, 'created_at': '2025-01-05T09:00:00Z',
          },
        ],
        'people': {'seller-3': {'name': 'Otieno', 'photo': null, 'is_online': false}},
        'next_before': null,
      };
    });
    await tester.pumpWidget(app());
    await _settle(tester);
    // Three cards leave the list short of the screen: it asks at once.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await _settle(tester);
    expect(fakeRequests.where((r) => r.uri.queryParameters['before'] == 'cursor-1'), hasLength(1));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await _settle(tester);
    expect(find.text('Otieno'), findsOneWidget);
    expect(find.text('5 JAN 2025'), findsOneWidget);
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Inbox opens Calls from its header', (tester) async {
    pushed.clear();
    setFakeRoute((uri) => uri.path == '/negotiate/inbox/seller-me' ? <Object?>[] : null);
    await tester.pumpWidget(MaterialApp(
      home: const InboxScreen(animateBackground: false),
      onGenerateRoute: (settings) {
        pushed.add(settings);
        return MaterialPageRoute(builder: (_) => const SizedBox());
      },
    ));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('inbox-calls')));
    await _settle(tester);
    expect(pushed.last.name, '/call-history');
  });

  testWidgets('the Menu lists Calls', (tester) async {
    setFakeRoute((uri) => uri.path == '/auth/me' ? {'id': 'seller-me', 'name': 'Sam'} : null);
    await tester.pumpWidget(const MaterialApp(home: MenuScreen(animateBackground: false)));
    await _settle(tester);
    await tester.scrollUntilVisible(find.text('Calls'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Voice and video calls with buyers and sellers'), findsOneWidget);
  });
}

/// pumpAndSettle never returns (the constellation animates forever).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
