// How Zeno asks about SMS alerts on the sell wizard's last step
// (ZenoSmsPrompts, ZenoStreamingBubble): ten phrasings, never the same one
// twice in a row, each naming the seller and the listing - and streamed in
// like a model's reply, or shown whole under reduced motion.
import 'dart:math';

import 'package:broka/services/zeno_sms_prompts.dart';
import 'package:broka/widgets/zeno_streaming_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ZenoSmsPrompts', () {
    test('ten different questions, each one a question', () {
      expect(ZenoSmsPrompts.questions.toSet(), hasLength(10));
      for (var i = 0; i < 10; i++) {
        final q = ZenoSmsPrompts.compose(i, 0, sellerName: 'Wanjiku Kamau', itemName: 'Dry maize');
        expect(q, endsWith('?'), reason: q);
        expect(q, startsWith('Hi Wanjiku!'), reason: q);
        expect(q, contains('"Dry maize"'), reason: q);
        expect(q, isNot(contains('{')), reason: q);
      }
    });

    test('without a name or a title it still reads as a sentence', () {
      expect(ZenoSmsPrompts.compose(1, 2),
          startsWith('Habari! Your listing is almost live.'));
      expect(ZenoSmsPrompts.compose(0, 1, sellerName: '  ', itemName: ''),
          contains('for your listing.'));
    });

    test('never asks the same question twice in a row', () async {
      // A random source that always picks question 3 first.
      final rnd = _Fixed([3, 0, 3, 0, 3, 0]);
      final first = await ZenoSmsPrompts.next(itemName: 'Maize', random: rnd);
      final second = await ZenoSmsPrompts.next(itemName: 'Maize', random: rnd);
      expect(first, ZenoSmsPrompts.compose(3, 0, itemName: 'Maize'));
      expect(second, isNot(first));
      // And it's remembered on the phone, across app restarts.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('zeno_sms_prompt_last'), isNot(3));
    });

    test('over many listings, every phrasing turns up', () async {
      final seen = <String>{};
      final rnd = Random(7);
      for (var i = 0; i < 200; i++) {
        seen.add(await ZenoSmsPrompts.next(itemName: 'Maize', random: rnd));
      }
      final opening = seen.map((q) => q.split('!').skip(1).join('!')).toSet();
      expect(opening.length, 10);
    });
  });

  group('ZenoStreamingBubble', () {
    const text = 'Hey Otieno! Quick one before we go live: should I SMS you?';

    testWidgets('streams the words in after a moment of thinking', (tester) async {
      var done = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ZenoStreamingBubble(
            text: text, random: Random(1), onDone: () => done = true)),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Zeno is thinking…'), findsOneWidget);
      expect(find.text('thinking'), findsOneWidget);

      // Frame by frame until the first words land (the thinking beat is
      // under a second and a half).
      for (var i = 0; i < 40 && find.text('writing').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Zeno is thinking…'), findsNothing);
      expect(find.text('writing'), findsOneWidget);
      // Part way: some words, not all of them, and a caret.
      final partial = _shown(tester);
      expect(partial, endsWith('▍'));
      expect(partial.length, lessThan(text.length));
      expect(done, isFalse);

      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(done, isTrue);
      expect(_shown(tester), text);
      expect(find.text('just now'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Removed mid-flight elsewhere, nothing is left running.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('keeps thinking until there is something to say', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: ZenoStreamingBubble(text: null))));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('Zeno is thinking…'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: ZenoStreamingBubble(text: text))));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(_shown(tester), text);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('under reduced motion the whole question shows at once', (tester) async {
      var done = false;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(body: ZenoStreamingBubble(text: text, onDone: () => done = true)),
      ));
      await tester.pump();
      expect(_shown(tester), text);
      expect(done, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('screen readers hear the whole question, never half of it', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ZenoStreamingBubble(text: text, random: Random(2)))));
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.bySemanticsLabel(text), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      handle.dispose();
    });
  });
}

/// The bubble's streamed text as it stands, caret included.
String _shown(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((w) => w.text.toPlainText())
    .firstWhere((t) => t.contains('Otieno') || t.contains('Hey'), orElse: () => '');

/// Returns [values] in turn from nextInt (bounded by max).
class _Fixed implements Random {
  _Fixed(this.values);
  final List<int> values;
  var _i = 0;

  @override
  int nextInt(int max) => values[_i++ % values.length] % max;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}
