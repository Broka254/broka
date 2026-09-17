// BROKA v3.0 - Deal Status Screen
// Full screen view of a deal with live WebSocket status, escrow timeline,
// action buttons (confirm delivery / open dispute), and deal details.
//
// Navigate to:
//   Navigator.push(context, MaterialPageRoute(
//     builder: (_) => DealStatusScreen(
//       dealId: deal['id'],
//       token:  authToken,
//       role:   'buyer', // or 'seller'
//       dealData: deal,
//     ),
//   ));

import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/network/deal_ws_client.dart';
import '../../../core/utils/result.dart';
import '../../escrow/data/repositories/escrow_repository.dart';

class DealStatusScreen extends StatefulWidget {
  final String dealId;
  final String token;
  final String role;               // 'buyer' | 'seller'
  final Map<String, dynamic>? dealData;

  const DealStatusScreen({
    super.key,
    required this.dealId,
    required this.token,
    required this.role,
    this.dealData,
  });

  @override
  State<DealStatusScreen> createState() => _DealStatusScreenState();
}

class _DealStatusScreenState extends State<DealStatusScreen> {
  late DealWsClient _wsClient;
  StreamSubscription<DealStatusUpdate>? _updateSub;

  DealStatus  _status      = DealStatus.agreed;
  String?     _detail;
  bool        _isActing    = false;
  String?     _actionError;

  late Map<String, dynamic> _deal;

  @override
  void initState() {
    super.initState();
    _deal = widget.dealData ?? {};
    if (_deal['status'] != null) {
      _status = DealStatus.fromString(_deal['status'] as String);
    }

    _wsClient = dealWsManager.subscribe(widget.dealId, widget.token);
    _updateSub = _wsClient.updateStream.listen((upd) {
      if (mounted) {
        setState(() {
          _status = upd.status;
          _detail = upd.detail;
        });
        if (upd.status == DealStatus.released) {
          _showSnack('✅ Funds released to seller!', isSuccess: true);
        } else if (upd.status == DealStatus.disputed) {
          _showSnack('⚖️ Dispute opened — funds frozen');
        } else if (upd.status == DealStatus.refunded) {
          _showSnack('↩ Refund processed');
        }
      }
    });
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    dealWsManager.unsubscribe(widget.dealId);
    super.dispose();
  }

  void _showSnack(String msg, {bool isSuccess = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isSuccess ? Colors.green[700] : null,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _confirmDelivery() async {
    setState(() { _isActing = true; _actionError = null; });
    final result = await escrowRepository.confirmDelivery(widget.dealId);
    result.fold(
      onSuccess: (_) => _showSnack('Delivery confirmed! Funds released.', isSuccess: true),
      onFailure: (msg, _) => setState(() => _actionError = msg),
    );
    if (mounted) setState(() => _isActing = false);
  }

  Future<void> _openDispute() async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open Dispute'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Describe the problem. Funds will be frozen until resolved.'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'What went wrong?',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open Dispute'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() { _isActing = true; _actionError = null; });
    // POST /disputes/open
    // Inline call to the disputes endpoint
    final repo = EscrowRepository();
    final result = await repo.getDeal(widget.dealId);
    // Use disputesRepository (if wired) or raw call
    // Here we navigate user to dispute screen with pre-filled data
    if (mounted) {
      Navigator.pushNamed(context, '/dispute', arguments: {
        'deal_id':     widget.dealId,
        'description': reasonCtrl.text,
      });
    }
    if (mounted) setState(() => _isActing = false);
  }

  @override
  Widget build(BuildContext context) {
    final isBuyer  = widget.role == 'buyer';
    final price    = (_deal['agreed_price'] as num?)?.toDouble() ?? 0.0;
    final comm     = (_deal['commission'] as num?)?.toDouble() ?? 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Deal Status'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Request refresh',
            onPressed: _wsClient.requestRefresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Live status card ───────────────────────────────────────────────
          _StatusCard(status: _status, wsClient: _wsClient, detail: _detail),
          const SizedBox(height: 16),

          // ── Deal details ───────────────────────────────────────────────────
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Deal Details',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 12),
                  _row('Agreed Price', 'KES ${_fmtKes(price)}'),
                  _row('Broka Fee (3%)', 'KES ${_fmtKes(comm)}'),
                  _row('Total Paid',     'KES ${_fmtKes(price + comm)}'),
                  _row('Deal ID', widget.dealId.substring(0, 8).toUpperCase()),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Action buttons (buyer only, only when escrow is paid) ──────────
          if (isBuyer && _status == DealStatus.paid) ...[
            if (_actionError != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_actionError!, style: const TextStyle(color: Colors.red)),
              ),
              const SizedBox(height: 8),
            ],
            ElevatedButton.icon(
              onPressed: _isActing ? null : _confirmDelivery,
              icon: _isActing
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle),
              label: const Text('Confirm Delivery & Release Funds'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Colors.green[700],
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _isActing ? null : _openDispute,
              icon: const Icon(Icons.gavel, color: Colors.red),
              label: const Text('Open Dispute', style: TextStyle(color: Colors.red)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                side: const BorderSide(color: Colors.red),
              ),
            ),
          ],

