// The two negotiation screens on Home's visual system (2026-09-26): the
// Zeno negotiation room (NegotiateScreen) and the one-on-one chat
// (NegotiationScreen). Both sat on ChatAmbientBackground under their own
// opaque bars; now they share the constellation, Home's header language and
// Zeno's composer with the rest of the app. In the Zeno room, a new reply is
// written out word by word; the history is simply there.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/safe_payment/escrow_callout.dart';
import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiate_screen.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/chat_ambient_background.dart';
import 'package:broka/widgets/chat_parts.dart';
import 'package:broka/widgets/collapsing_screen_header.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:broka/widgets/zeno_streaming_text.dart';

import 'support/fake_api.dart';

const _reply = 'The seller has come down to 21,000 and says the charger is '
    'included. That is within the range you gave me.';

void main() {
  setUpAll(() async {
    installFakeApi();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Zeno's voice and the chat's voice notes own players and a recorder;
    // nothing plays or records in these tests.
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'com.llfbandit.record/messages',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    // Real glyph widths for the overflow checks: the test font draws every
    // character a full em wide and reports overflows no phone would show.
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts';
    if (Directory(fonts).existsSync()) {
      final roboto = FontLoader('Roboto');
      for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
        roboto.addFont(Future.value(ByteData.view(File('$fonts/$f').readAsBytesSync().buffer)));
      }
      await roboto.load();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'buyer-1';
    ApiService.currentUserName = 'Amina Wanjiru';
    clearFakeRequests();
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return [
          {'role': 'broker', 'content': 'Welcome back, Amina.', 'id': 'm1'},
          {'role': 'buyer', 'content': 'Can he do 20K?', 'via_ai': true, 'id': 'm2'},
          {'role': 'seller', 'content': 'Is it still available?', 'id': 'm3'},
          {'role': 'buyer', 'content': 'Yes, pick up in Westlands', 'id': 'm4'},
        ];
      }
      if (p == '/negotiate/message') return {'role': 'broker', 'content': _reply, 'id': 'm5'};
      if (p.startsWith('/negotiate/deal-status')) return {'has_deal': false};
      if (p == '/auth/user/seller-1') {
        return {
          'id': 'seller-1',
          'name': 'Xavier Bravin',
          'is_online': true,
          'last_seen_label': 'Active now',
          'rating': 4.8,
          'completed_deals': 3,
        };
      }
      return null;
    });
  });

  Widget screen(Widget child) => MaterialApp(
        onGenerateRoute: (_) => MaterialPageRoute(
          settings: RouteSettings(arguments: {
            'listing': Listing.fromJson({
              ...fakeListingJson(1),
              'listing_type': 'fixed',
              'status': 'active',
            }),
            'role': 'buyer',
          }),
          builder: (_) => child,
        ),
      );

  group('Zeno negotiation room', () {
    testWidgets("is on Home's visual system", (tester) async {
      await tester.pumpWidget(screen(const NegotiateScreen(animateBackground: false)));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.byType(ChatAmbientBackground), findsNothing);
      expect(find.text('NEGOTIATION'), findsOneWidget);
      expect(find.byType(BrokaHeaderButton), findsNWidgets(2)); // direct chat, voice
      expect(find.byType(ChatComposerPill), findsOneWidget);
      expect(find.text('Zeno is composing...'), findsNothing);
      // BROKA holds no payments while they are paused: the header no longer
      // says "Escrow protected", and the pay chip doesn't promise security.
      // It names the way that is real - an independent escrow service - and
      // the escrow callout sits above the composer, with Zeno to guide.
      expect(find.text('Zeno mediating · Pay with escrow'), findsOneWidget);
      expect(find.textContaining('Escrow protected'), findsNothing);
      expect(find.byType(EscrowCallout), findsOneWidget);
      expect(find.text('Ask Zeno'), findsOneWidget);
      expect(find.text('Pay securely'), findsNothing);
    });

    testWidgets('the history is there at once; a new reply is written out',
        (tester) async {
      await tester.pumpWidget(screen(const NegotiateScreen(animateBackground: false)));
      await _settle(tester);
      // Picked up from the server: no replaying Zeno's old words.
      expect(find.text('Welcome back, Amina.'), findsOneWidget);
      expect(find.text('Can he do 20K?'), findsOneWidget);
      // The direct thread stays out of Zeno's room.
      expect(find.text('Is it still available?'), findsNothing);

      await tester.enterText(find.byKey(const Key('negotiate-composer')), 'What did he say?');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final shown = tester
          .widget<Text>(find.descendant(
              of: find.byType(ZenoStreamingText).last, matching: find.byType(Text)))
          .textSpan!
          .toPlainText();
      expect(shown, isNot(_reply), reason: 'not the whole reply at once');
      expect(shown, endsWith('▍'));
      expect(_reply, startsWith(shown.replaceAll('▍', '')));

      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(_reply), findsOneWidget);
    });

    testWidgets('nothing overflows on a 320dp phone at a large text size',
        (tester) async {
      _smallPhone(tester);
      await tester.pumpWidget(screen(const NegotiateScreen(animateBackground: false)));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('One-on-one chat', () {
    testWidgets("is on Home's visual system", (tester) async {
      await tester.pumpWidget(screen(const NegotiationScreen(animateBackground: false)));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.byType(ChatAmbientBackground), findsNothing);
      expect(find.text('Xavier Bravin'), findsOneWidget);
      expect(find.byTooltip('Voice call'), findsOneWidget);
      expect(find.byTooltip('Video call'), findsOneWidget);
      // No "agree the deal" step: the buyer pays straight from the chat.
      expect(find.byTooltip('Agree the deal'), findsNothing);
      expect(find.byKey(const Key('pay-now')), findsOneWidget);
      // Not "Pay securely - the seller is paid only after you've received
      // the item": that was BROKA's escrow, which it doesn't run while
      // payments are paused. It says so, and offers an independent one.
      expect(find.textContaining("BROKA doesn't take payments itself yet. Pay with escrow"), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('pay-now')), matching: find.text('Pay with escrow')),
          findsOneWidget);
      expect(find.text('Zeno, guide me'), findsOneWidget);
      expect(find.textContaining('Pay securely'), findsNothing);
      expect(find.byTooltip('Ask Zeno'), findsOneWidget);
      expect(find.byType(ChatComposerPill), findsOneWidget);

      // The direct thread only - Zeno's room stays private.
      expect(find.text('Is it still available?'), findsOneWidget);
      expect(find.text('Can he do 20K?'), findsNothing);
      // Yours on the brand gradient, like Zeno's screen.
      final mine = tester.widget<Container>(find
          .ancestor(of: find.text('Yes, pick up in Westlands'), matching: find.byType(Container))
          .first);
      expect((mine.decoration as BoxDecoration).gradient, isNotNull);
    });

    testWidgets('nothing overflows on a 320dp phone at a large text size',
        (tester) async {
      _smallPhone(tester);
      await tester.pumpWidget(screen(const NegotiationScreen(animateBackground: false)));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });

    // A listing of several units: the buyer says how many, up to what is
    // left, in the pay window itself, and the payment carries the count
    // (the backend takes that many from the seller's stock).
    testWidgets('paying for several units asks how many', (tester) async {
      final bags = Listing.fromJson({
        ...fakeListingJson(1, price: 3500),
        'listing_type': 'direct', 'status': 'active',
        'quantity': 100, 'units_left': 3, 'price_unit': 'bag',
      });
      setFakeRoute((uri) {
        if (uri.path.startsWith('/deal/pay-quote/')) {
          final q = uri.queryParameters;
          final price = double.tryParse(q['agreed_price'] ?? '') ?? 3500;
          return {'deal_id': null, 'goods_amount': price, 'merchant_commission': price * 0.0349,
                  'provider_fee': price * 0.01, 'total_to_pay': price * 1.0449,
                  'agreed_price': price, 'amount_paid': 0, 'balance': price, 'min_part_payment': 100};
        }
        if (uri.path == '/deal/pay') return {'deal_id': 'deal-1', 'total_to_pay': 10971.45};
        if (uri.path.startsWith('/negotiate/deal-status')) return {'has_deal': false};
        return null;
      });
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (s) => MaterialPageRoute(
          settings: RouteSettings(name: s.name, arguments: {'listing': bags, 'role': 'buyer'}),
          builder: (_) => s.name == '/escrow-payment'
              ? const Scaffold(body: Text('payment screen'))
              : const NegotiationScreen(animateBackground: false),
        ),
      ));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('pay-now')));
      await _settle(tester);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byTooltip('More'));
        await _settle(tester);
      }
      // Three are left, so three is the most.
      expect(tester.widget<Text>(find.byKey(const Key('units-value'))).data, '3');
      expect(tester.widget<TextField>(find.byKey(const Key('escrow-pay-amount'))).controller!.text, '10500');

      await tester.enterText(find.byKey(const Key('escrow-pay-phone')), '0712345678');
      await tester.tap(find.byKey(const Key('escrow-pay-confirm')));
      await _settle(tester);
      final sent = fakeRequests.singleWhere((r) => r.uri.path == '/deal/pay').json as Map;
      expect(sent['quantity'], 3);
      expect(sent['agreed_price'], 10500);
      expect(sent.containsKey('amount'), isFalse); // the whole of it
      expect(find.text('payment screen'), findsOneWidget);
    });

    // The pay window opened only after a fee quote came back from E-Confirm,
    // and stopped at "Could not get a payment quote right now" when it
    // didn't. A quote is a preview: the buyer still pays.
    testWidgets('a quote that fails does not stop the buyer paying', (tester) async {
      setFakeRoute((uri) {
        if (uri.path.startsWith('/deal/pay-quote/')) return const FakeResponse.error(statusCode: 502);
        if (uri.path == '/deal/pay') return {'deal_id': 'deal-1', 'total_to_pay': 3657.15};
        if (uri.path.startsWith('/negotiate/deal-status')) return {'has_deal': false};
        return null;
      });
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (s) => MaterialPageRoute(
          settings: RouteSettings(name: s.name, arguments: {
            'listing': Listing.fromJson({...fakeListingJson(1, price: 3500), 'listing_type': 'direct', 'status': 'active'}),
            'role': 'buyer',
          }),
          builder: (_) => s.name == '/escrow-payment'
              ? const Scaffold(body: Text('payment screen'))
              : const NegotiationScreen(animateBackground: false),
        ),
      ));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('pay-now')));
      await _settle(tester);

      expect(find.textContaining('shown on your M-Pesa prompt'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('escrow-pay-amount')), '3500');
      await tester.enterText(find.byKey(const Key('escrow-pay-phone')), '0712345678');
      await tester.tap(find.byKey(const Key('escrow-pay-confirm')));
      await _settle(tester);
      final sent = fakeRequests.singleWhere((r) => r.uri.path == '/deal/pay').json as Map;
      expect(sent['amount'], 3500);
      expect(find.text('payment screen'), findsOneWidget);
    });

    // A seller who went from Zeno's room to the direct chat arrived without
    // the buyer's id: the call went out with no callee_id, the backend
    // refused it, and every call ended in "Could not start the call".
    testWidgets('a seller coming from Zeno can call the buyer', (tester) async {
      ApiService.currentUserId = 'seller-1';
      setFakeRoute((uri) {
        if (uri.path == '/calls/initiate') {
          return {'status': 'sent', 'room_id': 'room-1', 'call_token': 't'};
        }
        if (uri.path.startsWith('/negotiate/deal-status')) return {'has_deal': false};
        return null;
      });
      final listing = Listing.fromJson({
        ...fakeListingJson(1), 'listing_type': 'fixed', 'status': 'active',
      });
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (settings) => MaterialPageRoute(
          settings: settings.name == '/'
              ? RouteSettings(name: '/', arguments: {
                  'listing': listing, 'role': 'seller', 'buyer_id': 'buyer-9',
                })
              : settings,
          builder: (_) => switch (settings.name) {
            '/direct-chat' => const NegotiationScreen(animateBackground: false),
            '/voip-call' => const Scaffold(body: Text('calling')),
            _ => const NegotiateScreen(animateBackground: false),
          },
        ),
      ));
      await _settle(tester);

      await tester.tap(find.byTooltip('Chat directly'));
      await _settle(tester);
      await tester.tap(find.byTooltip('Voice call'));
      await _settle(tester);
      await tester.tap(find.text('Call Now'));
      await _settle(tester);

      final sent = fakeRequests.singleWhere((r) => r.uri.path == '/calls/initiate').json as Map;
      expect(sent['callee_id'], 'buyer-9');
      expect(find.text('calling'), findsOneWidget);
    });
  });

  // A recorder that failed used to fail silently: a start that threw escaped
  // unhandled and the mic button did nothing, and a stop or cancel that
  // threw left the recording bar up with nothing behind it.
  group('Voice notes', () {
    late _FakeRecorder recorder;
    late RecordPlatform realRecorder;

    setUp(() {
      realRecorder = RecordPlatform.instance;
      recorder = _FakeRecorder();
      RecordPlatform.instance = recorder;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => Directory.systemTemp.path);
    });
    tearDown(() => RecordPlatform.instance = realRecorder);

    final mic = find.byTooltip('Record a voice note');

    testWidgets('a recorder that will not start says so', (tester) async {
      recorder.startError = PlatformException(code: 'record', message: 'mic busy');
      await tester.pumpWidget(screen(const NegotiationScreen(animateBackground: false)));
      await _settle(tester);

      await tester.tap(mic);
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Could not start recording. Please try again.'), findsOneWidget);
      expect(mic, findsOneWidget, reason: 'still on the input bar');
    });

    testWidgets('a second tap while starting does not start a second recording',
        (tester) async {
      await tester.pumpWidget(screen(const NegotiationScreen(animateBackground: false)));
      await _settle(tester);

      await tester.tap(mic);
      await tester.tap(mic, warnIfMissed: false);
      await _settle(tester);

      expect(recorder.calls.where((c) => c == 'start'), hasLength(1));
    });

    testWidgets('a recorder that will not stop does not leave the bar up',
        (tester) async {
      recorder.stopError = PlatformException(code: 'record', message: 'stop failed');
      await tester.pumpWidget(screen(const NegotiationScreen(animateBackground: false)));
      await _settle(tester);

      await tester.tap(mic);
      await _settle(tester);
      expect(mic, findsNothing, reason: 'recording');

      await tester.tap(find.byType(ChatSendButton));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(mic, findsOneWidget, reason: 'back on the input bar');
      expect(find.text('Could not save the voice note. Please try again.'), findsOneWidget);
    });

    testWidgets('a recorder that will not cancel does not leave the bar up',
        (tester) async {
      recorder.cancelError = PlatformException(code: 'record', message: 'cancel failed');
      await tester.pumpWidget(screen(const NegotiationScreen(animateBackground: false)));
      await _settle(tester);

      await tester.tap(mic);
      await _settle(tester);
      expect(mic, findsNothing, reason: 'recording');

      await tester.tap(find.byTooltip('Discard the recording'));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(mic, findsOneWidget, reason: 'back on the input bar');
    });
  });
}

/// Stands in for the record plugin's platform side. Its state stream lives
/// on an event channel named after a random recorder id, which a channel
/// mock can't address.
class _FakeRecorder extends RecordPlatform {
  Object? startError;
  Object? stopError;
  Object? cancelError;
  final calls = <String>[];

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async => true;

  @override
  Future<void> start(String recorderId, RecordConfig config,
      {required String path}) async {
    calls.add('start');
    if (startError != null) throw startError!;
  }

  @override
  Future<String?> stop(String recorderId) async {
    calls.add('stop');
    if (stopError != null) throw stopError!;
    return null;
  }

  @override
  Future<void> cancel(String recorderId) async {
    calls.add('cancel');
    if (cancelError != null) throw cancelError!;
  }

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _smallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320 * 2, 640 * 2);
  tester.view.devicePixelRatio = 2.0;
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// pumpAndSettle never returns (the typing dots and the avatar animate).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
