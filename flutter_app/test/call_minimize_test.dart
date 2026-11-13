// Minimising a call (asked for 2026-11-13, beside WhatsApp's call screen):
// the call screen was the only place a call could be - leaving it hung up.
// Its top-left button, and Back, now take the user back to the screen they
// called from with the call carrying on underneath; a bar across the top of
// the app says so, brings the call back with a tap, and can end it.
import 'dart:async';

import 'package:broka/features/calls/presentation/ongoing_call.dart';
import 'package:broka/screens/voip_call_screen.dart';
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
      'xyz.luan/audioplayers/events/broka_ringtone',
      'com.broka.app/ringtone',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clearFakeRequests();
    setFakeRoute(null);
    OngoingCall.instance.debugReset();
  });

  // The app's shape: the bar above the Navigator, the observer on it.
  Future<GlobalKey<NavigatorState>> openCallFromChat(
      WidgetTester tester, Completer<Map<String, dynamic>?> setup) async {
    final nav = GlobalKey<NavigatorState>();
    final chatArgs = {'buyer_id': 'buyer-1'};
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      navigatorObservers: [OngoingCall.instance.observer],
      builder: (_, child) => OngoingCallHost(child: child!),
      initialRoute: '/direct-chat',
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => Scaffold(body: Center(child: Text('THE CHAT ${settings.name}'))),
      ),
    ));
    nav.currentState!.pushReplacementNamed('/direct-chat', arguments: chatArgs);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    nav.currentState!.push(MaterialPageRoute<void>(
      settings: RouteSettings(name: '/voip-call', arguments: {
        'roomId': '',
        'userId': 'buyer-1',
        'callToken': '',
        'callSetup': setup.future,
        'clientCallId': 'cc-min-0001',
        'peerName': 'Arnold',
        'isCaller': true,
        'listingId': 'listing-1',
        'buyerId': 'buyer-1',
        'callerRole': 'seller',
        'callType': 'audio',
      }),
      builder: (_) => const VoipCallScreen(animateBackground: false),
    ));
    await _settle(tester);
    return nav;
  }

  testWidgets('minimise goes back to the chat, the call on, and the bar returns to it',
      (tester) async {
    final setup = Completer<Map<String, dynamic>?>();
    await openCallFromChat(tester, setup);
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.byKey(const Key('ongoing-call-bar')), findsNothing);

    await tester.tap(find.byKey(const Key('call-minimize')));
    await _settle(tester);

    expect(find.text('THE CHAT /direct-chat'), findsOneWidget, reason: 'back on the chat');
    expect(find.byKey(const Key('ongoing-call-bar')), findsOneWidget);
    expect(find.text('Arnold · Calling…'), findsOneWidget);
    expect(find.byType(VoipCallScreen, skipOffstage: false), findsOneWidget,
        reason: 'the call screen - and so the call - is still there');
    expect(fakeRequests.where((r) => r.uri.path == '/calls/cancel-setup'), isEmpty,
        reason: 'minimising is not hanging up');

    await tester.tap(find.byKey(const Key('ongoing-call-bar')));
    await _settle(tester);
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.byKey(const Key('ongoing-call-bar')), findsNothing);

    // Back minimises too, as on WhatsApp.
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byKey(const Key('ongoing-call-bar')), findsOneWidget);
    expect(find.byType(VoipCallScreen, skipOffstage: false), findsOneWidget);
  });

  testWidgets("the bar's End ends the call and leaves the user where they are",
      (tester) async {
    final setup = Completer<Map<String, dynamic>?>();
    await openCallFromChat(tester, setup);
    await tester.tap(find.byKey(const Key('call-minimize')));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('ongoing-call-end')));
    await _settle(tester);

    final cancel = fakeRequests.where((r) => r.uri.path == '/calls/cancel-setup').toList();
    expect(cancel, hasLength(1));
    expect((cancel.single.json as Map)['client_call_id'], 'cc-min-0001');
    expect(find.byType(VoipCallScreen, skipOffstage: false), findsNothing);
    expect(find.byKey(const Key('ongoing-call-bar')), findsNothing);
    expect(find.text('THE CHAT /direct-chat'), findsOneWidget);
  });

  testWidgets('ended after coming back from the bar, the call leaves the user on the chat',
      (tester) async {
    final setup = Completer<Map<String, dynamic>?>();
    await openCallFromChat(tester, setup);
    await tester.tap(find.byKey(const Key('call-minimize')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('ongoing-call-bar')));
    await _settle(tester);

    await tester.tap(find.text('End'));
    await _settle(tester);

    expect(find.byType(VoipCallScreen, skipOffstage: false), findsNothing);
    expect(find.text('THE CHAT /direct-chat'), findsOneWidget,
        reason: 'the chat the minimise moved above the call is opened again');
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
