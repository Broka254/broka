// Minimising a call (services/call_dock.dart, widgets/call_dock_host.dart).
//
// The call screen owned the call, so leaving it - Back included - hung up,
// and there was no way to look at the listing or the chat while talking.
// WhatsApp's call screen has a minimise button at its top left that keeps
// the call going in a small bar over the rest of the app; BROKA's does now,
// and Back does the same.
import 'dart:async';

import 'package:broka/screens/voip_call_screen.dart';
import 'package:broka/services/active_call.dart';
import 'package:broka/services/call_dock.dart';
import 'package:broka/widgets/call_dock_host.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() {
    installFakeApi();
    for (final name in [
      'com.broka.app/call_service',
      'FlutterWebRTC.Event',
      'FlutterWebRTC.Method',
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'com.broka.app/ringtone',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clearFakeRequests();
    CallDock.instance.reset();
    ActiveCall.instance.reset();
  });

  Future<void> frames(WidgetTester tester, [int n = 14]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  /// The app as main.dart builds it - the call's host above the navigator -
  /// with a chat on screen, and a call placed from it. The call is still
  /// being set up ([setup] not answered): "Calling…", with End.
  Future<GlobalKey<NavigatorState>> callFromChat(
      WidgetTester tester, Future<Map<String, dynamic>?> setup, {bool host = true}) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      builder: host ? (context, child) => CallDockHost(child: child!) : null,
      home: const Scaffold(body: Center(child: Text('THE CHAT'))),
      onGenerateRoute: (s) => s.name == '/voip-call'
          ? MaterialPageRoute<void>(
              settings: s, builder: (_) => const VoipCallScreen(animateBackground: false))
          : null,
    ));
    nav.currentState!.pushNamed('/voip-call', arguments: {
      'roomId': '',
      'userId': 'buyer-1',
      'callToken': '',
      'callSetup': setup,
      'clientCallId': 'cc-1',
      'peerName': 'Amina Wanjiru',
      'isCaller': true,
      'callerRole': 'buyer',
      'listingName': 'Airtel 5G router',
      'listingId': 'l1',
      'buyerId': 'buyer-1',
    });
    await frames(tester);
    return nav;
  }

  testWidgets('minimise keeps the call going over the app, and the pill brings it back',
      (tester) async {
    final setup = Completer<Map<String, dynamic>?>();
    await callFromChat(tester, setup.future);
    expect(find.text('Calling…'), findsOneWidget);

    await tester.tap(find.byKey(const Key('call-minimize')));
    await frames(tester);
    // Back on the chat, with the call in the pill.
    expect(find.text('THE CHAT'), findsOneWidget);
    expect(find.byKey(const Key('call-pill')), findsOneWidget);
    expect(find.byKey(const Key('call-peer-name')), findsNothing);
    expect(find.text('Amina Wanjiru'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('call-pill-state'))).data, 'Calling…');
    expect(CallDock.instance.hasCall, isTrue);

    await tester.tap(find.byKey(const Key('call-pill')));
    await frames(tester);
    // The same call, in full: the name, its state, one constellation.
    expect(find.byKey(const Key('call-pill')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('call-peer-name'))).data, 'Amina Wanjiru');
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(CallDock.instance.hasCall, isFalse);

    // Back minimises it too; it used to hang up.
    await tester.binding.handlePopRoute();
    await frames(tester);
    expect(find.byKey(const Key('call-pill')), findsOneWidget);
    expect(find.text('THE CHAT'), findsOneWidget);

    // Still the same call: what its setup answers reaches the pill.
    setup.complete(null);
    await frames(tester);
    expect(tester.widget<Text>(find.byKey(const Key('call-pill-state'))).data,
        startsWith('Could not start the call'));
    await tester.tap(find.byKey(const Key('call-pill-close')));
    await frames(tester);
    expect(find.byKey(const Key('call-pill')), findsNothing);
    expect(CallDock.instance.hasCall, isFalse);
    await finish(tester);
  });

  testWidgets('End on the pill ends the call', (tester) async {
    await callFromChat(tester, Completer<Map<String, dynamic>?>().future);
    await tester.tap(find.byKey(const Key('call-minimize')));
    await frames(tester);
    await tester.tap(find.byKey(const Key('call-pill-end')));
    await frames(tester);
    expect(find.byKey(const Key('call-pill')), findsNothing);
    expect(find.byType(VoipCallScreen), findsNothing);
    expect(find.text('THE CHAT'), findsOneWidget);
    expect(CallDock.instance.hasCall, isFalse);
    await finish(tester);
  });

  testWidgets('with the call minimised, a call button brings it back instead of a second call',
      (tester) async {
    final nav = await callFromChat(tester, Completer<Map<String, dynamic>?>().future);
    await tester.tap(find.byKey(const Key('call-minimize')));
    await frames(tester);
    // What the chat's call buttons do first (NegotiationScreen._initiateCall).
    expect(CallDock.instance.expand(), isTrue);
    await frames(tester);
    expect(find.byType(VoipCallScreen), findsOneWidget);
    expect(find.byKey(const Key('call-pill')), findsNothing);
    expect(nav.currentState!.canPop(), isTrue);
    // Nothing to bring back now.
    expect(CallDock.instance.expand(), isFalse);
    await finish(tester);
  });

  testWidgets('without a place to put the call, there is no minimise', (tester) async {
    await callFromChat(tester, Completer<Map<String, dynamic>?>().future, host: false);
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.byKey(const Key('call-minimize')), findsNothing);
    await finish(tester);
  });

  tearDown(() async {
    CallDock.instance.reset();
    ActiveCall.instance.reset();
  });
}