          // ── Terminal state message ─────────────────────────────────────────
          if (_status.isTerminal) ...[
            const SizedBox(height: 12),
            _TerminalCard(status: _status),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey[600])),
          Text(value,  style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  String _fmtKes(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(0)}K';
    return v.toStringAsFixed(0);
  }
}

// ── Sub-widgets ────────────────────────────────────────────────────────────────

class _StatusCard extends StatefulWidget {
  final DealStatus status;
  final DealWsClient wsClient;
  final String? detail;
  const _StatusCard({required this.status, required this.wsClient, this.detail});

  @override
  State<_StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<_StatusCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  StreamSubscription<DealWsState>? _sub;
  WsConnectionState _conn = WsConnectionState.connecting;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat(reverse: true);
    _sub = widget.wsClient.stateStream.listen((s) {
      if (mounted) setState(() => _conn = s.connection);
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(widget.status);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.08), color.withOpacity(0.02)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Icon(_icon(widget.status), size: 48, color: color),
          const SizedBox(height: 10),
          Text(
            widget.status.displayLabel,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color),
            textAlign: TextAlign.center,
          ),
          if (widget.detail != null) ...[
            const SizedBox(height: 6),
            Text(widget.detail!, style: TextStyle(color: color.withOpacity(0.7), fontSize: 13)),
          ],
          const SizedBox(height: 12),
          // Connection indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) => Opacity(
                  opacity: _conn == WsConnectionState.connected ? _pulse.value : 0.3,
                  child: Container(
                    width: 7, height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _conn == WsConnectionState.connected ? Colors.green : Colors.orange,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _conn == WsConnectionState.connected
                    ? 'Live updates active'
                    : _conn == WsConnectionState.reconnecting
                        ? 'Reconnecting…'
                        : 'Offline',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Color _color(DealStatus s) => switch (s) {
    DealStatus.agreed          => const Color(0xFF3B82F6),
    DealStatus.paid            => const Color(0xFFF59E0B),
    DealStatus.released        => const Color(0xFF22C55E),
    DealStatus.refunded        => const Color(0xFF6366F1),
    DealStatus.disputed        => const Color(0xFFEF4444),
    DealStatus.disputeResolved => const Color(0xFF8B5CF6),
    DealStatus.unknown         => Colors.grey,
  };

  static IconData _icon(DealStatus s) => switch (s) {
    DealStatus.agreed          => Icons.handshake_outlined,
    DealStatus.paid            => Icons.lock_outlined,
    DealStatus.released        => Icons.check_circle_outline,
    DealStatus.refunded        => Icons.undo,
    DealStatus.disputed        => Icons.gavel_outlined,
    DealStatus.disputeResolved => Icons.balance_outlined,
    DealStatus.unknown         => Icons.help_outline,
  };
}

class _TerminalCard extends StatelessWidget {
  final DealStatus status;
  const _TerminalCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final isReleased = status == DealStatus.released;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: (isReleased ? Colors.green : Colors.indigo).withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            isReleased ? Icons.emoji_events : Icons.undo,
            color: isReleased ? Colors.green[700] : Colors.indigo[700],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isReleased
                  ? 'This deal is complete. You can leave a review for the seller.'
                  : 'Refund has been processed. Funds will be returned to you.',
              style: TextStyle(
                color: isReleased ? Colors.green[700] : Colors.indigo[700],
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
