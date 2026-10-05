// Zeno's conversation after the 2026-09-26 pass: it survives closing the
// screen (and the app), it can be started over, it sends Zeno only the
// recent context - once - and the screen is on Home's visual system.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/zeno_screen.dart';
import 'package:broka/services/zeno_chat_store.dart';
import 'package:broka/widgets/chat_ambient_background.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:broka/widgets/zeno_avatar.dart';
import 'package:broka/widgets/zeno_streaming_text.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(() {
    installFakeApi();
    // BrokaTts owns an AudioPlayer; nothing plays in these tests.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  var replies = 0;
  setUp(() {
    replies = 0;
    clearFakeRequests();
    SharedPreferences.setMockInitialValues({});
    setFakeRoute((uri) {
      if (uri.path == '/zeno/assistant/turn') {
        replies++;
        return {'reply': 'Zeno reply $replies', 'action': null};
      }
      if (uri.path.startsWith('/buy-agent-requests/converse')) {
        return {'reply': 'Which storage size?', 'phase': 'ASKING', 'slots': {'query': 'iphone'}, 'questions_asked': 1};
      }
      return null;
    });
  });

  Future<void> say(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('zeno-composer')), text);
    // The send button scales in once there's a draft: one frame to start
    // the animation, then long enough for it to finish.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await _settle(tester);
    // Zeno's reply writes itself out; wait for the last word.
    await _stream(tester);
  }

  testWidgets('the conversation is still there after Zeno is closed', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    await say(tester, 'Is 800K fair for an Axio?');
    expect(find.text('Zeno reply 1'), findsOneWidget);

    // Close Zeno entirely, then open it again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    expect(find.text('Is 800K fair for an Axio?'), findsOneWidget);
    expect(find.text('Zeno reply 1'), findsOneWidget);
    // Openers are for a new conversation, not one being continued.
    expect(find.text('Tips to close a deal faster'), findsNothing);
  });

  testWidgets('the next message carries the earlier conversation as context',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    await say(tester, 'First question');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    clearFakeRequests();
    await say(tester, 'Second question');

    final sent = fakeRequests.lastWhere((r) => r.uri.path == '/zeno/assistant/turn').json as Map;
    expect(sent['message'], 'Second question');
    final history = (sent['history'] as List).cast<Map>();
    expect(history.map((h) => h['content']), ['First question', 'Zeno reply 1'],
        reason: 'the restored conversation is the context');
    // The server appends `message` itself; sending it in history too put
    // every message into Zeno's context twice.
    expect(history.where((h) => h['content'] == 'Second question'), isEmpty);
  });

  testWidgets('a long conversation sends only the recent context', (tester) async {
    // 60 exchanges - more than the server reads (the last 40).
    SharedPreferences.setMockInitialValues({});
    await ZenoChatStore.save('assistant', ZenoConversation(
      turns: [
        for (var i = 0; i < 120; i++)
          ZenoStoredTurn(role: i.isEven ? 'user' : 'broker', content: 'turn $i'),
      ],
      history: [
        for (var i = 0; i < 120; i++)
          {'role': i.isEven ? 'user' : 'assistant', 'content': 'turn $i'},
      ],
      savedAt: DateTime.now(),
    ));
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    clearFakeRequests();
    await say(tester, 'And now?');

    final sent = fakeRequests.lastWhere((r) => r.uri.path == '/zeno/assistant/turn').json as Map;
    final history = sent['history'] as List;
    expect(history.length, 20);
    expect((history.last as Map)['content'], 'turn 119');
  });

  testWidgets('New chat starts over and forgets the old one', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    await say(tester, 'Something to forget');

    await tester.tap(find.byTooltip('New chat'));
    await _settle(tester);
    await tester.tap(find.text('New chat').last);
    await _settle(tester);
    expect(find.text('Something to forget'), findsNothing);
    expect(await ZenoChatStore.load('assistant'), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    expect(find.text('Something to forget'), findsNothing);
  });

  testWidgets('the Buying Agent keeps its own conversation and what it gathered',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen(mode: ZenoMode.buyingAgent)));
    await _settle(tester);
    await say(tester, "I'm looking for an iPhone");
    expect(find.text('Which storage size?'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen(mode: ZenoMode.buyingAgent)));
    await _settle(tester);
    clearFakeRequests();
    await say(tester, '256GB');
    final sent = fakeRequests
        .lastWhere((r) => r.uri.path.startsWith('/buy-agent-requests/converse'))
        .json as Map;
    expect(sent['slots'], {'query': 'iphone'});
    expect(sent['questions_asked'], 1);

    // The market assistant is a different conversation.
    final assistant = await ZenoChatStore.load('assistant');
    expect(assistant, isNull);
    // Outlast the screen's "searching…" caption timer.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a query from Home starts a fresh Buying Agent conversation',
      (tester) async {
    await ZenoChatStore.save('buying', ZenoConversation(
      turns: const [ZenoStoredTurn(role: 'user', content: 'an old laptop search')],
      history: const [{'role': 'user', 'content': 'an old laptop search'}],
      slots: const {'category': 'Electronics', 'query': 'laptop'},
      savedAt: DateTime.now(),
    ));
    await tester.pumpWidget(const MaterialApp(
        home: ZenoScreen(mode: ZenoMode.buyingAgent, initialQuery: 'a used tractor')));
    await _settle(tester);
    expect(find.text('an old laptop search'), findsNothing);
    final sent = fakeRequests
        .lastWhere((r) => r.uri.path.startsWith('/buy-agent-requests/converse'))
        .json as Map;
    expect(sent['message'], 'a used tractor');
    expect(sent.containsKey('slots'), isFalse);
    await tester.pump(const Duration(seconds: 3));
  });

  test('a month-old conversation is not picked up again', () async {
    SharedPreferences.setMockInitialValues({});
    await ZenoChatStore.save('assistant', ZenoConversation(
      turns: const [ZenoStoredTurn(role: 'user', content: 'hello')],
      history: const [],
      savedAt: DateTime.utc(2026, 8, 1),
    ));
    expect(await ZenoChatStore.load('assistant', now: DateTime.utc(2026, 8, 20)), isNotNull);
    expect(await ZenoChatStore.load('assistant', now: DateTime.utc(2026, 9, 5)), isNull);
  });

  test('stored listings drop inline images', () {
    final turn = ZenoStoredTurn(role: 'broker', content: 'found one', matches: [
      {'id': 'l1', 'name': 'iPhone', 'verified_photos': 'A' * 50000, 'price': 1000},
    ]);
    final stored = turn.toJson()['matches'] as List;
    expect(stored.single, {'id': 'l1', 'name': 'iPhone', 'price': 1000});
  });

  group('replies are written out like a language model writes', () {
    const long = 'A fair price for a 2014 Axio in Nairobi is between 780K and '
        '850K, depending on mileage and whether it has been locally used.';

    setUp(() => setFakeRoute((uri) => uri.path == '/zeno/assistant/turn'
        ? {'reply': long, 'action': null}
        : null));

    /// What the newest reply shows right now, caret and all.
    String shown(WidgetTester tester) => tester
        .widget<Text>(find.descendant(
            of: find.byType(ZenoStreamingText).last, matching: find.byType(Text)))
        .textSpan!
        .toPlainText();

    testWidgets('a new reply arrives a few words at a time', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('zeno-composer')), 'Is 800K fair?');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final early = shown(tester);
      expect(early, isNot(long), reason: 'not the whole reply at once');
      expect(early, endsWith('▍'), reason: 'a caret where the next word goes');
      expect(long, startsWith(early.replaceAll('▍', '')));

      await tester.pump(const Duration(milliseconds: 400));
      final later = shown(tester).replaceAll('▍', '');
      expect(later.length, greaterThan(early.replaceAll('▍', '').length),
          reason: 'more words keep arriving');

      await _stream(tester);
      await _stream(tester);
      expect(find.text(long), findsOneWidget);
    });

    testWidgets('one word at a time, at a pace that can be read', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('zeno-composer')), 'Is 800K fair?');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));

      final total = long.split(' ').length;
      final counts = <int>[];
      for (var frame = 0; frame < 500; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        // The greeting is the first; the reply, once it lands, the second.
        final replies = find.byType(ZenoStreamingText);
        if (replies.evaluate().length < 2) continue;
        final text = tester.widget<Text>(
            find.descendant(of: replies.last, matching: find.byType(Text)));
        final shown = (text.data ?? text.textSpan!.toPlainText()).replaceAll('▍', '');
        counts.add(shown.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length);
        if (counts.last == total && text.data != null) break;
      }

      expect(counts.last, total);
      for (var i = 1; i < counts.length; i++) {
        expect(counts[i] - counts[i - 1], lessThanOrEqualTo(1),
            reason: 'words arrive one at a time, never in lumps (frame $i)');
      }
      final firstWord = counts.indexWhere((c) => c > 0);
      final lastWord = counts.indexOf(total);
      final writingMs = (lastWord - firstWord) * 16;
      // 23 words: about 1.8s at a steady reading pace. The first version
      // wrote this in well under a second.
      expect(writingMs, inInclusiveRange(1300, 3500));
    });

    testWidgets('a conversation picked up again is not written out again',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
      await _settle(tester);
      await say(tester, 'Is 800K fair?');
      await _stream(tester);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
      await _settle(tester);
      expect(find.text(long), findsOneWidget);
    });

    testWidgets('under reduced motion the reply is there at once', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(disableAnimations: true), child: ZenoScreen())));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('zeno-composer')), 'Is 800K fair?');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await _settle(tester);
      expect(find.text(long), findsOneWidget);
    });

    testWidgets("the Buying Agent's listings wait for its sentence", (tester) async {
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? {
              'reply': 'I found two iPhones near you that fit what you described.',
              'phase': 'RESULTS',
              'verdict': 'MATCHES',
              'matches': [fakeListingJson(1)..['name'] = 'iPhone 13 Pro'],
              'slots': {'query': 'iphone'},
              'questions_asked': 2,
            }
          : null);
      await tester.pumpWidget(const MaterialApp(home: ZenoScreen(mode: ZenoMode.buyingAgent)));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('zeno-composer')), 'iPhone 13, under 60K');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('iPhone 13 Pro'), findsNothing);

      await _stream(tester);
      await _stream(tester);
      expect(find.text('iPhone 13 Pro'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  testWidgets('a watch already running can be replaced from Zeno', (tester) async {
    // Zeno used to answer ACTIVE_REQUEST_EXISTS with "cancel that one from
    // the home screen" - and nothing in the app could cancel a watch.
    var actions = 0;
    setFakeRoute((uri) {
      if (uri.path.startsWith('/buy-agent-requests/converse')) {
        return {
          'reply': "Nothing yet - want me to keep watching?",
          'phase': 'RESULTS',
          'verdict': 'EMPTY',
          'matches': const [],
          'slots': {'query': 'sofa', 'category': 'Home & Furniture', 'max_price': 40000},
          'questions_asked': 0,
        };
      }
      if (uri.path.startsWith('/buy-agent-requests/action')) {
        actions++;
        return switch (actions) {
          1 => {'action': 'CREATE_BUYING_REQUEST', 'status': 'FAILED',
                'error_code': 'ACTIVE_REQUEST_EXISTS', 'message': 'You already have one.'},
          2 => {'action': 'CANCEL_REQUEST', 'status': 'SUCCESS', 'request': {'status': 'cancelled'}},
          _ => {'action': 'CREATE_BUYING_REQUEST', 'status': 'SUCCESS', 'request': {'status': 'active'}},
        };
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen(mode: ZenoMode.buyingAgent)));
    await _settle(tester);
    await say(tester, 'a sofa under 40k');
    await _stream(tester);

    await tester.tap(find.text('Keep watching for me'));
    await _settle(tester);
    expect(find.text('Replace your current watch?'), findsOneWidget);
    await tester.tap(find.text('Replace it'));
    await _settle(tester);

    final sent = fakeRequests
        .where((r) => r.uri.path.startsWith('/buy-agent-requests/action'))
        .map((r) => (r.json as Map)['action'])
        .toList();
    expect(sent, ['CREATE_BUYING_REQUEST', 'CANCEL_REQUEST', 'CREATE_BUYING_REQUEST']);
    expect(find.text("I'll keep watching and tell you when something turns up."), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets("on Home's visual system", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(find.byType(ChatAmbientBackground), findsNothing);
    expect(find.text('ZENO'), findsOneWidget);
    expect(find.byType(ZenoAvatar), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  // The opener asked "How does BROKA escrow work?" - there is no BROKA
  // escrow while payments are paused, and asking invites a description of
  // one.
  testWidgets('the openers ask how to pay safely, not about BROKA escrow', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    // The rail builds its chips as they scroll in: take it to the end.
    final rail = Offset(400, tester.getCenter(find.text('🚗')).dy);
    for (var i = 0; i < 8; i++) {
      await tester.dragFrom(rail, const Offset(-300, 0));
      await _settle(tester);
    }
    expect(find.text('How do I pay a seller safely?'), findsOneWidget);
    expect(find.textContaining('escrow'), findsNothing);
  });
}

/// pumpAndSettle never returns here (the constellation animates forever).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// Long enough for a short reply to finish writing itself out.
Future<void> _stream(WidgetTester tester) async {
  for (int i = 0; i < 25; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
