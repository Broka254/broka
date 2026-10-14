// BROKA - Protection Badge (Volume 2 §2.1)
// ─────────────────────────────────────────
// A small persistent pill that keeps escrow protection visible throughout
// the negotiation and payment screens, instead of relying on the buyer to
// recall what Zeno said about escrow once, earlier in the chat.
//
// Deliberately takes the raw backend status string (matching DealStatus's
// .value in backend/api/database.py) rather than the DealStatus enum in
// core/network/deal_ws_client.dart. That enum doesn't model every state
// this badge needs (e.g. awaiting_condition_check comes back as `unknown`
// today), and extending it would mean updating the exhaustive switches
// over it in deal_status_widget.dart and deal_status_screen.dart in
// lockstep. This widget owns its own small mapping instead, and is safe
// to pass any status string, known or not - unrecognised values (or null,
// e.g. before a deal exists) just render nothing.
//
// Usage:
//   ProtectionBadge(status: 'paid')
//   ProtectionBadge(status: someDeal?.status)

import 'package:flutter/material.dart';

class ProtectionBadge extends StatelessWidget {
  final String? status;

  /// Compact mode uses smaller padding/text for tight spaces (e.g. inline
  /// next to a payment button rather than its own row).
  final bool compact;

  const ProtectionBadge({super.key, required this.status, this.compact = false});

  static const Map<String, String> _labels = {
    'agreed':                   '🛡 Protected — funds held until you confirm',
    'paid':                     '🛡 Payment secured',
    'awaiting_condition_check': '🛡 Inspection window open',
    'awaiting_resolution':      '🛡 Under BROKA review',
    'awaiting_replacement':     '🛡 Replacement in progress — funds still held',
    'goods_not_arrived':        '🛡 Delivery issue — funds still held',
    'disputed':                 '🛡 Under BROKA review',
    'released':                 '✅ Funds released to seller',
    'refunded':                 '✅ Refunded to buyer',
  };

  static const Map<String, Color> _colors = {
    'agreed':                   Color(0xFF3B82F6),
    'paid':                     Color(0xFFF59E0B),
    'awaiting_condition_check': Color(0xFFF59E0B),
    'awaiting_resolution':      Color(0xFFEF4444),
    'awaiting_replacement':     Color(0xFFEF4444),
    'goods_not_arrived':        Color(0xFFEF4444),
    'disputed':                 Color(0xFFEF4444),
    'released':                 Color(0xFF22C55E),
    'refunded':                 Color(0xFF6366F1),
  };

  @override
  Widget build(BuildContext context) {
    final String? s = status;
    if (s == null || !_labels.containsKey(s)) {
      return const SizedBox.shrink();
    }
    final Color color = _colors[s] ?? const Color(0xFF3B82F6);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 12,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        _labels[s]!,
        style: TextStyle(
          fontSize: compact ? 11 : 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
