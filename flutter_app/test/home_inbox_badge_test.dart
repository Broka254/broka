// Home's Inbox tab shows how many messages are unread (2026-10-02). Nothing
// on Home said a message was waiting: the count lived inside the Inbox.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/screens/home_screen.dart';
import 'package:broka/services/global_poller_service.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    HomeScreen.railHintEnabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : null,
    );
  });

  tearDown(() => GlobalPollerService.instance.unreadTotal.value = 0);

  Future<void> run(WidgetTester tester, Duration total) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  final badge = find.byKey(const Key('inbox-unread-badge'));

  testWidgets('the Inbox tab counts unread messages, and updates', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(data: MediaQueryData(size: Size(800, 1200)), child: HomeScreen()),
    ));
    await run(tester, const Duration(milliseconds: 300));
    expect(badge, findsNothing, reason: 'nothing unread, no badge');

    GlobalPollerService.instance.unreadTotal.value = 4;
    await tester.pump();
    expect(badge, findsOneWidget);
    expect(find.descendant(of: badge, matching: find.text('4')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Inbox, 4 unread')), findsOneWidget,
        reason: 'a screen reader says it too');

    GlobalPollerService.instance.unreadTotal.value = 140;
    await tester.pump();
    expect(find.descendant(of: badge, matching: find.text('99+')), findsOneWidget);

    GlobalPollerService.instance.unreadTotal.value = 0;
    await tester.pump();
    expect(badge, findsNothing, reason: 'read, so it goes');
    await run(tester, const Duration(milliseconds: 300));
    semantics.dispose();
  });
}
