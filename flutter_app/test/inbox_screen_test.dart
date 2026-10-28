// The Inbox on Home's visual system (2026-09-26): the constellation, the
// collapsing header the Menu next to it uses, and cards like Home's -
// instead of a flat grey app bar over a plain background.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/main.dart' show BrokaColors;
import 'package:broka/screens/inbox_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/local_chat_store.dart';
import 'package:broka/widgets/broka_image.dart';
import 'package:broka/widgets/collapsing_screen_header.dart';
import 'package:broka/widgets/constellation_background.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _thread({
  required String listingId,
  required String listing,
  required String buyer,
  int unread = 0,
  String last = 'Is it still available?',
  String? listingImage,
  String lastMsgType = 'text',
  String lastRole = 'buyer',
  bool seen = false,
  bool delivered = false,
}) =>
    {
      'listing_id': listingId,
      'listing_name': listing,
      'listing_category': 'Electronics',
      'listing_price': 24000,
      'location_name': 'Westlands',
      'listing_type': 'fixed',
      'seller_id': 'u1',
      'seller_name': 'Grace Akinyi',
      'buyer_id': 'buyer-$buyer',
      'buyer_name': buyer,
      'my_role': 'seller',
      'last_message': last,
      'last_role': lastRole,
      'last_msg_type': lastMsgType,
      if (listingImage != null) 'listing_image': listingImage,
      'unread': unread,
      'last_message_seen': seen,
      'last_message_delivered': delivered,
      'time_ago': '5m',
      'is_online': true,
    };

