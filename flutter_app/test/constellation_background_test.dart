// The constellation behind the screens (widgets/constellation_background.dart)
// must not move when the keyboard opens.
//
// It used to be drawn to fit whatever box it was given, with each star at a
// fraction of that box's height. A Scaffold makes its body shorter by the
// keyboard's height, so the moment a chat's message field took focus every
// star slid up and the whole sky squashed into the space left above the
// keyboard - on the chat, Zeno, search, and every other screen on it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/widgets/constellation_background.dart';
import 'package:broka/widgets/splash_painters.dart';

void main() {
  Finder sky() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is NeuralNetworkPainter);

  Future<void> pumpScreen(WidgetTester tester, {bool resize = true}) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2340); // 360 x 780
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        resizeToAvoidBottomInset: resize,
        appBar: AppBar(title: const Text('Chat')),
        body: const ConstellationBackground(
          animate: false,
          child: Align(alignment: Alignment.bottomCenter, child: TextField()),
        ),
      ),
    ));
  }

  void openKeyboard(WidgetTester tester, double logicalHeight) {
    tester.view.viewInsets = FakeViewPadding(bottom: logicalHeight * 3);
  }

  testWidgets('the sky keeps its size and place when the keyboard opens', (tester) async {
    await pumpScreen(tester);
    final restSize = tester.getSize(sky());
    final restTop = tester.getTopLeft(sky());
    final restBox = tester.getSize(find.byType(ConstellationBackground));
    expect(restSize, restBox);

    openKeyboard(tester, 300);
    await tester.pump();

    // The screen did make room for the keyboard...
    expect(tester.getSize(find.byType(ConstellationBackground)).height, restBox.height - 300);
    // ...but the stars are drawn on the same canvas as before, in the same
    // place; the keyboard only covers the bottom of it.
    expect(tester.getSize(sky()), restSize);
    expect(tester.getTopLeft(sky()), restTop);
    expect(tester.takeException(), isNull);
  });

  testWidgets('it stays put through every frame of the keyboard sliding up and back', (tester) async {
    await pumpScreen(tester);
    final restSize = tester.getSize(sky());
    for (final h in [40.0, 120.0, 260.0, 300.0, 180.0, 60.0, 0.0]) {
      openKeyboard(tester, h);
      await tester.pump();
      expect(tester.getSize(sky()), restSize, reason: 'keyboard at ${h}dp');
    }
  });

  testWidgets('a screen opened with the keyboard already up still gets the full sky', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2340);
    addTearDown(tester.view.reset);
    openKeyboard(tester, 300);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ConstellationBackground(animate: false, child: SizedBox.expand()),
      ),
    ));
    final withKeyboard = tester.getSize(sky());

    tester.view.resetViewInsets();
    await tester.pump();
    expect(tester.getSize(sky()), withKeyboard);
    expect(tester.getSize(sky()), tester.getSize(find.byType(ConstellationBackground)));
  });

  testWidgets('a screen that does not resize is drawn exactly as before', (tester) async {
    await pumpScreen(tester, resize: false);
    final box = tester.getSize(find.byType(ConstellationBackground));
    openKeyboard(tester, 300);
    await tester.pump();
    expect(tester.getSize(sky()), box);
  });

  testWidgets('turning the phone fits the sky to the new shape', (tester) async {
    await pumpScreen(tester);
    tester.view.physicalSize = const Size(2340, 1080);
    await tester.pump();
    expect(tester.getSize(sky()), tester.getSize(find.byType(ConstellationBackground)));
  });
}
