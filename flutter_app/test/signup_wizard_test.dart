// Covers the signup wizard's step split: one question per screen, which of
// them are optional, and the validation that gates each Continue.
//
// Everything here reaches step 3 by skipping phone verification, so no test
// in this file makes a network call. The OTP round trips themselves are
// covered by the backend suite.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/screens/auth_screen.dart';

void main() {
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // local_auth speaks Pigeon; answering keeps the biometrics probe quiet.
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
    await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Create Account, pick an account type, enter a phone, then skip
  /// verification — which lands on the name step without touching the network.
  Future<void> toNameStep(
    WidgetTester tester, {
    String accountType = 'I want to buy',
    String? sellerTier,
  }) async {
    await tester.tap(find.text('Create Account'));
    await settle(tester);

    await tester.tap(find.text(accountType));
    await settle(tester);
    await tester.tap(find.text('Continue'));
    await settle(tester);

    if (sellerTier != null) {
      await tester.tap(find.text(sellerTier));
      await settle(tester);
      await tester.tap(find.text('Continue'));
      await settle(tester);
    }

    await tester.enterText(find.byType(TextField).first, '0706462869');
    await tester.pump();
    await tester.tap(find.text('Skip for now — verify later'));
    await settle(tester);
  }

  /// Walks name -> preferred -> email (skipped) -> password.
  Future<void> toPasswordStep(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, 'Xavier');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await settle(tester);
    await tester.tap(find.text('Continue'));
    await settle(tester);
    await tester.tap(find.text('Skip'));
    await settle(tester);
  }

  Future<void> fillPassword(WidgetTester tester) async {
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'secret123');
    await tester.enterText(fields.at(1), 'secret123');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await settle(tester);
  }

  Future<void> continueStep(WidgetTester tester) async {
    await tester.tap(find.text('Continue'));
    await settle(tester);
  }

  group('step split', () {
    testWidgets('name, preferred name, email and password are separate screens',
        (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);

      // 3 — official name
      expect(find.text('Your Name'), findsOneWidget);
      expect(find.text('Preferred Name'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'Xavier Mwangi');
      await tester.pump();
      await continueStep(tester);

      // 4 — preferred name
      expect(find.text('Preferred Name'), findsOneWidget);
      expect(find.text('What should Zeno call you?'), findsOneWidget);
      await continueStep(tester);

      // 5 — email
      expect(find.text('Email'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await settle(tester);

      // 6 — password
      expect(find.text('Password'), findsWidgets);
      expect(find.text('Confirm Password'), findsOneWidget);
    });

    testWidgets('a buyer sees a ten-step dotted indicator', (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);
      for (final n in ['4', '5', '6', '7', '8', '9']) {
        expect(find.text(n), findsWidgets, reason: 'step $n missing');
      }
    });
  });

  group('validation', () {
    testWidgets('official name is required', (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);
      await continueStep(tester);

      expect(find.text('Please enter your official name'), findsOneWidget);
      expect(find.text('Your Name'), findsOneWidget); // did not advance
    });

    testWidgets('preferred name is optional', (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Xavier');
      await tester.pump();
      await continueStep(tester);

      await continueStep(tester); // leave it blank
      expect(find.text('Email'), findsOneWidget);
    });

    testWidgets('a malformed email is rejected before any request', (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Xavier');
      await tester.pump();
      await continueStep(tester);
      await continueStep(tester);

      await tester.enterText(find.byType(TextField).first, 'not-an-email');
      await tester.pump();
      await tester.tap(find.text('Send Code'));
      await settle(tester);

      expect(find.text('Please enter a valid email address'), findsOneWidget);
    });

    testWidgets('mismatched passwords do not advance', (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Xavier');
      await tester.pump();
      await continueStep(tester);
      await continueStep(tester);
      await tester.tap(find.text('Skip'));
      await settle(tester);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'secret123');
      await tester.enterText(fields.at(1), 'secret124');
      await tester.pump();
      await continueStep(tester);

      expect(find.text('Both passwords must match'), findsWidgets);
      expect(find.text('Confirm Password'), findsOneWidget); // still here
    });

    testWidgets('a short password does not advance', (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Xavier');
      await tester.pump();
      await continueStep(tester);
      await continueStep(tester);
      await tester.tap(find.text('Skip'));
      await settle(tester);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'abc');
      await tester.enterText(fields.at(1), 'abc');
      await tester.pump();
      await continueStep(tester);

      expect(find.text('Password must be at least 6 characters'), findsOneWidget);
    });

    testWidgets('matching passwords advance to the photo step', (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Xavier');
      await tester.pump();
      await continueStep(tester);
      await continueStep(tester);
      await tester.tap(find.text('Skip'));
      await settle(tester);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'secret123');
      await tester.enterText(fields.at(1), 'secret123');
      await tester.pump();
      await continueStep(tester);

      expect(find.text('Your Photo'), findsOneWidget);
    });
  });

  group('back navigation', () {
    testWidgets('Back walks the new steps in reverse', (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Xavier');
      await tester.pump();
      await continueStep(tester);
      expect(find.text('Preferred Name'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await settle(tester);
      expect(find.text('Your Name'), findsOneWidget);
    });

    testWidgets('the typed name survives a trip back', (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Xavier Mwangi');
      await tester.pump();
      await continueStep(tester);
      await tester.tap(find.text('Back'));
      await settle(tester);

      expect(find.text('Xavier Mwangi'), findsOneWidget);
    });
  });

  group('account type branching', () {
    testWidgets('a buyer is never asked what kind of seller they are',
        (tester) async {
      await pumpAuth(tester);
      await tester.tap(find.text('Create Account'));
      await settle(tester);
      // No "buy safely through escrow": BROKA holds no payments while they
      // are paused.
      expect(find.textContaining('see it before you pay'), findsOneWidget);
      expect(find.textContaining('escrow'), findsNothing);
      await tester.tap(find.text('I want to buy'));
      await settle(tester);
      await tester.tap(find.text('Continue'));
      await settle(tester);

      expect(find.text('What kind of seller?'), findsNothing);
      expect(find.text('Phone'), findsOneWidget);
    });

    testWidgets('choosing to sell inserts the seller question', (tester) async {
      await pumpAuth(tester);
      await tester.tap(find.text('Create Account'));
      await settle(tester);
      await tester.tap(find.text('I want to buy and sell'));
      await settle(tester);
      await tester.tap(find.text('Continue'));
      await settle(tester);

      expect(find.text('What kind of seller?'), findsOneWidget);
      expect(find.text('Just a few items'), findsOneWidget);
      expect(find.text("I'm running a business"), findsOneWidget);
    });

    testWidgets('a short-term seller skips business setup entirely',
        (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester,
          accountType: 'I want to buy and sell',
          sellerTier: 'Just a few items');
      await toPasswordStep(tester);
      await fillPassword(tester);

      // Straight from password to the photo step.
      expect(find.text('Your Photo'), findsOneWidget);
      expect(find.text('Business Name'), findsNothing);
    });

    testWidgets('a long-term seller gets business setup after the password',
        (tester) async {
      await pumpAuth(tester);
      await toNameStep(tester,
          accountType: 'I want to buy and sell',
          sellerTier: "I'm running a business");
      await toPasswordStep(tester);
      await fillPassword(tester);

      expect(find.text('Business Name'), findsOneWidget);
      expect(find.text('Your Photo'), findsNothing);
    });
  });

  group('business setup', () {
    /// Drives a long-term seller as far as the business-name step.
    Future<void> toBusinessStep(WidgetTester tester) async {
      await toNameStep(tester,
          accountType: 'I want to buy and sell',
          sellerTier: "I'm running a business");
      await toPasswordStep(tester);
      await fillPassword(tester);
    }

    testWidgets('business name is required', (tester) async {
      await pumpAuth(tester);
      await toBusinessStep(tester);
      await continueStep(tester);

      expect(find.text('Please enter your business name'), findsOneWidget);
      expect(find.text('Business Name'), findsOneWidget);
    });

    testWidgets('each business question is its own screen', (tester) async {
      await pumpAuth(tester);
      await toBusinessStep(tester);

      await tester.enterText(find.byType(TextField).first, 'Clanix');
      await tester.pump();
      await continueStep(tester);
      expect(find.text('What You Sell'), findsOneWidget);

      await continueStep(tester); // category has a preselected default
      expect(find.text('Location'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Sira');
      await tester.pump();
      await continueStep(tester);
      expect(find.text('About the Business'), findsOneWidget);
    });

    testWidgets('the description is optional', (tester) async {
      await pumpAuth(tester);
      await toBusinessStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Clanix');
      await tester.pump();
      await continueStep(tester);
      await continueStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Sira');
      await tester.pump();
      await continueStep(tester);

      await tester.tap(find.text('Skip'));
      await settle(tester);
      expect(find.text('Your Business Name'), findsOneWidget);
    });

    testWidgets('the preview composes name, category and location',
        (tester) async {
      await pumpAuth(tester);
      await toBusinessStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Clanix');
      await tester.pump();
      await continueStep(tester);
      await continueStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Sira');
      await tester.pump();
      await continueStep(tester);
      await tester.tap(find.text('Skip'));
      await settle(tester);

      expect(find.text('Clanix · Electronics · Sira'), findsOneWidget);
    });

    testWidgets('tapping a preview row jumps back to that question',
        (tester) async {
      await pumpAuth(tester);
      await toBusinessStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Clanix');
      await tester.pump();
      await continueStep(tester);
      await continueStep(tester);
      await tester.enterText(find.byType(TextField).first, 'Sira');
      await tester.pump();
      await continueStep(tester);
      await tester.tap(find.text('Skip'));
      await settle(tester);

      // Correcting a typo must not mean backing out through three screens.
      await tester.tap(find.text('Location'));
      await settle(tester);
      expect(find.text('Location'), findsOneWidget);
      expect(find.text('The area buyers would come to'), findsOneWidget);
    });
  });
}