void main() {
  setUpAll(() async {
    installFakeApi();
    // Real glyph widths for the overflow check: the test font draws every
    // character a full em wide and reports overflows no phone would show.
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
    ApiService.currentUserId = 'u1';
    setFakeRoute((uri) => uri.path == '/negotiate/inbox/u1'
        ? [
            _thread(listingId: 'l1', listing: 'HP EliteBook 840 G5', buyer: 'Amina Wanjiru', unread: 2),
            _thread(listingId: 'l1', listing: 'HP EliteBook 840 G5', buyer: 'Otieno', last: 'Deal at 21K?'),
            _thread(listingId: 'l2', listing: 'Samsung Galaxy A54 with a very long listing title',
                buyer: 'Kamau', unread: 1),
          ]
        : null);
  });

  final pushed = <RouteSettings>[];
  Widget app() => MaterialApp(
        home: const InboxScreen(animateBackground: false),
        onGenerateRoute: (settings) {
          pushed.add(settings);
          return MaterialPageRoute(builder: (_) => const Scaffold(body: Text('A THREAD')));
        },
      );

  testWidgets("on Home's visual system, with the unread count in the header",
      (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('INBOX'), findsOneWidget);
    expect(find.text('3 new'), findsOneWidget);
    expect(find.text('HP EliteBook 840 G5'), findsOneWidget);
    expect(find.text('2 conversations'), findsOneWidget);
  });

  testWidgets('a listing opens to its conversations, and a conversation opens',
      (tester) async {
    pushed.clear();
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.text('Amina Wanjiru'), findsNothing);

    await tester.tap(find.text('HP EliteBook 840 G5'));
    await _settle(tester);
    expect(find.text('Amina Wanjiru'), findsOneWidget);
    expect(find.text('Deal at 21K?'), findsOneWidget);

    await tester.tap(find.text('Amina Wanjiru'));
    await _settle(tester);
    // Her two unread messages are in the direct chat, and Zeno has nothing
    // new: the thread opens where they are (chat_screen_memory_test.dart).
    expect(pushed.last.name, '/direct-chat');
    expect((pushed.last.arguments as Map)['buyer_id'], 'buyer-Amina Wanjiru');
  });

  testWidgets('my last message ticks: single dull sent, dull double received, '
      'purple double read', (tester) async {
    // _thread's my_role is 'seller', so lastRole 'seller' makes the last
    // message mine - the only rows that carry a tick.
    setFakeRoute((uri) => uri.path == '/negotiate/inbox/u1'
        ? [
            _thread(listingId: 'l1', listing: 'HP EliteBook 840 G5',
                buyer: 'Sent Sam', lastRole: 'seller', last: 'One tick'),
            _thread(listingId: 'l1', listing: 'HP EliteBook 840 G5',
                buyer: 'Gotit Gail', lastRole: 'seller', delivered: true,
                last: 'Two dull ticks'),
            _thread(listingId: 'l1', listing: 'HP EliteBook 840 G5',
                buyer: 'Read Ruth', lastRole: 'seller', seen: true,
                delivered: true, last: 'Two purple ticks'),
          ]
        : null);
    await tester.pumpWidget(app());
    await _settle(tester);
    // One listing auto-expands; a group among several needs the tap.
    if (find.text('Sent Sam').evaluate().isEmpty) {
      await tester.tap(find.text('HP EliteBook 840 G5'));
      await _settle(tester);
    }

    Icon tickFor(String buyer) {
      final row = find.ancestor(of: find.text(buyer), matching: find.byType(InkWell));
      final ticks = tester.widgetList<Icon>(find.descendant(
          of: row,
          matching: find.byWidgetPredicate((w) =>
              w is Icon &&
              (w.icon == Icons.done_rounded || w.icon == Icons.done_all_rounded))));
      return ticks.single;
    }

    final sent = tickFor('Sent Sam');
    expect(sent.icon, Icons.done_rounded, reason: 'sent is a single tick');
    expect(sent.color, BrokaColors.textMid, reason: 'the single tick is dull');

    final delivered = tickFor('Gotit Gail');
    expect(delivered.icon, Icons.done_all_rounded,
        reason: 'received is a double tick');
    expect(delivered.color, BrokaColors.textMid,
        reason: 'received but unread stays dull');

    final read = tickFor('Read Ruth');
    expect(read.icon, Icons.done_all_rounded, reason: 'read is a double tick');
    expect(read.color, BrokaColors.neonPurple,
        reason: 'read is the purple double tick, not blue');
  });

  testWidgets('no conversations: says so and offers a way to start one',
      (tester) async {
    setFakeRoute((uri) => uri.path == '/negotiate/inbox/u1' ? <Object?>[] : null);
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.byType(BrokaEmptyState), findsOneWidget);
    expect(find.text('No conversations yet'), findsOneWidget);
    expect(find.text('Browse listings'), findsOneWidget);
  });

  testWidgets('a failed load with nothing saved offers a retry', (tester) async {
    setFakeRoute((uri) => uri.path == '/negotiate/inbox/u1' ? const FakeResponse.error() : null);
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.text("Couldn't load your inbox"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('the calls button says where it goes and opens call history',
      (tester) async {
    pushed.clear();
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.text('Call history'), findsOneWidget,
        reason: 'a bare phone icon does not say it opens call history');
    await tester.tap(find.byKey(const Key('inbox-calls')));
    await _settle(tester);
    expect(pushed.last.name, '/call-history');
  });

  testWidgets('a listing group shows the listing photo, not a category icon',
      (tester) async {
    const png = 'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    setFakeRoute((uri) => uri.path == '/negotiate/inbox/u1'
        ? [
            _thread(
                listingId: 'l9', listing: 'Airtel 5G router', buyer: 'Arnold',
                listingImage: png),
          ]
        : null);
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.byType(BrokaImage), findsOneWidget);
    expect(find.text('Airtel 5G router'), findsOneWidget);
  });

  testWidgets('a missed call is a conversation row with unread state, '
      'not a notification', (tester) async {
    setFakeRoute((uri) => uri.path == '/negotiate/inbox/u1'
        ? [
            _thread(
                listingId: 'l9', listing: 'Airtel 5G router', buyer: 'Arno',
                last: 'missed', lastMsgType: 'call', unread: 1),
          ]
        : null);
    await tester.pumpWidget(app());
    await _settle(tester);
    // The single listing auto-expands, so the thread row is visible.
    expect(find.text('Missed call'), findsOneWidget);
    expect(find.text('Missed call received'), findsNothing);
    expect(find.text('missed'), findsNothing);
    expect(find.byIcon(Icons.call_missed_rounded), findsOneWidget);
  });

  testWidgets('a server error with saved messages is not called offline, '
      'and recovers by itself', (tester) async {
    await LocalChatStore.save(LocalChatStore.inboxListScopeFor('u1'), [
      _thread(listingId: 'l1', listing: 'HP EliteBook 840 G5', buyer: 'Amina Wanjiru'),
    ]);
    setFakeRoute((uri) =>
        uri.path == '/negotiate/inbox/u1' ? const FakeResponse.error() : null);
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.textContaining("You're offline"), findsNothing,
        reason: 'a 500 from the server is not being offline');
    expect(find.textContaining('saved messages'), findsOneWidget);

    // Back online: the screen retries on its own instead of pinning the
    // stale banner until a manual pull-to-refresh.
    setFakeRoute((uri) => uri.path == '/negotiate/inbox/u1'
        ? [
            _thread(listingId: 'l1', listing: 'HP EliteBook 840 G5', buyer: 'Amina Wanjiru'),
          ]
        : null);
    await tester.pump(const Duration(seconds: 16));
    await _settle(tester);
    expect(find.textContaining('saved messages'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size',
      (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(app());
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('HP EliteBook 840 G5'));
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });
}

/// pumpAndSettle never returns (the constellation animates forever).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
