// The Inbox opens the screen the user was using (2026-10-02).
//
// Reported from a phone: someone who had moved a deal to the direct chat was
// put back in Zeno's room every time they opened it from the Inbox. Each
// thread now remembers which of its two screens the user was last on, and
// the Inbox opens that one - unless only the other has something new: the
// other person wrote in the direct chat (`unread`), or Zeno said something
// in its room (`zeno_unread`). A notification about a Zeno message opens
// Zeno's room, where that message is.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/models/listing.dart';
import 'package:broka/screens/inbox_screen.dart';
import 'package:broka/screens/negotiate_screen.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/chat_screen_memory.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:broka/services/notification_service.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _thread({int unread = 0, int zenoUnread = 0, String role = 'buyer'}) => {
      'listing_id': 'listing-1',
      'listing_name': 'HP EliteBook 840 G5',
      'listing_category': 'Electronics',
      'listing_price': 24000,
      'location_name': 'Westlands',
      'listing_type': 'fixed',
      'seller_id': 'seller-1',
      'seller_name': 'Xavier Bravin',
      'buyer_id': 'buyer-1',
      'buyer_name': 'Amina Wanjiru',
      'my_role': role,
      'last_message': 'Is it still available?',
      'last_role': role == 'buyer' ? 'seller' : 'buyer',
      'unread': unread,
      'zeno_unread': zenoUnread,
      'last_message_seen': false,
      'time_ago': '5m',
      'is_online': true,
    };

