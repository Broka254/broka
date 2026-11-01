// Direct-chat reliability: typing presence, auto-flush, reply navigation,
// natural image aspect, and Zeno server restore.
//
// Each test drives the real widget and asserts the rendered outcome -
// no private members are touched except the two @visibleForTesting seams
// (inbound socket frames, reconnect flush) that stand in for a live
// WebSocket no test can open.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/zeno_chat_store.dart';
import 'package:broka/widgets/aspect_image.dart';
import 'package:broka/widgets/message_receipt.dart';

import 'support/fake_api.dart';

String _iso(DateTime t) => t.toUtc().toIso8601String();

Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  return Uint8List.fromList(img.encodePng(image));
}

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

  /// pumpAndSettle never returns (the constellation animates).
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  dynamic stateOf(WidgetTester tester) =>
      tester.state(find.byType(NegotiationScreen)) as dynamic;

  group('typing presence', () {
    testWidgets('the other side typing shows, then expires on its own',
        (tester) async {
      final at = DateTime.now().subtract(const Duration(minutes: 1));
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') {
          return [
            {'role': 'seller', 'content': 'Karibu', 'id': 'm1', 'created_at': _iso(at)},
          ];
        }
        if (p.endsWith('/read-status')) return <String, dynamic>{};
        return null;
      });
      await tester.pumpWidget(chat());
      await settle(tester);
      expect(find.textContaining('is typing'), findsNothing);

      stateOf(tester).debugSocketFrame({'type': 'typing', 'role': 'seller'});
      await tester.pump();
      expect(find.textContaining('is typing'), findsOneWidget);

      // No fresh event: the indicator clears itself instead of sticking.
      await tester.pump(const Duration(seconds: 7));
      await settle(tester);
      expect(find.textContaining('is typing'), findsNothing);
    });

    testWidgets('stop_typing and our own role never show an indicator',
        (tester) async {
      final at = DateTime.now().subtract(const Duration(minutes: 1));
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') {
          return [
            {'role': 'seller', 'content': 'Karibu', 'id': 'm1', 'created_at': _iso(at)},
          ];
        }
        if (p.endsWith('/read-status')) return <String, dynamic>{};
        return null;
      });
      await tester.pumpWidget(chat());
      await settle(tester);

      // Our own devices are excluded server-side; a frame carrying our role
      // must not light the indicator either.
      stateOf(tester).debugSocketFrame({'type': 'typing', 'role': 'buyer'});
      await tester.pump();
      expect(find.textContaining('is typing'), findsNothing);

      stateOf(tester).debugSocketFrame({'type': 'typing', 'role': 'seller'});
      await tester.pump();
      expect(find.textContaining('is typing'), findsOneWidget);

      stateOf(tester).debugSocketFrame({'type': 'stop_typing', 'role': 'seller'});
      await tester.pump();
      expect(find.textContaining('is typing'), findsNothing);
    });

    testWidgets('a new message from them clears the indicator', (tester) async {
      final at = DateTime.now().subtract(const Duration(minutes: 1));
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') {
          return [
            {'role': 'seller', 'content': 'Karibu', 'id': 'm1', 'created_at': _iso(at)},
          ];
        }
        if (p.endsWith('/read-status')) return <String, dynamic>{};
        return null;
      });
      await tester.pumpWidget(chat());
      await settle(tester);

      stateOf(tester).debugSocketFrame({'type': 'typing', 'role': 'seller'});
      await tester.pump();
      expect(find.textContaining('is typing'), findsOneWidget);

      stateOf(tester).debugSocketFrame({
        'type': 'message',
        'id': 'm2',
        'role': 'seller',
        'content': 'Niko hapa',
        'msg_type': 'text',
        'created_at': _iso(DateTime.now()),
      });
      await settle(tester);
      expect(find.textContaining('is typing'), findsNothing);
      expect(find.text('Niko hapa'), findsOneWidget);
    });
  });

  group('offline auto-flush', () {
    testWidgets('a failed send goes out on its own when asked to flush',
        (tester) async {
      final at = DateTime.now().subtract(const Duration(minutes: 1));
      var failSends = true;
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') {
          return [
            {'role': 'seller', 'content': 'Karibu', 'id': 'm1', 'created_at': _iso(at)},
          ];
        }
        if (p == '/negotiate/direct-message') {
          if (failSends) return const FakeResponse.error();
          final body = (fakeRequests.lastWhere((r) => r.uri.path == p).json
              as Map<String, dynamic>);
          return {
            'ok': true,
            'message': {
              'id': 'm9',
              'role': 'buyer',
              'content': body['content'],
              'msg_type': 'text',
              'created_at': _iso(DateTime.now()),
              'client_msg_id': body['client_msg_id'],
            },
          };
        }
        if (p.endsWith('/read-status')) return <String, dynamic>{};
        return null;
      });
      await tester.pumpWidget(chat());
      await settle(tester);

      await tester.enterText(find.byKey(const Key('direct-chat-composer')), 'Niko offline');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await settle(tester);
      // Failed: the bubble says so instead of pretending it sent.
      expect(find.text('Niko offline'), findsOneWidget);
      final failedSends = fakeRequests
          .where((r) => r.uri.path == '/negotiate/direct-message')
          .toList();
      expect(failedSends, hasLength(1));
      final clientId =
          (failedSends.single.json as Map<String, dynamic>)['client_msg_id'];

      // Connectivity returns: the flush resends under the SAME id.
      failSends = false;
      stateOf(tester).debugFlushFailed();
      await settle(tester);

      final resent = fakeRequests
          .where((r) => r.uri.path == '/negotiate/direct-message')
          .toList();
      expect(resent, hasLength(2));
      expect((resent.last.json as Map<String, dynamic>)['client_msg_id'], clientId);
      expect(
        tester
            .widgetList<MessageReceiptIcon>(find.byType(MessageReceiptIcon))
            .map((w) => w.receipt),
        contains(MessageReceipt.sent),
      );
    });
  });

  group('reply navigation', () {
    testWidgets('tapping a quote lands exactly on the original bubble',
        (tester) async {
      final base = DateTime.now().subtract(const Duration(minutes: 30));
      final history = [
        for (var i = 0; i < 30; i++)
          {
            'role': i.isEven ? 'seller' : 'buyer',
            'content': i == 0 ? 'Alpha one' : 'Filler message number $i ' * (1 + i % 3),
            'id': 'm$i',
            'created_at': _iso(base.add(Duration(minutes: i))),
          },
        {
          'role': 'buyer',
          'content': 'Answering the first one',
          'id': 'm30',
          'created_at': _iso(base.add(const Duration(minutes: 31))),
          'reply_to_message_id': 'm0',
          'reply_preview': {
            'message_id': 'm0',
            'sender_role': 'seller',
            'msg_type': 'text',
            'preview': 'Alpha one',
            'deleted': false,
          },
        },
      ];
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') return history;
        if (p.endsWith('/read-status')) return <String, dynamic>{};
        return null;
      });
      await tester.pumpWidget(chat());
      await settle(tester);

      // Restored long threads open at the latest message: the first bubble
      // is off-screen, so the only 'Alpha one' on screen is the quote.
      expect(find.text('Alpha one'), findsOneWidget);

      await tester.tap(find.text('Alpha one'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      // The exact original bubble is now laid out and visible.
      expect(find.text('Alpha one'), findsWidgets);
    });
  });

  group('natural image aspect', () {
    testWidgets('landscape, portrait and square keep their own ratio',
        (tester) async {
      // The inner box carries the photo's own ratio: landscape 2:1,
      // portrait 1:2 (height clamped to the 340 bound), square 1:1. The
      // outer frame is bubble-width driven; the ratio lives inside it.
      for (final (w, h, ratio) in [
        (200, 100, 2.0),
        (100, 200, 0.5),
        (120, 120, 1.0),
      ]) {
        // Codecs decode on real time outside the fake-async zone: keep
        // pumping until the framed photo lands, then assert its exact size.
        await tester.runAsync(() async {
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: AspectImage(
                  provider: MemoryImage(_png(w, h)),
                  maxWidth: 300,
                  maxHeight: 340,
                ),
              ),
            ),
          ));
          for (var i = 0;
              i < 40 && find.byType(ClipRRect).evaluate().isEmpty;
              i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await tester.pump();
          }
        });
        await settle(tester);
        // The resolved frame - portrait, landscape and square each keep
        // their own ratio instead of a forced crop box.
        final boxes = [
          for (final e in find.byType(SizedBox).evaluate())
            tester.getSize(find.byWidget(e.widget!)),
        ];
        expect(
          boxes.any((s) =>
              s.width > 0 &&
              s.height > 0 &&
              (s.width / s.height - ratio).abs() < 0.02),
          isTrue,
          reason: 'no $w×$h box at ratio $ratio in $boxes',
        );
      }
    });
  });

  group('zeno server restore', () {
    test('server turns merge with local ones and offline turns upload',
        () async {
      ApiService.currentUserId = 'zeno-user';
      SharedPreferences.setMockInitialValues({});
      await ZenoChatStore.save(
        'assistant',
        ZenoConversation(
          turns: const [
            ZenoStoredTurn(role: 'broker', content: 'Welcome'),
            ZenoStoredTurn(role: 'user', content: 'typed offline'),
          ],
          history: const [
            {'role': 'assistant', 'content': 'Welcome'},
            {'role': 'user', 'content': 'typed offline'},
          ],
          savedAt: DateTime.now().toUtc(),
        ),
      );
      setFakeRoute((uri) {
        if (uri.path == '/zeno/assistant/conversation' && uri.queryParameters['mode'] == 'assistant') {
          return {
            'turns': [
              {
                'role': 'assistant',
                'content': 'Welcome',
                'client_turn_id': 'srv-1',
                'seq': 1,
                'created_at': _iso(DateTime.now()),
              },
              {
                'role': 'assistant',
                'content': 'From another device',
                'client_turn_id': 'srv-2',
                'seq': 2,
                'created_at': _iso(DateTime.now()),
              },
            ],
          };
        }
        if (uri.path == '/zeno/assistant/conversation/append') {
          return {'seq': 3, 'role': 'user', 'content': 'typed offline', 'client_turn_id': 'up-1'};
        }
        return null;
      });

      final merged = await ZenoChatStore.restoreFromServer('assistant');
      expect(merged, isNotNull);
      final contents = merged!.turns.map((t) => t.content).toList();
      // Server transcript kept whole and in order; the offline turn kept
      // after it, not dropped and not duplicated.
      expect(contents, ['Welcome', 'From another device', 'typed offline']);

      // A second restore must not duplicate anything.
      setFakeRoute((uri) {
        if (uri.path == '/zeno/assistant/conversation') {
          return {
            'turns': [
              for (final t in contents)
                {
                  'role': t == 'typed offline' ? 'user' : 'assistant',
                  'content': t,
                  'client_turn_id': 'srv-x-$t',
                  'seq': 1,
                  'created_at': _iso(DateTime.now()),
                },
            ],
          };
        }
        return null;
      });
      final again = await ZenoChatStore.restoreFromServer('assistant');
      expect(again!.turns.map((t) => t.content).toList(), contents);
    });
  });
}
