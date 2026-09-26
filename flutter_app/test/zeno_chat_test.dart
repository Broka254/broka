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
      if (uri.path == '/negotiate/chat') {
        replies++;
        return {'role': 'broker', 'content': 'Zeno reply $replies'};
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

    final sent = fakeRequests.lastWhere((r) => r.uri.path == '/negotiate/chat').json as Map;
    expect(sent['content'], 'Second question');
    final history = (sent['history'] as List).cast<Map>();
    expect(history.map((h) => h['content']), ['First question', 'Zeno reply 1'],
        reason: 'the restored conversation is the context');
    // The server appends `content` itself; sending it in history too put
    // every message into Zeno's context twice.
    expect(history.where((h) => h['content'] == 'Second question'), isEmpty);
  });

  testWidgets('a long conversation sends only the recent context', (tester) async {
    // 60 exchanges - past /negotiate/chat's 100-entry limit on history.
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

    final sent = fakeRequests.lastWhere((r) => r.uri.path == '/negotiate/chat').json as Map;
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

  testWidgets("on Home's visual system", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ZenoScreen()));
    await _settle(tester);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(find.byType(ChatAmbientBackground), findsNothing);
    expect(find.text('ZENO'), findsOneWidget);
    expect(find.byType(ZenoAvatar), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

/// pumpAndSettle never returns here (the constellation animates forever).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
