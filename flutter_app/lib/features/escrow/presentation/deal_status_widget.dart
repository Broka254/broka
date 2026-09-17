// BROKA v3.0 - Real-time Deal Status Widget
// Drop this into any screen that shows a deal.
// It connects to the WebSocket hub and animates through status changes.
//
// Usage:
//   DealStatusWidget(dealId: deal.id, token: authToken)

import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/network/deal_ws_client.dart';
import '../../../widgets/protection_badge.dart';

class DealStatusWidget extends StatefulWidget {
  final String dealId;
  final String token;
  final String? initialStatus;
  final VoidCallback? onReleased;
  final VoidCallback? onDisputed;
  final VoidCallback? onRefunded;

  const DealStatusWidget({
    super.key,
    required this.dealId,
    required this.token,
    this.initialStatus,
    this.onReleased,
    this.onDisputed,
    this.onRefunded,
  });

  @override
  State<DealStatusWidget> createState() => _DealStatusWidgetState();
}

class _DealStatusWidgetState extends State<DealStatusWidget>
    with SingleTickerProviderStateMixin {
  late DealWsClient _client;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  StreamSubscription<DealWsState>?  _stateSub;
  StreamSubscription<DealStatusUpdate>? _updateSub;

  WsConnectionState _connState = WsConnectionState.connecting;
  DealStatus _status = DealStatus.unknown;
  String?    _detail;

  // ProtectionBadge (Volume 2 §2.1) takes the raw backend status string
  // rather than this widget's own DealStatus enum - see protection_badge.dart
  // for why. disputeResolved deliberately maps to null: this enum alone
  // can't tell us whether that resolved as a release or a refund, and
  // guessing wrong is worse than showing nothing.
  String? get _statusApiString => switch (_status) {
    DealStatus.agreed          => 'agreed',
    DealStatus.paid            => 'paid',
    DealStatus.released        => 'released',
    DealStatus.refunded        => 'refunded',
    DealStatus.disputed        => 'disputed',
    DealStatus.disputeResolved => null,
    DealStatus.unknown         => null,
  };

  @override
  void initState() {
    super.initState();

    // Parse initial status passed in from HTTP response
    if (widget.initialStatus != null) {
      _status = DealStatus.fromString(widget.initialStatus!);
    }

    // Pulse animation for "live" indicator dot
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(_pulseController);

    // Connect WebSocket
    _client = dealWsManager.subscribe(widget.dealId, widget.token);

    _stateSub = _client.stateStream.listen((state) {
      if (mounted) setState(() => _connState = state.connection);
    });

    _updateSub = _client.updateStream.listen(_onStatusUpdate);
  }

  void _onStatusUpdate(DealStatusUpdate update) {
    if (!mounted) return;
    setState(() {
      _status = update.status;
      _detail = update.detail;
    });

    // Trigger callbacks
    if (update.status == DealStatus.released) widget.onReleased?.call();
    if (update.status == DealStatus.disputed) widget.onDisputed?.call();
    if (update.status == DealStatus.refunded) widget.onRefunded?.call();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _updateSub?.cancel();
    dealWsManager.unsubscribe(widget.dealId);
    _pulseController.dispose();
    super.dispose();
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 12),
            _buildStatusRow(),
            if (_statusApiString != null) ...[
              const SizedBox(height: 8),
              ProtectionBadge(status: _statusApiString),
            ],
            if (_detail != null) ...[
              const SizedBox(height: 8),
              Text(
                _detail!,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
            const SizedBox(height: 12),
            _buildProgressBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final isConnected = _connState == WsConnectionState.connected;
    final isReconnecting = _connState == WsConnectionState.reconnecting;

    return Row(
      children: [
        const Text(
          'Deal Status',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const Spacer(),
        AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, __) => Opacity(
            opacity: isConnected ? _pulseAnim.value : 0.3,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isConnected
                    ? Colors.green
                    : isReconnecting
                        ? Colors.orange
                        : Colors.grey,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          isConnected
              ? 'Live'
              : isReconnecting
                  ? 'Reconnecting…'
                  : 'Offline',
          style: TextStyle(
            fontSize: 11,
            color: isConnected
                ? Colors.green
                : isReconnecting
                    ? Colors.orange
                    : Colors.grey,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusRow() {
    return Row(
      children: [
        Icon(_statusIcon(_status), color: _statusColor(_status), size: 24),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _status.displayLabel,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: _statusColor(_status),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBar() {
    const steps = [
      DealStatus.agreed,
      DealStatus.paid,
      DealStatus.released,
    ];
    final idx = steps.indexOf(_status);
    final progress = idx >= 0 ? (idx + 1) / steps.length : 0.0;

    if (_status == DealStatus.refunded || _status == DealStatus.disputed) {
      return _buildAltStatus();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _stepLabel('Agreed',  idx >= 0),
            _stepLabel('In Escrow', idx >= 1),
            _stepLabel('Released', idx >= 2),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.grey[200],
            valueColor: AlwaysStoppedAnimation(_statusColor(_status)),
            minHeight: 6,
          ),
        ),
      ],
    );
  }

  Widget _buildAltStatus() {
    final isRefund  = _status == DealStatus.refunded;
    final isDispute = _status == DealStatus.disputed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (isDispute ? Colors.orange : Colors.blue).withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isDispute ? '⚖️  In dispute — awaiting resolution' : '↩  Buyer refunded',
        style: TextStyle(
          fontSize: 13,
          color: isDispute ? Colors.orange[700] : Colors.blue[700],
        ),
      ),
    );
  }

  Widget _stepLabel(String label, bool active) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        color: active ? Colors.black87 : Colors.grey[400],
        fontWeight: active ? FontWeight.w600 : FontWeight.normal,
      ),
    );
  }

  static Color _statusColor(DealStatus s) => switch (s) {
    DealStatus.agreed          => const Color(0xFF3B82F6),
    DealStatus.paid            => const Color(0xFFF59E0B),
    DealStatus.released        => const Color(0xFF22C55E),
    DealStatus.refunded        => const Color(0xFF6366F1),
    DealStatus.disputed        => const Color(0xFFEF4444),
    DealStatus.disputeResolved => const Color(0xFF8B5CF6),
    DealStatus.unknown         => Colors.grey,
  };

  static IconData _statusIcon(DealStatus s) => switch (s) {
    DealStatus.agreed          => Icons.handshake_outlined,
    DealStatus.paid            => Icons.lock_outlined,
    DealStatus.released        => Icons.check_circle_outline,
    DealStatus.refunded        => Icons.undo,
    DealStatus.disputed        => Icons.gavel_outlined,
    DealStatus.disputeResolved => Icons.balance_outlined,
    DealStatus.unknown         => Icons.help_outline,
  };
}
