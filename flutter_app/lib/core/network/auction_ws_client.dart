// lib/core/network/auction_ws_client.dart
// Mirrors deal_ws_client.dart's exact reconnect contract: 25s JSON pings,
// backoff starting at 1s and doubling up to a 32s cap (Design Journal
// Volume 6, Ch.27). Two details corrected from the source spec's draft
// against the real deal_ws_client.dart: pings are a JSON {"type":"ping"}
// message, not the bare string 'ping', and backoff is computed the same
// way the real file does it (bit-shift + clamp), not a hardcoded array -
// same numbers either way, but this stays correct if _maxBackoff ever
// changes in one place without the other.
//
// The backoff never actually grew: connect() reset the retry count before
// the connection had proved anything, so a server that refused every
// attempt was asked again every second for as long as the auction stayed
// open - a reconnect a second over mobile data. The count is reset only
// once the server has answered on the socket now.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web_socket_channel/web_socket_channel.dart';

class AuctionWsClient {
  final String listingId;
  final String token;
  final void Function(Map<String, dynamic> event) onEvent;

  // Hardcoded here rather than taken as a constructor parameter, matching
  // DealWsClient's actual pattern - a caller passing the wrong base URL
  // (e.g. forgetting the /auction-ws prefix, as this file's first draft
  // did) fails silently at the WebSocket layer, not at compile time.
  static const String _baseWsUrl = String.fromEnvironment(
    'API_WS_URL',
    defaultValue: 'wss://broka-api-development.up.railway.app',
  );

  /// Tests point the client at a local server, and shrink the backoff's
  /// unit so a run of failed attempts takes milliseconds.
  @visibleForTesting
  static String? baseUrlOverride;
  @visibleForTesting
  static Duration backoffUnit = const Duration(seconds: 1);

  static const Duration _pingInterval = Duration(seconds: 25);
  static const int _maxBackoffSteps = 32; // 32 units: 32 seconds

  WebSocketChannel? _channel;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _retryCount = 0;
  bool _closedByUser = false;

  /// Failed attempts since the server last answered.
  @visibleForTesting
  int get retryCount => _retryCount;

  AuctionWsClient({
    required this.listingId,
    required this.token,
    required this.onEvent,
  });

  void connect() {
    _closedByUser = false;
    final base = baseUrlOverride ?? _baseWsUrl;
    final uri = Uri.parse('$base/auction-ws/ws/$listingId?token=$token');
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    // A refused handshake is reported through the stream below; this only
    // keeps it from also surfacing as an unhandled error.
    unawaited(channel.ready.then((_) {}, onError: (Object _) {}));

    channel.stream.listen(
      (message) {
        if (!identical(_channel, channel)) return;
        // The server is talking: whatever went wrong before is over.
        _retryCount = 0;
        final Object? decoded;
        try {
          decoded = jsonDecode(message as String);
        } catch (_) {
          return; // not a frame this client knows - not worth a crash
        }
        if (decoded is Map<String, dynamic>) onEvent(decoded);
      },
      onDone: () => _scheduleReconnect(channel),
      onError: (_) => _scheduleReconnect(channel),
      cancelOnError: true,
    );

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
    });
  }

  void _scheduleReconnect(WebSocketChannel channel) {
    // An error and the close that follows it are one failure, not two.
    if (!identical(_channel, channel)) return;
    _channel = null;
    _pingTimer?.cancel();
    if (_closedByUser) return;
    final steps = 1 << (_retryCount >= 5 ? 5 : _retryCount);
    final delay = backoffUnit * (steps > _maxBackoffSteps ? _maxBackoffSteps : steps);
    _retryCount++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_closedByUser) connect();
    });
  }

  void dispose() {
    _closedByUser = true;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    final channel = _channel;
    _channel = null;
    try {
      channel?.sink.close();
    } catch (_) {}
  }
}
