// The final sign-up step: three declarations, both documents, and what the
// request actually carries.
//
// The wizard is walked for real as far as the confirmation step. The selfie
// step is the only part that cannot run headless, so a fake `/selfie` route
// returns a 1x1 PNG exactly as the camera route would. Registration HTTP is
// intercepted with package:http's MockClient through runWithClient, the same
// wiring ApiService uses in the app.
import 'dart:async';
import 'dart:convert';

import 'package:broka/core/legal/legal_documents.dart';
import 'package:broka/main.dart' show BrokaColors;
import 'package:broka/screens/auth_screen.dart';
import 'package:broka/screens/privacy_screen.dart';
import 'package:broka/screens/terms_screen.dart';
import 'package:broka/widgets/gradient_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

http.Response _json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

class _FakeSelfie extends StatelessWidget {
  const _FakeSelfie();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.pop(context, _png1x1),
            child: const Text('Fake capture'),
          ),
        ),
      );
}

class _HomeStub extends StatelessWidget {
  const _HomeStub();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Home')));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

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

  Future<void> pumpAuth(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      routes: {
        '/selfie': (_) => const _FakeSelfie(),
        '/terms': (_) => const TermsScreen(animateBackground: false),
        '/privacy': (_) => const PrivacyScreen(animateBackground: false),
        '/home': (_) => const _HomeStub(),
      },
      home: const AuthScreen(),
    ));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await settle(tester);
  }

  /// Buyer wizard: account type -> phone (OTP skipped) -> name ->
  /// preferred -> email (skipped) -> password -> selfie -> Confirm.
  Future<void> toConfirmStep(WidgetTester tester) async {
    await tapText(tester, 'Create Account');
    await tapText(tester, 'I want to buy');
    await tapText(tester, 'Continue');

    await tester.enterText(find.byType(TextField).first, '0706462869');
    await tester.pump();
    await tapText(tester, 'Skip for now — verify later');

    await tester.enterText(find.byType(TextField).first, 'Xavier Mwangi');
    await tester.pump();
    await tapText(tester, 'Continue'); // name
    await tapText(tester, 'Continue'); // preferred name (optional)
    await tapText(tester, 'Skip'); // email (optional)
    await tester.enterText(find.byType(TextField).at(0), 'secret123');
    await tester.enterText(find.byType(TextField).at(1), 'secret123');
    await tester.pump();
    await tapText(tester, 'Continue'); // password

    await tapText(tester, 'Take Profile Selfie');
    await tapText(tester, 'Fake capture');
    await tapText(tester, 'Continue'); // photo -> confirm

    expect(find.text('Before creating your BROKA account'), findsOneWidget);
  }

  bool checked(WidgetTester tester, String key) =>
      tester.widget<Checkbox>(find.byKey(Key(key))).value ?? false;

  VoidCallback? cta(WidgetTester tester) =>
      tester.widget<GradientButton>(find.byKey(const Key('signup-activate')))
          .onPressed;

  Future<void> tick(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await settle(tester);
  }

  Future<void> tickAll(WidgetTester tester) async {
    await tick(tester, 'signup-age');
    await tick(tester, 'signup-terms');
    await tick(tester, 'signup-privacy');
  }

  testWidgets('all three declarations start unchecked and the CTA is dead',
      (tester) async {
    await pumpAuth(tester);
    await toConfirmStep(tester);

    expect(find.text('All three declarations are required.'), findsOneWidget);
    expect(checked(tester, 'signup-age'), isFalse);
    expect(checked(tester, 'signup-terms'), isFalse);
    expect(checked(tester, 'signup-privacy'), isFalse);
    expect(cta(tester), isNull);

    // The disabled button still explains itself when tapped, and the tap
    // cannot reach registration.
    await tester.ensureVisible(find.byKey(const Key('signup-activate')));
    var requests = 0;
    final mock = MockClient((req) async {
      requests++;
      return _json({'detail': 'should not be called'}, 422);
    });
    await http.runWithClient(() async {
      await tester.tap(find.byKey(const Key('signup-activate')));
      await settle(tester);
    }, () => mock);

    expect(find.byKey(const Key('signup-legal-error')), findsOneWidget);
    expect(find.text('Confirm all three declarations to create your account.'),
        findsOneWidget);
    expect(requests, 0);
  });

  testWidgets('the exact declaration wording is shown', (tester) async {
    await pumpAuth(tester);
    await toConfirmStep(tester);

    expect(
      find.textContaining(LegalDocuments.ageDeclaration, findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(LegalDocuments.termsPrefix, findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(LegalDocuments.privacyPrefix, findRichText: true),
      findsOneWidget,
    );

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(LegalDocuments.ageDeclaration),
      findsWidgets,
      reason: 'the checkbox and its sentence both name what is confirmed',
    );
    semantics.dispose();
  });

  testWidgets('the CTA enables only when all three are ticked', (tester) async {
    await pumpAuth(tester);
    await toConfirmStep(tester);

    await tick(tester, 'signup-age');
    await tick(tester, 'signup-terms');
    expect(cta(tester), isNull, reason: 'two of three is not enough');

    await tick(tester, 'signup-privacy');
    expect(checked(tester, 'signup-age'), isTrue);
    expect(checked(tester, 'signup-terms'), isTrue);
    expect(checked(tester, 'signup-privacy'), isTrue);
    expect(cta(tester), isNotNull);
  });

  testWidgets('the link text is underlined, so it reads as a link',
      (tester) async {
    await pumpAuth(tester);
    await toConfirmStep(tester);

    final link = find.descendant(
      of: find.byKey(const Key('signup-terms-link')),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(link).style?.decoration,
        TextDecoration.underline);
    expect(tester.widget<Text>(link).style?.color, isNot(BrokaColors.textHigh));
  });

  testWidgets('the Terms link opens the Terms and back keeps the form',
      (tester) async {
    await pumpAuth(tester);
    await toConfirmStep(tester);
    await tick(tester, 'signup-terms');

    await tester.ensureVisible(find.byKey(const Key('signup-terms-link')));
    await tester.tap(find.byKey(const Key('signup-terms-link')));
    await settle(tester);
    expect(find.byType(TermsScreen), findsOneWidget);
    expect(find.text('Terms of Use and Service'), findsOneWidget);

    Navigator.of(tester.element(find.byType(TermsScreen))).pop();
    await settle(tester);

    // Opening a document is not agreement, and it does not lose anything:
    // the tick and the rest of the wizard are still there.
    expect(find.text('Before creating your BROKA account'), findsOneWidget);
    expect(checked(tester, 'signup-terms'), isTrue);
    expect(checked(tester, 'signup-age'), isFalse);
    expect(find.textContaining('Xavier Mwangi', findRichText: true),
        findsOneWidget);
  });

  testWidgets('the Privacy link opens the Privacy Policy screen',
      (tester) async {
    await pumpAuth(tester);
    await toConfirmStep(tester);

    await tester.ensureVisible(find.byKey(const Key('signup-privacy-link')));
    await tester.tap(find.byKey(const Key('signup-privacy-link')));
    await settle(tester);
    expect(find.byType(PrivacyScreen), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.textContaining('Not yet published.', findRichText: true),
        findsWidgets);

    Navigator.of(tester.element(find.byType(PrivacyScreen))).pop();
    await settle(tester);
    expect(checked(tester, 'signup-privacy'), isFalse,
        reason: 'reading the policy is not acknowledging it');
  });

  testWidgets('registration sends the declarations and the versions shown',
      (tester) async {
    await pumpAuth(tester);
    await toConfirmStep(tester);
    await tickAll(tester);

    http.Request? sent;
    final mock = MockClient((req) async {
      sent = req;
      // Refused on purpose: this test is about the request body, and a
      // refusal keeps the signed-in navigation out of a widget test.
      return _json({
        'detail': "BROKA's Terms of Use and Service have been updated.",
      }, 422);
    });

    await http.runWithClient(() async {
      await tester.ensureVisible(find.byKey(const Key('signup-activate')));
      await tester.tap(find.byKey(const Key('signup-activate')));
      await settle(tester);
    }, () => mock);

    expect(sent, isNotNull);
    expect(sent!.url.path, '/auth/register');
    final body = jsonDecode(sent!.body) as Map<String, dynamic>;
    expect(body['legal_acceptance'], {
      'age_confirmed': true,
      'terms_accepted': true,
      'privacy_acknowledged': true,
      'terms_version': LegalDocuments.terms.version,
      'privacy_version': LegalDocuments.privacy.version,
    });
  });

  testWidgets('a refused registration shows the reason and stays on the step',
      (tester) async {
    await pumpAuth(tester);
    await toConfirmStep(tester);
    await tickAll(tester);

    final mock = MockClient((req) async => _json({
          'detail': 'Acknowledge BROKA\'s Privacy Policy before creating an account.',
        }, 422));

    await http.runWithClient(() async {
      await tester.ensureVisible(find.byKey(const Key('signup-activate')));
      await tester.tap(find.byKey(const Key('signup-activate')));
      await settle(tester);
    }, () => mock);

    expect(
      find.text('Acknowledge BROKA\'s Privacy Policy before creating an account.'),
      findsOneWidget,
    );
    expect(find.text('Before creating your BROKA account'), findsOneWidget);
    expect(find.text('Home'), findsNothing, reason: 'no false success');
  });

  testWidgets('two taps in flight send one registration', (tester) async {
    await pumpAuth(tester);
    await toConfirmStep(tester);
    await tickAll(tester);

    var requests = 0;
    final first = Completer<http.Response>();
    final mock = MockClient((req) {
      requests++;
      return first.future;
    });

    await http.runWithClient(() async {
      await tester.ensureVisible(find.byKey(const Key('signup-activate')));
      await tester.tap(find.byKey(const Key('signup-activate')));
      await tester.pump(); // first request is now in flight
      await tester.tap(find.byKey(const Key('signup-activate')));
      await tester.pump();
      first.complete(_json({'detail': 'nope'}, 422));
      await settle(tester);
    }, () => mock);

    expect(requests, 1);
  });
}
