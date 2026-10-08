// The call screen, upgraded (2026-10-02). Reported from a phone: a seller
// calling a buyer saw "Buyer" where the buyer's name should be, on a flat
// black screen whose hints and button labels were drawn in the app's
// dimmest text colour. It now shows who is on the other end, on the
// constellation every other screen sits on, with readable labels.
import 'dart:io';

import 'package:broka/main.dart' show BrokaColors;
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/screens/voip_call_screen.dart';
import 'package:broka/models/listing.dart';
import 'package:broka/services/active_call.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    installFakeApi();
    // Real glyph widths for the overflow check: the test font draws every
    // character a full em wide and reports overflows no phone would show.
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts';
    if (Directory(fonts).existsSync()) {
      final roboto = FontLoader('Roboto');
      for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
        roboto.addFont(Future.value(ByteData.view(File('$fonts/$f').readAsBytesSync().buffer)));
      }
      await roboto.load();
    }
    for (final name in [
      'com.broka.app/call_service',
      'FlutterWebRTC.Event',
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers/events/broka_ringtone',
      'com.broka.app/ringtone',
      'com.llfbandit.record/messages',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    // Microphone refused: an outgoing call fails at once, which is all
    // these need - the screen's people and labels show in every state.
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final p in (call.arguments as List).cast<int>()) p: 0};
      }
      return 0;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), (_) async => null);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clearFakeRequests();
    setFakeRoute((uri) => uri.path == '/auth/user/buyer-7'
        ? {'id': 'buyer-7', 'name': 'Amina Wanjiru', 'is_online': true}
        : null);
  });

  Future<void> open(WidgetTester tester, Map<String, Object?> args) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const SizedBox()));
    nav.currentState!.push(MaterialPageRoute<void>(
      settings: RouteSettings(name: '/voip-call', arguments: {
        'roomId': 'room-1',
        'userId': 'seller-1',
        'callToken': 't',
        ...args,
      }),
      builder: (_) => const VoipCallScreen(animateBackground: false),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  String nameShown(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('call-peer-name'))).data!;

  testWidgets("shows the person's name, their side of the deal and the listing", (tester) async {
    await open(tester, {
      'peerName': 'Amina Wanjiru',
      'isCaller': true,
      'callerRole': 'seller',
      'listingName': 'Airtel 5G router',
    });
    expect(nameShown(tester), 'Amina Wanjiru');
    expect(find.text('BUYER'), findsOneWidget);
    expect(find.text('Airtel 5G router'), findsOneWidget);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    await close(tester);
  });

  testWidgets('a placeholder name is replaced with theirs', (tester) async {
    await open(tester, {
      'peerName': 'Buyer',
      'peerId': 'buyer-7',
      'isCaller': true,
      'callerRole': 'seller',
      'listingName': 'Airtel 5G router',
    });
    expect(nameShown(tester), 'Amina Wanjiru');
    expect(fakeRequests.where((r) => r.uri.path == '/auth/user/buyer-7'), hasLength(1));
    await close(tester);
  });

  testWidgets('a real name is not looked up again', (tester) async {
    await open(tester, {
      'peerName': 'Grace Akinyi',
      'peerPhoto': 'aGk=',
      'peerId': 'buyer-7',
      'isCaller': true,
      'callerRole': 'seller',
    });
    expect(nameShown(tester), 'Grace Akinyi');
    expect(fakeRequests.where((r) => r.uri.path.startsWith('/auth/user/')), isEmpty);
    await close(tester);
  });

  testWidgets('an incoming call: who, what about, and Accept / Decline', (tester) async {
    await open(tester, {
      'peerName': 'Xavier Bravin',
      'isCaller': false,
      'callerRole': 'seller',
      'listingName': 'HP EliteBook 840 G5',
    });
    expect(nameShown(tester), 'Xavier Bravin');
    expect(find.text('SELLER'), findsOneWidget);
    expect(find.text('Incoming call'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    // The hint is in the readable text colour, not the dimmest one.
    final about = tester.widget<Text>(find.text('About HP EliteBook 840 G5'));
    expect(about.style?.color, BrokaColors.textMid);
    final accept = tester.widget<Text>(find.text('Accept'));
    expect(accept.style?.color, isNot(BrokaColors.textLow));
    await close(tester);
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 568 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, {
      'peerName': 'Wanjiku Kamau-Otieno Wambui',
      'isCaller': false,
      'callerRole': 'buyer',
      'callType': 'video',
      'listingName': 'Samsung Galaxy A54 with a very long listing title indeed',
    });
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  // The direct chat passed the word "Buyer" as the name whenever the seller
  // called. It passes the buyer's name now, and who they are.
  testWidgets("a seller's call from the chat carries the buyer's name", (tester) async {
    ApiService.currentUserId = 'seller-1';
    setFakeRoute((uri) {
      if (uri.path == '/calls/initiate') {
        return {'status': 'sent', 'room_id': 'room-1', 'call_token': 't'};
      }
      if (uri.path == '/auth/user/buyer-7') {
        return {'id': 'buyer-7', 'name': 'Amina Wanjiru', 'is_online': false};
      }
      if (uri.path.startsWith('/negotiate/deal-status')) return {'has_deal': false};
      return null;
    });
    RouteSettings? call;
    final listing = Listing.fromJson({
      ...fakeListingJson(1), 'seller_id': 'seller-1', 'listing_type': 'fixed', 'status': 'active',
    });
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (settings) {
        if (settings.name == '/voip-call') call = settings;
        return MaterialPageRoute(
          settings: settings.name == '/'
              ? RouteSettings(name: '/', arguments: {
                  'listing': listing, 'role': 'seller', 'buyer_id': 'buyer-7',
                })
              : settings,
          builder: (_) => settings.name == '/voip-call'
              ? const Scaffold(body: Text('calling'))
              : const NegotiationScreen(animateBackground: false),
        );
      },
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The chat's own header names the buyer too.
    expect(find.text('Amina Wanjiru'), findsWidgets);

    await tester.tap(find.byTooltip('Voice call'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Start a secure call with Amina Wanjiru?'), findsOneWidget);
    await tester.tap(find.text('Call Now'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final args = call!.arguments as Map;
    expect(args['peerName'], 'Amina Wanjiru');
    expect(args['peerId'], 'buyer-7');
    expect(args['callerRole'], 'seller');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  // Review, 2026-10-08: a redial's screen opens on top of the call it
  // replaced. That call then ends - and its screen popped whatever was on
  // top, hanging up the redial, and stopped the foreground service the
  // redial's call runs on.
  testWidgets("a replaced call's screen closes itself, not the redial's on top",
      (tester) async {
    final serviceCalls = <String>[];
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.broka.app/call_service'), (call) async {
      serviceCalls.add(call.method);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.broka.app/call_service'), (_) async => null);
      ActiveCall.instance.reset();
    });

    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const SizedBox()));
    nav.currentState!.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/voip-call', arguments: {
        'roomId': 'room-1',
        'userId': 'seller-1',
        'callToken': 't',
        'peerName': 'Amina Wanjiru',
        'isCaller': true,
        'callerRole': 'seller',
        'listingName': 'Airtel 5G router',
      }),
      builder: (_) => const VoipCallScreen(animateBackground: false),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    // The redial's screen, now the phone's call, opens on top before the
    // replaced call (microphone refused here: it fails at once) is taken
    // down.
    ActiveCall.instance.begin('room-2', answered: true);
    nav.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const SizedBox(key: Key('redial-screen')),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    serviceCalls.clear();
    await tester.pump(const Duration(seconds: 3));

    expect(find.byKey(const Key('redial-screen')), findsOneWidget);
    expect(find.byType(VoipCallScreen, skipOffstage: false), findsNothing);
    expect(serviceCalls, isNot(contains('stop')),
        reason: "the redial's call keeps its foreground service");
    ActiveCall.instance.reset(); // its keep-alive timer
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
