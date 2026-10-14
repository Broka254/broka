// Covers the two auth-screen behaviours that were reported as unreliable:
// OTP code entry (which must accept a code arriving from ANY source, not just
// typing) and composing a typed local number into E.164.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/widgets/country_phone_field.dart';
import 'package:broka/widgets/otp_code_field.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
    );

void main() {
  group('composeE164', () {
    test('drops the leading zero people type out of habit', () {
      expect(composeE164('+254', '0706462869'), '+254706462869');
    });

    test('leaves an already-national number alone', () {
      expect(composeE164('+254', '706462869'), '+254706462869');
    });

    test('ignores spaces and punctuation', () {
      expect(composeE164('+254', '0706 462 869'), '+254706462869');
    });

    test('honours a non-default dial code', () {
      expect(composeE164('+256', '0772123456'), '+256772123456');
    });

    test('is empty-safe', () {
      expect(composeE164('+254', ''), '+254');
    });
  });

  group('countryForDialCode', () {
    test('resolves a known code', () {
      expect(countryForDialCode('+255').name, 'Tanzania');
    });

    test('falls back to Kenya rather than throwing on an unknown code', () {
      expect(countryForDialCode('+999').dialCode, '+254');
    });
  });

  group('OtpCodeField', () {
    testWidgets('renders one box per digit', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(_wrap(OtpCodeField(controller: ctrl, autofocus: false)));
      // Five placeholder dashes plus one caret in the active box would vary
      // with focus, so assert on the box count instead.
      expect(find.byType(AnimatedContainer), findsNWidgets(6));
    });

    testWidgets('a code written straight to the controller fills every box', (tester) async {
      // This is the SMS-Retriever path: the native side hands us the code and
      // the service assigns it. Six independent TextFields could not do this
      // without fanning the value out by hand, which is what used to make
      // autofill land in one box or none.
      final ctrl = TextEditingController();
      await tester.pumpWidget(_wrap(OtpCodeField(controller: ctrl, autofocus: false)));

      ctrl.text = '481902';
      await tester.pump();

      for (final digit in ['4', '8', '1', '9', '0', '2']) {
        expect(find.text(digit), findsOneWidget);
      }
      expect(find.text('–'), findsNothing);
    });

    testWidgets('fires onCompleted exactly once for a bulk fill', (tester) async {
      final ctrl = TextEditingController();
      final completed = <String>[];
      await tester.pumpWidget(_wrap(OtpCodeField(
        controller: ctrl,
        autofocus: false,
        onCompleted: completed.add,
      )));

      ctrl.text = '123456';
      await tester.pump();
      // A second notification with the same value (a selection change, which
      // the controller also broadcasts) must not re-submit.
      ctrl.selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();

      expect(completed, ['123456']);
    });

    testWidgets('does not fire until the code is complete', (tester) async {
      final ctrl = TextEditingController();
      final completed = <String>[];
      await tester.pumpWidget(_wrap(OtpCodeField(
        controller: ctrl,
        autofocus: false,
        onCompleted: completed.add,
      )));

      ctrl.text = '1234';
      await tester.pump();

      expect(completed, isEmpty);
    });

    testWidgets('re-fires after a correction, so a retry still submits', (tester) async {
      final ctrl = TextEditingController();
      final completed = <String>[];
      await tester.pumpWidget(_wrap(OtpCodeField(
        controller: ctrl,
        autofocus: false,
        onCompleted: completed.add,
      )));

      ctrl.text = '111111';
      await tester.pump();
      ctrl.text = '11111';   // user deletes a digit after a wrong code
      await tester.pump();
      ctrl.text = '222222';
      await tester.pump();

      expect(completed, ['111111', '222222']);
    });

    testWidgets('reports every change through onChanged', (tester) async {
      final ctrl = TextEditingController();
      final seen = <String>[];
      await tester.pumpWidget(_wrap(OtpCodeField(
        controller: ctrl,
        autofocus: false,
        onChanged: seen.add,
      )));

      ctrl.text = '12';
      await tester.pump();

      expect(seen, contains('12'));
    });
  });
}
