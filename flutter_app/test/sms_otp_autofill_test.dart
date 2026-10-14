// The signup wizard's automatic OTP capture (Android SMS Retriever), end to
// end on the Dart side: a code the native bridge delivers must land in the
// verify step's field and be submitted without the user touching anything.
//
// Reported as "the automatic SMS OTP reader is not working": the listener
// only accepted a code on step 2, which stopped being the verify step when
// the account-type and seller questions were put in front of the phone
// number. Every captured code was thrown away.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/screens/auth_screen.dart';
import 'package:broka/services/sms_autofill_service.dart';

import 'support/fake_api.dart';

const _events = 'com.broka.app/sms_retriever_events';

void main() {
  // Set once the screen listens to the retriever's event channel.
  bool listening = false;
  Duration otpRequestDelay = Duration.zero;

  /// What SmsRetrieverBridge.kt sends when the SMS arrives. Sent through the
  /// messenger and awaited, rather than through MockStreamHandler's sink,
  /// whose delivery runs off the test's clock and lands after the asserts.
  Future<void> deliverSms(String code) async {
    expect(listening, isTrue, reason: 'the retriever stream was never listened to');
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            _events, const StandardMethodCodec().encodeSuccessEnvelope(code), (_) {});
  }

  setUpAll(() {
    installFakeApi(route: (uri) {
      if (uri.path.endsWith('/auth/otp/request')) {
        return FakeResponse(
          {'ok': true, 'phone': '+254706462869', 'expires_in_seconds': 300},
          delay: otpRequestDelay,
        );
      }
      if (uri.path.endsWith('/auth/otp/verify')) {
        return const {'ok': true, 'phone_verify_token': 'verify-token'};
      }
      return null;
    });
  });

  setUp(() {
    listening = false;
    otpRequestDelay = Duration.zero;
    clearFakeRequests();
    SmsAutofillService.resetForTest();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    const codec = StandardMessageCodec();
    for (final name in const [
      'isDeviceSupported',
      'deviceCanSupportBiometrics',
      'getEnrolledBiometrics',
    ]) {
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.local_auth_android.LocalAuthApi.$name',
        (ByteData? m) async => codec.encodeMessage(
          <Object?>[name == 'getEnrolledBiometrics' ? <Object?>[] : true],
        ),
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.broka.app/sms_retriever'),
      (call) async => call.method == 'getAppSignature' ? 'FA+9qCX9VSu' : true,
    );
    messenger.setMockStreamHandler(
      const EventChannel(_events),
      MockStreamHandler.inline(onListen: (_, __) {
        listening = true;
      }),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : null,
    );
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
  }

  /// Create Account, buyer, a phone number, then Send Code - which requests
  /// the code for real (against the fake API) and arms the retriever.
  Future<void> requestCode(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Create Account'));
    await settle(tester);
    await tester.tap(find.text('I want to buy'));
    await settle(tester);
    await tester.tap(find.text('Continue'));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '0706462869');
    await tester.pump();
    await tester.tap(find.text('Send Code'));
  }

  List<FakeRequest> verifyRequests() =>
      fakeRequests.where((r) => r.uri.path.endsWith('/auth/otp/verify')).toList();

  testWidgets('the request carries this build\'s app signature', (tester) async {
    await requestCode(tester);
    await settle(tester);

    final request = fakeRequests.singleWhere((r) => r.uri.path.endsWith('/auth/otp/request'));
    expect((request.json as Map)['app_signature'], 'FA+9qCX9VSu');
  });

  testWidgets('a code captured on the verify step is filled and submitted', (tester) async {
    await requestCode(tester);
    await settle(tester);
    expect(find.textContaining('Code sent to'), findsOneWidget);

    await deliverSms('481902');
    await settle(tester);

    final verify = verifyRequests();
    expect(verify, hasLength(1));
    expect((verify.single.json as Map)['code'], '481902');
    // Verified: the wizard moved on to the name step by itself.
    expect(find.text('Official Name'), findsOneWidget);
  });

  testWidgets('a code that beats the request back is kept for the verify step',
      (tester) async {
    // The SMS is sent before the server answers, so on a slow connection
    // it arrives while the phone step is still waiting.
    otpRequestDelay = const Duration(seconds: 2);
    await requestCode(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Code sent to'), findsNothing);

    await deliverSms('481902');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);

    final verify = verifyRequests();
    expect(verify, hasLength(1));
    expect((verify.single.json as Map)['code'], '481902');
  });

  testWidgets('a code arriving while a resend is in flight is still submitted',
      (tester) async {
    await requestCode(tester);
    await settle(tester);

    // Past the resend cooldown.
    for (var i = 0; i < 125; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    otpRequestDelay = const Duration(seconds: 2);
    await tester.tap(find.text('Resend code'));
    await tester.pump(const Duration(milliseconds: 100));

    await deliverSms('551177');
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);

    final verify = verifyRequests();
    expect(verify, hasLength(1));
    expect((verify.single.json as Map)['code'], '551177');
  });

  testWidgets('a code arriving after the user left sign-up is ignored', (tester) async {
    await requestCode(tester);
    await settle(tester);
    await tester.tap(find.text('Login').first);
    await settle(tester);

    await deliverSms('481902');
    await settle(tester);
    expect(verifyRequests(), isEmpty);
  });
}
