// What the user is told when something fails.
//
// Screens used to show `e.toString()` - so a phone with no signal put
// "ClientException with SocketFailed host lookup: 'api.broka.co.ke' (OS
// Error: No address associated with hostname, errno = 7),
// uri=https://api.broka.co.ke/auth/login" on the login screen: the API's
// address, the route and the OS's internals, none of which the user can
// act on and all of which tell a stranger looking over their shoulder
// how the app is built. Everything an error shows goes through here.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../network/api_client.dart';

const String kOfflineMessage =
    "Can't reach BROKA right now. Check your internet connection and try again.";
const String kTimeoutMessage =
    'BROKA is taking too long to respond. Check your connection and try again.';
const String kGenericErrorMessage = 'Something went wrong. Please try again.';

/// A message for [error] that is safe to put on screen.
///
/// Network failures become one plain sentence. A message the server wrote
/// for people (an [ApiException], or `Exception(detail)`) is kept, unless
/// it carries something technical - an address, an OS error, a type name
/// - in which case [fallback] is shown instead.
String userFacingError(Object? error, {String fallback = kGenericErrorMessage}) {
  if (error == null) return fallback;
  if (error is SocketException ||
      error is http.ClientException ||
      error is HandshakeException ||
      error is TlsException ||
      error is HttpException) {
    return kOfflineMessage;
  }
  if (error is TimeoutException) return kTimeoutMessage;
  if (error is ApiException) {
    // A 5xx body is the server's own trouble ("Internal Server Error"),
    // not something written for the user.
    if (error.statusCode >= 500) return fallback;
    return sanitizeErrorText(error.message, fallback: fallback);
  }
  if (error is FormatException || error is TypeError || error is Error) {
    return fallback;
  }
  return sanitizeErrorText(error.toString(), fallback: fallback);
}

// Signs that a message was written for a developer, not a person. Any one
// of them and the whole message is replaced: half a stack trace is still
// a stack trace.
final List<RegExp> _technical = [
  RegExp(r'[a-z][a-z0-9+.-]*://', caseSensitive: false), // any URL
  RegExp(r'\b(api\.)?broka\.co\.ke\b', caseSensitive: false),
  RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'), // an IP address
  RegExp(r'\berrno\b|OS Error|SocketFailed|host lookup|Connection (refused|reset|closed)',
      caseSensitive: false),
  RegExp(r'\b\w*(Exception|Error)\b\s*[:(]'), // "ClientException:", "TypeError("
  RegExp(r'\bInstance of\b|\bNull check\b|is not a subtype', caseSensitive: false),
  RegExp(r'#\d+\s+\S+\s+\(|\.dart:\d+'), // stack frames
  RegExp(r'Traceback|sqlalchemy|asyncpg|psycopg', caseSensitive: false),
  RegExp(r'<(!doctype|html)', caseSensitive: false),
];

/// [text] with the "Exception: " Dart puts in front removed, or
/// [fallback] when the text is empty or technical.
String sanitizeErrorText(String? text, {String fallback = kGenericErrorMessage}) {
  if (text == null) return fallback;
  var s = text.trim();
  while (s.startsWith('Exception: ')) {
    s = s.substring('Exception: '.length).trim();
  }
  if (s.isEmpty || s == 'null') return fallback;
  if (_isNetworkText(s)) return kOfflineMessage;
  if (s.length > 240) return fallback;
  for (final pattern in _technical) {
    if (pattern.hasMatch(s)) return fallback;
  }
  return s;
}

bool _isNetworkText(String s) {
  final lower = s.toLowerCase();
  return lower.contains('socketexception') ||
      lower.contains('clientexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('network is unreachable') ||
      lower.contains('handshakeexception');
}
