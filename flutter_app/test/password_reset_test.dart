// Forgotten and changed passwords, and Settings' language choice.
//
// "Forgot password?" on the login screen was a label with nothing behind it,
// and Settings had no way to change a password. Now the login link opens an
// SMS-code reset (features/auth/presentation/password_reset_screen.dart) and
// Settings has Change password (change_password_screen.dart), each through
// the real ApiClient against the fake backend, so what is sent is checked
// as well as what is shown.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/auth/presentation/change_password_screen.dart';
import 'package:broka/features/auth/presentation/password_reset_screen.dart';
import 'package:broka/screens/auth_screen.dart';
import 'package:broka/screens/settings_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/otp_code_field.dart';

import 'support/fake_api.dart';

const _session = {
  'ok': true,
  'access_token': 'new-access',
  'refresh_token': 'new-refresh',
  'token_type': 'bearer',
  'user_id': 'user-1',
  'name': 'Grace Akinyi',
  'nickname': 'Grace',
  'phone': '+254712345678',
  'account_type': 'buyer',
  'lat': -1.28,
  'lng': 36.8,
};

/// The reset and change endpoints answering as the backend does when all
/// goes well; [overrides] answer first.
FakeRoute _backend([Map<String, Object?> overrides = const {}]) => (uri) {
      if (overrides.containsKey(uri.path)) return overrides[uri.path];
      switch (uri.path) {
        case '/auth/password/forgot':
          return {'ok': true, 'phone': '+254712345678', 'expires_in_seconds': 300};
        case '/auth/password/forgot/verify':
          return {'ok': true, 'reset_token': 'reset-tok'};
        case '/auth/password/reset':
        case '/auth/password/change':
          return _session;
        case '/auth/me':
          return {'id': 'user-1', 'name': 'Grace Akinyi', 'location_visible': true};
      }
      return null;
    };

List<FakeRequest> _sent(String path) =>
    fakeRequests.where((r) => r.uri.path == path).toList();

