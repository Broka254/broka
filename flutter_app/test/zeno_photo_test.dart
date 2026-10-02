// Zeno can look at a photo (2026-10-02). Asked whether it could: it could
// not - the Zeno tab took words only, and the server's photo analysis was
// pinned to a Gemini model Google had shut down. The tab now has a photo
// button; the photo waits in the composer, goes with the next message (or
// on its own), and shows in the conversation. The server checks it, strips
// its metadata and shrinks it before any model sees it.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/zeno_screen.dart';
import 'package:broka/services/zeno_chat_store.dart';
import 'package:broka/widgets/chat_parts.dart';

import 'support/fake_api.dart';

// A 1x1 PNG: real image bytes, so Image.memory has something to decode.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  setUpAll(() {
    installFakeApi();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  setUp(() {
    clearFakeRequests();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => setFakeRoute(null));

  Future<void> run(WidgetTester tester, Duration total) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget zeno({ZenoMode mode = ZenoMode.assistant}) => MaterialApp(
        home: ZenoScreen(
          mode: mode,
          animateBackground: false,
          photoPicker: (_) async => _png,
        ),
      );

  List<Map> turns() => [
        for (final r in fakeRequests)
          if (r.uri.path == '/zeno/assistant/turn') r.json as Map,
      ];

  Future<void> send(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250)); // the send button scales in
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
  }

  testWidgets('a photo goes to Zeno with the question, and shows in the conversation',
      (tester) async {
    setFakeRoute((uri) => uri.path == '/zeno/assistant/turn'
        ? {'reply': "That's a Samsung A54 - around KES 32,000 used.", 'action': null}
        : null);
    await tester.pumpWidget(zeno());
    await run(tester, const Duration(milliseconds: 400));

    await tester.tap(find.byTooltip('Show Zeno a photo'));
    await run(tester, const Duration(milliseconds: 100));
    expect(find.byKey(const Key('zeno-staged-photo')), findsOneWidget,
        reason: 'waits in the composer');

    await tester.enterText(find.byKey(const Key('zeno-composer')), 'what is this worth?');
    await send(tester);
    await run(tester, const Duration(seconds: 4));

    final body = turns().single;
    expect(body['message'], 'what is this worth?');
    expect(base64Decode(body['image_base64'] as String), _png);
    expect(find.byKey(const Key('zeno-staged-photo')), findsNothing, reason: 'sent');
    expect(find.byKey(const Key('zeno-sent-photo')), findsOneWidget);
    expect(find.text("That's a Samsung A54 - around KES 32,000 used."), findsOneWidget);

    // Kept on the phone as "a photo was sent", not as the photo.
    final saved = await ZenoChatStore.load('assistant');
    expect(saved!.turns.firstWhere((t) => t.role == 'user').content, '📷 what is this worth?');
  });

  testWidgets('a photo on its own is a question', (tester) async {
    setFakeRoute((uri) => uri.path == '/zeno/assistant/turn'
        ? {'reply': 'A pair of Air Force 1s.', 'action': null}
        : null);
    await tester.pumpWidget(zeno());
    await run(tester, const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Show Zeno a photo'));
    await run(tester, const Duration(milliseconds: 100));
    await send(tester);
    await run(tester, const Duration(seconds: 3));

    final body = turns().single;
    expect(body['message'], isNotEmpty);
    expect(body['image_base64'], isNotEmpty);
  });

  testWidgets('a staged photo can be taken back out', (tester) async {
    await tester.pumpWidget(zeno());
    await run(tester, const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Show Zeno a photo'));
    await run(tester, const Duration(milliseconds: 100));
    await tester.tap(find.bySemanticsLabel('Remove the photo'));
    await run(tester, const Duration(milliseconds: 100));
    expect(find.byKey(const Key('zeno-staged-photo')), findsNothing);
    expect(tester.widget<ChatSendButton>(find.byType(ChatSendButton)).visible, isFalse,
        reason: 'nothing left to send');
  });

  testWidgets('a photo Zeno cannot use says why', (tester) async {
    setFakeRoute((uri) => uri.path == '/zeno/assistant/turn'
        ? const FakeResponse({'detail': "That file isn't an image we can read."}, statusCode: 422)
        : null);
    await tester.pumpWidget(zeno());
    await run(tester, const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Show Zeno a photo'));
    await run(tester, const Duration(milliseconds: 100));
    await send(tester);
    await run(tester, const Duration(seconds: 2));
    expect(find.textContaining("isn't an image we can read"), findsOneWidget);
  });

  testWidgets("the Buying Agent's conversation has no photo button", (tester) async {
    await tester.pumpWidget(zeno(mode: ZenoMode.buyingAgent));
    await run(tester, const Duration(milliseconds: 400));
    expect(find.byTooltip('Show Zeno a photo'), findsNothing);
  });
}