void main() {
  setUpAll(() async {
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

  group('which screen a thread opens on', () {
    const zeno = ChatScreen.zeno;
    const direct = ChatScreen.direct;

    test('the one the user was last on, when nothing is new', () {
      expect(ChatScreenMemory.choose(remembered: direct, directUnread: 0, zenoUnread: 0), direct);
      expect(ChatScreenMemory.choose(remembered: zeno, directUnread: 0, zenoUnread: 0), zeno);
    });

    test('the other one, when only it has something new', () {
      expect(ChatScreenMemory.choose(remembered: direct, directUnread: 0, zenoUnread: 2), zeno);
      expect(ChatScreenMemory.choose(remembered: zeno, directUnread: 1, zenoUnread: 0), direct);
    });

    test('still the user\'s own, when both have something new', () {
      expect(ChatScreenMemory.choose(remembered: direct, directUnread: 1, zenoUnread: 3), direct);
      expect(ChatScreenMemory.choose(remembered: zeno, directUnread: 1, zenoUnread: 3), zeno);
    });

    test('a thread never opened here: Zeno\'s room, as before, unless only the chat has news', () {
      expect(ChatScreenMemory.choose(remembered: null, directUnread: 0, zenoUnread: 0), zeno);
      expect(ChatScreenMemory.choose(remembered: null, directUnread: 0, zenoUnread: 4), zeno);
      expect(ChatScreenMemory.choose(remembered: null, directUnread: 2, zenoUnread: 0), direct);
    });

    test('remembered per thread, and only for a thread it can name', () async {
      SharedPreferences.setMockInitialValues({});
      await ChatScreenMemory.remember('listing-1', 'buyer-1', direct);
      await ChatScreenMemory.remember('listing-1', 'buyer-2', zeno);
      await ChatScreenMemory.remember('listing-1', null, direct);
      expect(await ChatScreenMemory.recall('listing-1', 'buyer-1'), direct);
      expect(await ChatScreenMemory.recall('listing-1', 'buyer-2'), zeno);
      expect(await ChatScreenMemory.recall('listing-2', 'buyer-1'), isNull);
      expect(await ChatScreenMemory.recall('listing-1', null), isNull);
    });
  });

  group('the Inbox', () {
    final pushed = <RouteSettings>[];
    Widget inbox() => MaterialApp(
          home: const InboxScreen(animateBackground: false),
          onGenerateRoute: (settings) {
            pushed.add(settings);
            return MaterialPageRoute(builder: (_) => const Scaffold(body: Text('A THREAD')));
          },
        );

    Future<String?> openThread(WidgetTester tester, Map<String, dynamic> thread) async {
      pushed.clear();
      setFakeRoute((uri) => uri.path == '/negotiate/inbox/buyer-1' ? [thread] : null);
      await tester.pumpWidget(inbox());
      await _settle(tester);
      await tester.tap(find.text('Xavier Bravin'));
      await _settle(tester);
      return pushed.isEmpty ? null : pushed.last.name;
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ApiService.currentUserId = 'buyer-1';
    });

    testWidgets('opens the direct chat for someone who was using it', (tester) async {
      SharedPreferences.setMockInitialValues({'chat_screen_listing-1_buyer-1': 'direct'});
      expect(await openThread(tester, _thread()), '/direct-chat');
      final args = pushed.last.arguments as Map;
      expect(args['buyer_id'], 'buyer-1');
      expect(args['role'], 'buyer');
      expect(args['listing'], isA<Listing>());
    });

    testWidgets("goes to Zeno's room when Zeno has said something new there", (tester) async {
      SharedPreferences.setMockInitialValues({'chat_screen_listing-1_buyer-1': 'direct'});
      expect(await openThread(tester, _thread(zenoUnread: 1)), '/negotiate');
    });

    testWidgets("stays in Zeno's room for someone who uses it", (tester) async {
      SharedPreferences.setMockInitialValues({'chat_screen_listing-1_buyer-1': 'zeno'});
      expect(await openThread(tester, _thread()), '/negotiate');
    });

    testWidgets('goes to the direct chat when the other person wrote there', (tester) async {
      SharedPreferences.setMockInitialValues({'chat_screen_listing-1_buyer-1': 'zeno'});
      expect(await openThread(tester, _thread(unread: 2)), '/direct-chat');
    });

    testWidgets("an older server's inbox, with no zeno_unread, still opens", (tester) async {
      SharedPreferences.setMockInitialValues({'chat_screen_listing-1_buyer-1': 'direct'});
      expect(await openThread(tester, _thread()..remove('zeno_unread')), '/direct-chat');
    });
  });

  group('the two screens remember themselves', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ApiService.currentUserId = 'buyer-1';
      ApiService.currentUserName = 'Amina Wanjiru';
      clearFakeRequests();
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/inbox/buyer-1') return [_thread()];
        if (p == '/negotiate/listing-1/history') {
          return [
            {'role': 'broker', 'content': 'Welcome back, Amina.', 'id': 'm1'},
            {'role': 'seller', 'content': 'Is it still available?', 'id': 'm3'},
          ];
        }
        if (p == '/negotiate/message') {
          return {'role': 'broker', 'content': 'I asked him.', 'id': 'm5'};
        }
        if (p.startsWith('/negotiate/deal-status')) return {'has_deal': false};
        if (p == '/auth/user/seller-1') return {'id': 'seller-1', 'name': 'Xavier Bravin'};
        return null;
      });
    });

    testWidgets('moving to the direct chat is where the thread opens next time', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: const InboxScreen(animateBackground: false),
        onGenerateRoute: (settings) => MaterialPageRoute(
          settings: settings,
          builder: (_) => switch (settings.name) {
            '/direct-chat' => const NegotiationScreen(animateBackground: false),
            _ => const NegotiateScreen(animateBackground: false),
          },
        ),
      ));
      await _settle(tester);

      // First time: Zeno's room, as always.
      await tester.tap(find.text('Xavier Bravin'));
      await _settle(tester);
      expect(find.byType(NegotiateScreen), findsOneWidget);
      expect(await ChatScreenMemory.recall('listing-1', 'buyer-1'), ChatScreen.zeno);

      // The user moves to the direct chat, then goes back to the Inbox.
      await tester.tap(find.byTooltip('Chat directly'));
      await _settle(tester);
      expect(find.byType(NegotiationScreen), findsOneWidget);
      expect(await ChatScreenMemory.recall('listing-1', 'buyer-1'), ChatScreen.direct);
      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);
      expect(find.byType(InboxScreen), findsOneWidget);

      // Next time: the direct chat, not Zeno's room.
      await tester.tap(find.text('Xavier Bravin'));
      await _settle(tester);
      expect(find.byType(NegotiationScreen), findsOneWidget);
      expect(find.byType(NegotiateScreen), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
    });

    testWidgets("Zeno's room tells the server its messages were seen", (tester) async {
      await tester.pumpWidget(_room(const NegotiateScreen(animateBackground: false)));
      await _settle(tester);
      expect(_zenoReads(), hasLength(1), reason: 'once the history is on screen');

      await tester.enterText(find.byKey(const Key('negotiate-composer')), 'Ask him');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await _settle(tester);
      expect(_zenoReads(), hasLength(2), reason: "and again once Zeno's reply is");
      // Nothing of the other person's is marked read by it.
      expect(fakeRequests.where((r) => r.uri.path.endsWith('/mark-read')), isEmpty);

      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
    });

    testWidgets("a seller's Zeno room is the buyer they opened", (tester) async {
      ApiService.currentUserId = 'seller-1';
      await tester.pumpWidget(_room(const NegotiateScreen(animateBackground: false),
          role: 'seller', buyerId: 'buyer-7'));
      await _settle(tester);
      final history = fakeRequests.firstWhere((r) => r.uri.path == '/negotiate/listing-1/history');
      expect(history.uri.queryParameters['buyer_id'], 'buyer-7',
          reason: 'without it the server answers with the latest buyer\'s room');
      expect((_zenoReads().single.json as Map)['buyer_id'], 'buyer-7');
      expect(await ChatScreenMemory.recall('listing-1', 'buyer-7'), ChatScreen.zeno);

      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
    });
  });

  group('notifications', () {
    testWidgets("a Zeno message's notification opens Zeno's room", (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final opened = <RouteSettings>[];
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const SizedBox(),
        onGenerateRoute: (settings) {
          opened.add(settings);
          return MaterialPageRoute(settings: settings, builder: (_) => const SizedBox());
        },
      ));
      NotificationService.instance.navigatorKey = nav;
      final base = {'type': 'new_message', 'listingId': 'listing-1', 'buyerId': 'buyer-1', 'myRole': 'buyer'};
      await NotificationService.instance.navigateFromPayload({...base, 'screen': 'zeno'});
      await tester.pump();
      await NotificationService.instance.navigateFromPayload(base);
      await tester.pump();
      expect(opened.map((s) => s.name), ['/negotiate', '/direct-chat']);
      expect(opened.first.arguments, {'listingId': 'listing-1', 'role': 'buyer', 'buyer_id': 'buyer-1'});
    });

    test("the poller marks Zeno's messages as Zeno's", () async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final shown = <Map<String, dynamic>>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'), (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'show') shown.add(Map<String, dynamic>.from(call.arguments as Map));
        return null;
      });
      await NotificationService.instance.initialize(
          navKey: GlobalKey<NavigatorState>(), requestPermission: false);
      debugDefaultTargetPlatformOverride = null;

      SharedPreferences.setMockInitialValues({'global_poll_primed_v1': true});
      ApiService.currentUserId = 'buyer-1';
      GlobalPollerService.instance.appInForeground = true;
      var inbox = <Map<String, dynamic>>[];
      final client = MockClient((req) async {
        if (req.url.path.startsWith('/negotiate/inbox/')) {
          return http.Response(jsonEncode(inbox), 200, headers: {'content-type': 'application/json'});
        }
        return http.Response('{"detail":"none"}', 404);
      });
      Future<void> sweep() =>
          http.runWithClient(() => GlobalPollerService.instance.catchUp(), () => client);

      inbox = [{..._thread(), 'last_role': 'broker', 'last_message': 'He said yes', 'last_message_id': 'z1'}];
      await sweep();
      inbox = [{..._thread(), 'last_role': 'seller', 'last_message': 'ok', 'last_message_id': 's1'}];
      await sweep();

      final payloads = [for (final s in shown) jsonDecode(s['payload'] as String) as Map];
      expect(payloads, hasLength(2));
      expect(payloads[0]['screen'], 'zeno');
      expect(payloads[1].containsKey('screen'), isFalse);
      GlobalPollerService.instance.stop();
    });
  });
}

Widget _room(Widget child, {String role = 'buyer', String? buyerId}) => MaterialApp(
      onGenerateRoute: (_) => MaterialPageRoute(
        settings: RouteSettings(arguments: {
          'listing': Listing.fromJson({
            ...fakeListingJson(1),
            'id': 'listing-1',
            'seller_id': 'seller-1',
            'listing_type': 'fixed',
            'status': 'active',
          }),
          'role': role,
          if (buyerId != null) 'buyer_id': buyerId,
        }),
        builder: (_) => child,
      ),
    );

List<FakeRequest> _zenoReads() => fakeRequests
    .where((r) => r.method == 'POST' && r.uri.path == '/negotiate/listing-1/zeno-read')
    .toList();

/// pumpAndSettle never returns (the constellation animates forever).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