void main() {
  setUpAll(installFakeApi);

  setUp(() async {
    // The SMS Retriever's native side, as signup's tests answer it.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.broka.app/sms_retriever'),
      (call) async => call.method == 'getAppSignature' ? 'FA+9qCX9VSu' : true,
    );
    SharedPreferences.setMockInitialValues({});
    await ApiService.loadSavedSession();
    clearFakeRequests();
    setFakeRoute(_backend());
  });

  tearDown(() => setFakeRoute(null));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// [screen] pushed over a home route; returns what it popped with.
  Future<List<Object?>> open(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final popped = <Object?>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => Scaffold(
        body: Center(child: TextButton(
          onPressed: () async =>
              popped.add(await Navigator.push(context, MaterialPageRoute(builder: (_) => screen))),
          child: const Text('open'),
        )),
      )),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
    return popped;
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await settle(tester);
  }

  group('Forgot password', () {
    testWidgets('number, SMS code, new password - and this phone is signed in', (tester) async {
      final popped = await open(tester,
          const PasswordResetScreen(phone: '+254712345678', animateBackground: false));

      // Starts from the number typed on the login screen.
      expect(find.text('712345678'), findsOneWidget);
      await tapText(tester, 'Send code');
      expect(_sent('/auth/password/forgot').single.json,
          containsPair('phone', '+254712345678'));
      expect(find.text('Code sent to +254712345678'), findsOneWidget);

      // A full code submits itself, from whichever way it arrived.
      final code = tester.widget<OtpCodeField>(find.byType(OtpCodeField)).controller;
      code.text = '481902';
      await settle(tester);
      expect(_sent('/auth/password/forgot/verify').single.json,
          {'phone': '+254712345678', 'code': '481902'});

      await tester.enterText(find.byKey(const Key('reset-new-password')), 'NewPassw0rd');
      await tester.enterText(find.byKey(const Key('reset-confirm-password')), 'NewPassw0rd');
      await tapText(tester, 'Save password');

      expect(_sent('/auth/password/reset').single.json,
          {'reset_token': 'reset-tok', 'new_password': 'NewPassw0rd'});
      // It says it worked before it goes anywhere: the screen used to close
      // the moment the server answered, and someone who reset from the
      // login screen landed on Home with no word that anything happened.
      expect(popped, isEmpty);
      expect(find.byKey(const Key('reset-done')), findsOneWidget);
      expect(find.text('Password reset'), findsOneWidget);
      expect(find.textContaining("You're signed in with your new password"), findsOneWidget);
      await tapText(tester, 'Continue');
      expect(popped, [true]);
      expect(ApiService.authToken, 'new-access');
      expect(ApiService.currentUserId, 'user-1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), 'new-refresh');
      // The password itself is never kept on the phone.
      expect(prefs.getKeys().where((k) => prefs.get(k) == 'NewPassw0rd'), isEmpty);
    });

    testWidgets("an unknown number is told so, and nothing moves on", (tester) async {
      setFakeRoute(_backend({
        '/auth/password/forgot': const FakeResponse(
            {'detail': 'No BROKA account uses this number. Check it, or create an account.'},
            statusCode: 404),
      }));
      await open(tester, const PasswordResetScreen(phone: '+254799999999', animateBackground: false));
      await tapText(tester, 'Send code');
      expect(find.textContaining('No BROKA account uses this number'), findsOneWidget);
      expect(find.byType(OtpCodeField), findsNothing);
    });

    testWidgets('a wrong code says so and stays on the code', (tester) async {
      setFakeRoute(_backend({
        '/auth/password/forgot/verify':
            const FakeResponse({'detail': 'Incorrect code'}, statusCode: 400),
      }));
      await open(tester, const PasswordResetScreen(phone: '+254712345678', animateBackground: false));
      await tapText(tester, 'Send code');
      tester.widget<OtpCodeField>(find.byType(OtpCodeField)).controller.text = '000000';
      await settle(tester);
      expect(find.text('Incorrect code'), findsOneWidget);
      expect(find.byKey(const Key('reset-new-password')), findsNothing);
    });

    testWidgets('a refused reset says it failed, and why', (tester) async {
      setFakeRoute(_backend({
        '/auth/password/reset': const FakeResponse(
            {'detail': 'This reset has expired. Request a new code and try again.'},
            statusCode: 400),
      }));
      final popped = await open(tester,
          const PasswordResetScreen(phone: '+254712345678', animateBackground: false));
      await tapText(tester, 'Send code');
      tester.widget<OtpCodeField>(find.byType(OtpCodeField)).controller.text = '481902';
      await settle(tester);
      await tester.enterText(find.byKey(const Key('reset-new-password')), 'NewPassw0rd');
      await tester.enterText(find.byKey(const Key('reset-confirm-password')), 'NewPassw0rd');
      await tapText(tester, 'Save password');

      expect(find.textContaining('Your password was not changed'), findsOneWidget);
      expect(find.textContaining('This reset has expired'), findsOneWidget);
      expect(find.byKey(const Key('reset-done')), findsNothing);
      expect(popped, isEmpty);
    });

    testWidgets("an answer that never came says it can't tell, and what to do", (tester) async {
      setFakeRoute(_backend({
        '/auth/password/reset': const FakeResponse(null, statusCode: 503),
      }));
      await open(tester, const PasswordResetScreen(phone: '+254712345678', animateBackground: false));
      await tapText(tester, 'Send code');
      tester.widget<OtpCodeField>(find.byType(OtpCodeField)).controller.text = '481902';
      await settle(tester);
      await tester.enterText(find.byKey(const Key('reset-new-password')), 'NewPassw0rd');
      await tester.enterText(find.byKey(const Key('reset-confirm-password')), 'NewPassw0rd');
      await tapText(tester, 'Save password');

      expect(find.textContaining("couldn't confirm"), findsOneWidget);
      expect(find.byKey(const Key('reset-done')), findsNothing);
    });

    testWidgets('passwords that differ or are too short are caught before sending', (tester) async {
      await open(tester, const PasswordResetScreen(phone: '+254712345678', animateBackground: false));
      await tapText(tester, 'Send code');
      tester.widget<OtpCodeField>(find.byType(OtpCodeField)).controller.text = '481902';
      await settle(tester);

      await tester.enterText(find.byKey(const Key('reset-new-password')), 'abc');
      await tester.enterText(find.byKey(const Key('reset-confirm-password')), 'abc');
      await tapText(tester, 'Save password');
      expect(find.text('Password must be at least 6 characters'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('reset-new-password')), 'NewPassw0rd');
      await tester.enterText(find.byKey(const Key('reset-confirm-password')), 'NewPassw0rX');
      await tapText(tester, 'Save password');
      expect(find.text('Both passwords must match'), findsOneWidget);
      expect(_sent('/auth/password/reset'), isEmpty);
    });

    testWidgets("signed in, the code can only go to the account's own number", (tester) async {
      await open(tester, const PasswordResetScreen(
          phone: '+254712345678', lockPhone: true, animateBackground: false));
      final field = tester.widget<TextField>(find.descendant(
          of: find.byKey(const Key('reset-phone')), matching: find.byType(TextField)));
      expect(field.enabled, isFalse);
    });

    test('splitPhone separates the dial code the picker knows', () {
      expect(splitPhone('+256772123456'), ('+256', '772123456'));
      expect(splitPhone(null), ('+254', ''));
    });
  });

  group('Change password', () {
    testWidgets('changes it and keeps this phone signed in', (tester) async {
      final popped = await open(tester, const ChangePasswordScreen(animateBackground: false));
      await tester.enterText(find.byKey(const Key('change-current')), 'OldPassw0rd');
      await tester.enterText(find.byKey(const Key('change-new')), 'NewPassw0rd');
      await tester.enterText(find.byKey(const Key('change-confirm')), 'NewPassw0rd');
      await tapText(tester, 'Save new password');

      expect(_sent('/auth/password/change').single.json,
          {'current_password': 'OldPassw0rd', 'new_password': 'NewPassw0rd'});
      expect(popped, [true]);
      // The server signed every session out but this one's replacement.
      expect(ApiService.authToken, 'new-access');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), 'new-refresh');
    });

    testWidgets("a wrong current password is the server's word for it", (tester) async {
      setFakeRoute(_backend({
        '/auth/password/change':
            const FakeResponse({'detail': 'Your current password is wrong'}, statusCode: 400),
      }));
      final popped = await open(tester, const ChangePasswordScreen(animateBackground: false));
      await tester.enterText(find.byKey(const Key('change-current')), 'not-it');
      await tester.enterText(find.byKey(const Key('change-new')), 'NewPassw0rd');
      await tester.enterText(find.byKey(const Key('change-confirm')), 'NewPassw0rd');
      await tapText(tester, 'Save new password');
      expect(find.text('Your current password is wrong'), findsOneWidget);
      expect(popped, isEmpty);
    });

    testWidgets('a forgotten current password goes to the SMS reset for this account', (tester) async {
      SharedPreferences.setMockInitialValues({'auth_token': 'tok', 'user_id': 'user-1',
          'user_phone': '+254712345678'});
      await ApiService.loadSavedSession();
      await open(tester, const ChangePasswordScreen(animateBackground: false));
      await tapText(tester, 'Forgot it? Reset with an SMS code');
      expect(find.byType(PasswordResetScreen), findsOneWidget);
      expect(find.text('712345678'), findsOneWidget);
    });
  });

  group('Settings', () {
    testWidgets('has Change password', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen(animateBackground: false)));
      await settle(tester);
      // The list builds lazily: scroll Security into being first.
      await tester.scrollUntilVisible(find.byKey(const Key('settings-change-password')), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const Key('settings-change-password')));
      await settle(tester);
      expect(find.byType(ChangePasswordScreen), findsOneWidget);
    });

    testWidgets('offers English and Kiswahili, and nothing "coming soon"', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen(animateBackground: false)));
      await settle(tester);

      final choices = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .map((c) => (c.label as Text).data).toList();
      expect(choices, ['English', 'Kiswahili']);
      expect(find.textContaining('Coming soon'), findsNothing);
      for (final name in ['Dholuo', 'Kikuyu', 'Luganda', 'Sheng']) {
        expect(find.textContaining(name), findsNothing, reason: name);
      }

      // Kiswahili is chosen, and sent.
      clearFakeRequests();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Kiswahili'));
      await settle(tester);
      expect(ApiService.currentUserLanguage, 'swahili');
      expect(fakeRequests.where((r) => r.uri.path == '/auth/language'), isNotEmpty);
    });
  });

  group('Login', () {
    setUp(() {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMessageCodec();
      for (final name in const ['isDeviceSupported', 'deviceCanSupportBiometrics', 'getEnrolledBiometrics']) {
        messenger.setMockMessageHandler(
          'dev.flutter.pigeon.local_auth_android.LocalAuthApi.$name',
          (ByteData? m) async => codec.encodeMessage(
            <Object?>[name == 'getEnrolledBiometrics' ? <Object?>[] : true],
          ),
        );
      }
    });

    testWidgets('"Forgot password?" opens the reset with the number typed', (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.enterText(find.byType(TextField).first, '0712345678');
      await tester.ensureVisible(find.byKey(const Key('login-forgot-password')));
      await tester.tap(find.byKey(const Key('login-forgot-password')));
      await settle(tester);

      expect(find.byType(PasswordResetScreen), findsOneWidget);
      expect(tester.widget<PasswordResetScreen>(find.byType(PasswordResetScreen)).phone,
          '+254712345678');
    });
  });
}
