// lib/core/network/auction_ws_client.dart
// Mirrors deal_ws_client.dart's exact reconnect contract: 25s JSON pings,
// backoff starting at 1s and doubling up to a 32s cap (Design Journal
// Volume 6, Ch.27). Two details corrected from the source spec's draft
// against the real deal_ws_client.dart: pings are a JSON {"type":"ping"}
// message, not the bare string 'ping', and backoff is computed the same
// way the real file does it (bit-shift + clamp), not a hardcoded array -
// same numbers either way, but this stays correct if _maxBackoff ever
// changes in one place without the other.
import 'dart:async';
import 'dart:convert';
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
    defaultValue: 'wss://broka-dbjd.onrender.com',
  );

  static const Duration _pingInterval = Duration(seconds: 25);
  static const Duration _maxBackoff = Duration(seconds: 32);

  WebSocketChannel? _channel;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _retryCount = 0;
  bool _closedByUser = false;

  AuctionWsClient({
    required this.listingId,
    required this.token,
    required this.onEvent,
  });

  void connect() {
    _closedByUser = false;
    final uri = Uri.parse('$_baseWsUrl/auction-ws/ws/$listingId?token=$token');
    _channel = WebSocketChannel.connect(uri);
    _retryCount = 0;

    _channel!.stream.listen(
      (message) => onEvent(jsonDecode(message as String) as Map<String, dynamic>),
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
    );

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      _channel?.sink.add(jsonEncode({'type': 'ping'}));
    });
  }

  void _scheduleReconnect() {
    _pingTimer?.cancel();
    if (_closedByUser) return;
    final delay = Duration(seconds: (1 << _retryCount).clamp(1, _maxBackoff.inSeconds));
    _retryCount++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, connect);
  }

  void dispose() {
    _closedByUser = true;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
  }
}
