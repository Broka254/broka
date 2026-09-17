// BROKA v3.0 - Deal Status WebSocket Client
// ─────────────────────────────────────────
// Connects to /deal-ws/ws/<deal_id>?token=<jwt>
// Exposes a Stream<DealStatusUpdate> per deal.
// Auto-reconnects with exponential backoff (1s → 2s → 4s → 8s → 16s, cap 32s).
// Sends a ping every 25s to keep the connection alive through proxies.

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Domain object ─────────────────────────────────────────────────────────────

enum DealStatus {
  agreed,
  paid,
  released,
  refunded,
  disputed,
  disputeResolved,
  unknown;

  static DealStatus fromString(String s) => switch (s) {
    'agreed'            => agreed,
    'paid'              => paid,
    'released'          => released,
    'refunded'          => refunded,
    'disputed'          => disputed,
    'dispute_resolved'  => disputeResolved,
    _                   => unknown,
  };

  String get displayLabel => switch (this) {
    agreed           => 'Deal Agreed',
    paid             => 'Payment Held in Escrow',
    released         => 'Funds Released to Seller ✓',
    refunded         => 'Refunded to Buyer',
    disputed         => 'Dispute Opened',
    disputeResolved  => 'Dispute Resolved',
    unknown          => 'Unknown',
  };

  bool get isTerminal => this == released || this == refunded;
}

class DealStatusUpdate {
  final String    dealId;
  final DealStatus status;
  final DateTime  timestamp;
  final String?   detail;
  final Map<String, dynamic>? meta;

  const DealStatusUpdate({
    required this.dealId,
    required this.status,
    required this.timestamp,
    this.detail,
    this.meta,
  });

  factory DealStatusUpdate.fromJson(Map<String, dynamic> json) {
    return DealStatusUpdate(
      dealId:    json['deal_id'] as String,
      status:    DealStatus.fromString(json['status'] as String? ?? ''),
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      detail:    json['detail']  as String?,
      meta:      json['meta']    as Map<String, dynamic>?,
    );
  }
}

// ── Connection state ──────────────────────────────────────────────────────────

enum WsConnectionState { connecting, connected, reconnecting, disconnected }

class DealWsState {
  final WsConnectionState connection;
  final DealStatusUpdate? lastUpdate;
  const DealWsState(this.connection, {this.lastUpdate});
}

// ── Client ────────────────────────────────────────────────────────────────────

class DealWsClient {
  static const String _baseWsUrl = String.fromEnvironment(
    'API_WS_URL',
    defaultValue: 'wss://broka-dbjd.onrender.com',
  );

  static const Duration _pingInterval   = Duration(seconds: 25);
  static const Duration _maxBackoff     = Duration(seconds: 32);
  static const int      _maxRetries     = 10;

  final String dealId;
  final String token;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  int  _retryCount = 0;
  bool _disposed   = false;

  // State stream
  final _stateController = StreamController<DealWsState>.broadcast();
  Stream<DealWsState> get stateStream => _stateController.stream;

  // Update stream (filtered: only actual status changes)
  final _updateController = StreamController<DealStatusUpdate>.broadcast();
  Stream<DealStatusUpdate> get updateStream => _updateController.stream;

  WsConnectionState _connState = WsConnectionState.disconnected;
  DealStatusUpdate? _lastUpdate;

  DealWsClient({required this.dealId, required this.token});

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  void connect() {
    if (_disposed) return;
    _emit(WsConnectionState.connecting);
    _doConnect();
  }

  void _doConnect() {
    if (_disposed) return;
    final uri = Uri.parse('$_baseWsUrl/deal-ws/ws/$dealId?token=$token');
    _channel = WebSocketChannel.connect(uri);
    _emit(WsConnectionState.connected);
    _retryCount = 0;
    _startPing();

    _sub = _channel!.stream.listen(
      _onMessage,
      onError: _onError,
      onDone:  _onDone,
      cancelOnError: false,
    );
  }

  void disconnect() {
    _disposed = true;
    _cleanup();
    _emit(WsConnectionState.disconnected);
    _stateController.close();
    _updateController.close();
  }

  // ── Ping ────────────────────────────────────────────────────────────────────

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
    });
  }

  // ── Message handling ─────────────────────────────────────────────────────────

  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'pong') return; // keepalive ack — ignore

      if (type == 'deal_status') {
        final update = DealStatusUpdate.fromJson(json);
        _lastUpdate = update;
        if (!_updateController.isClosed) {
          _updateController.add(update);
        }
        _emit(_connState, lastUpdate: update);
      }
    } catch (e) {
      // Malformed frame — ignore
    }
  }

  void _onError(Object error) {
    _scheduleReconnect();
  }

  void _onDone() {
    if (!_disposed) _scheduleReconnect();
  }

  // ── Reconnection ─────────────────────────────────────────────────────────────

  void _scheduleReconnect() {
    if (_disposed || _retryCount >= _maxRetries) {
      _emit(WsConnectionState.disconnected);
      return;
    }
    _cleanup(keepState: true);
    _emit(WsConnectionState.reconnecting);

    final delay = Duration(
      seconds: (1 << _retryCount).clamp(1, _maxBackoff.inSeconds),
    );
    _retryCount++;

    _reconnectTimer = Timer(delay, () {
      if (!_disposed) _doConnect();
    });
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  void _cleanup({bool keepState = false}) {
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _sub     = null;
    _pingTimer = null;
  }

  void _emit(WsConnectionState state, {DealStatusUpdate? lastUpdate}) {
    _connState = state;
    if (!_stateController.isClosed) {
      _stateController.add(DealWsState(state, lastUpdate: lastUpdate ?? _lastUpdate));
    }
  }

  /// Request a status refresh from server (server re-queries DB and pushes)
  void requestRefresh() {
    try {
      _channel?.sink.add(jsonEncode({'type': 'refresh'}));
    } catch (_) {}
  }

  DealStatusUpdate? get lastUpdate => _lastUpdate;
  bool get isConnected => _connState == WsConnectionState.connected;
}

// ── Manager: one client per deal, shared across the app ─────────────────────

class DealWsManager {
  final Map<String, DealWsClient> _clients = {};

  /// Subscribe to a deal's status stream.
  /// Returns the client — call [unsubscribe] when the screen disposes.
  DealWsClient subscribe(String dealId, String token) {
    if (_clients.containsKey(dealId)) {
      return _clients[dealId]!;
    }
    final client = DealWsClient(dealId: dealId, token: token);
    _clients[dealId] = client;
    client.connect();
    return client;
  }

  /// Unsubscribe from a deal's stream (call from screen's dispose()).
  void unsubscribe(String dealId) {
    _clients[dealId]?.disconnect();
    _clients.remove(dealId);
  }

  void disposeAll() {
    for (final c in _clients.values) {
      c.disconnect();
    }
    _clients.clear();
  }
}

// Singleton
final dealWsManager = DealWsManager();
