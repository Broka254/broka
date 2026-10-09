// What a failure shows on screen (2026-10-09). The login screen showed
// "ClientException with SocketFailed host lookup: 'api.broka.co.ke' (OS
// Error: No address associated with hostname, errno = 7),
// uri=https://api.broka.co.ke/auth/login" to a phone with no signal: the
// API's address, the route and the OS's internals.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:broka/core/errors/user_facing_error.dart';
import 'package:broka/core/network/api_client.dart';
import 'package:broka/widgets/wizard_scaffold.dart';
import 'package:flutter/material.dart';

const _leak = "ClientException with SocketFailed host lookup: 'api.broka.co.ke' "
    '(OS Error: No address associated with hostname, errno = 7), '
    'uri=https://api.broka.co.ke/auth/login';

void main() {
  test('the login failure from the report says only that BROKA is unreachable', () {
    final shown = userFacingError(http.ClientException(
        "SocketFailed host lookup: 'api.broka.co.ke' (OS Error: No address "
        'associated with hostname, errno = 7)',
        Uri.parse('https://api.broka.co.ke/auth/login')));
    expect(shown, kOfflineMessage);
    expect(sanitizeErrorText(_leak), kOfflineMessage);
    expect(sanitizeErrorText('Exception: $_leak'), kOfflineMessage);
  });

  test('network and timeout failures are plain sentences', () {
    expect(userFacingError(const SocketException('Connection refused')), kOfflineMessage);
    expect(userFacingError(TimeoutException('x')), kTimeoutMessage);
  });

  test("the server's own words for people are kept", () {
    expect(userFacingError(Exception('Incorrect phone number or password')),
        'Incorrect phone number or password');
    expect(userFacingError(const ApiException(400, 'That code has expired')),
        'That code has expired');
  });

  test("a message for people inside a caller's own words is kept", () {
    expect(sanitizeErrorText('Could not start call: Exception: BROKA needs microphone access.'),
        'Could not start call: BROKA needs microphone access.');
  });

  test('anything technical is replaced', () {
    expect(userFacingError(const ApiException(500, 'Internal Server Error')), kGenericErrorMessage);
    expect(sanitizeErrorText('Failed to load https://api.broka.co.ke/x'), kGenericErrorMessage);
    expect(sanitizeErrorText("type 'Null' is not a subtype of type 'String'"), kGenericErrorMessage);
    expect(sanitizeErrorText('FormatException: Unexpected character'), kGenericErrorMessage);
    expect(sanitizeErrorText('connect to 10.0.2.2 failed'), kGenericErrorMessage);
    expect(userFacingError(StateError('Bad state')), kGenericErrorMessage);
  });

  testWidgets('the error banner never shows the raw text', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: WizardErrorBanner(_leak))));
    expect(find.textContaining('api.broka.co.ke'), findsNothing);
    expect(find.text(kOfflineMessage), findsOneWidget);
  });
}
