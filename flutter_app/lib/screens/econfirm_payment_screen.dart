// BROKA - E-Confirm Payment Screen (2026-09)
//
// Provider-neutral payment-waiting screen for marketplace escrow funded
// through E-Confirm API v2 — see api/domains/escrow/router.py's
// /deal/{deal_id}/fund and /deal/{deal_id}/payment-status.
//
// This is a NEW screen rather than a retrofit of mpesa_confirmation_screen.dart
// (Phase 16, option B of the integration spec): that screen is built
// specifically around a Safaricom CheckoutRequestID and /mpesa/query, and
// stays exactly as-is for whatever still calls it. This screen polls
// BROKA's backend only — never E-Confirm directly (Phase 16) — and never
// receives or displays a confirmation_code (Phase 2/23: that value never
// leaves the backend at all).
//
// Reads its arguments the same way mpesa_confirmation_screen.dart does
// (ModalRoute settings.arguments, not constructor params) so the call
// site in negotiation_screen.dart is a small, focused diff — swap the
// route name and the arguments map's keys — rather than a rewrite.
//
// Navigate to:
//   Navigator.pushNamed(context, '/escrow-payment', arguments: {
//     'deal_id': dealId, 'amount': totalToPay, 'phone': payerPhone,
//     'listing_name': listingName,
//   });

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../widgets/protection_badge.dart';

class EConfirmPaymentScreen extends StatefulWidget {
  const EConfirmPaymentScreen({super.key});

  @override
  State<EConfirmPaymentScreen> createState() => _EConfirmPaymentScreenState();
}

enum _Phase { waiting, secured, timedOut, requiresAttention }

class _EConfirmPaymentScreenState extends State<EConfirmPaymentScreen>
    with SingleTickerProviderStateMixin {
  static const _maxWaitSeconds = 180; // matches backend's ECONFIRM_MAX_POLL_SECONDS default
  static const _pollEvery = Duration(seconds: 4);

  Timer? _pollTimer;
  Timer? _countdownTimer;
  late final AnimationController _pulse;

  bool _argsLoaded = false;
  String _dealId = '';
  double _amount = 0.0;
  String _phone = '';
  String _listingName = '';

  _Phase _phase = _Phase.waiting;
  String _paymentStatus = 'preparing_payment';
  String _dealStatus = 'agreed';
  int _secondsLeft = _maxWaitSeconds;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat(reverse: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsLoaded) return;
    _argsLoaded = true;
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _dealId = (args?['deal_id'] as String?) ?? '';
    _amount = (args?['amount'] as num?)?.toDouble() ?? 0.0;
    _phone = (args?['phone'] as String?) ?? '';
    _listingName = (args?['listing_name'] as String?) ?? 'this item';
    _startPolling();
  }

  void _startPolling() {
    _countdownTimer?.cancel();
    _pollTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsLeft = (_secondsLeft - 1).clamp(0, _maxWaitSeconds));
      if (_secondsLeft == 0 && _phase == _Phase.waiting) {
        setState(() => _phase = _Phase.timedOut);
        _pollTimer?.cancel();
      }
    });
    Future.delayed(const Duration(seconds: 3), _poll);
    _pollTimer = Timer.periodic(_pollEvery, (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    if (!mounted || _phase != _Phase.waiting || _dealId.isEmpty) return;
    try {
      final status = await ApiService.getDealPaymentStatus(_dealId);
      if (!mounted) return;
      final paymentStatus = (status['payment_status'] as String?) ?? _paymentStatus;
      final dealStatus = (status['deal_status'] as String?) ?? _dealStatus;
      setState(() {
        _paymentStatus = paymentStatus;
        _dealStatus = dealStatus;
        _error = null;
      });
      if (paymentStatus == 'secured_in_escrow' || paymentStatus == 'released') {
        _pollTimer?.cancel();
        _countdownTimer?.cancel();
        await _onSecured();
      } else if (paymentStatus == 'requires_attention') {
        _pollTimer?.cancel();
        _countdownTimer?.cancel();
        if (mounted) setState(() => _phase = _Phase.requiresAttention);
      }
    } catch (e) {
      // A single failed poll isn't fatal — the countdown/timeout above is
      // what decides when to give up, same pattern
      // mpesa_confirmation_screen.dart already uses. Transient network
      // blips shouldn't flip the whole screen to an error state.
      if (mounted) setState(() => _error = 'Having trouble checking status — retrying…');
    }
  }

  Future<void> _onSecured() async {
    await _saveReceiptLocally();
    if (!mounted) return;
    setState(() => _phase = _Phase.secured);
    HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _saveReceiptLocally() async {
    // Deliberately the SAME 'mpesa_receipts' key/format
    // mpesa_confirmation_screen.dart already uses (dealId|reference|
    // isoTimestamp|listingName|amount) — deal_receipt_history_screen.dart
    // reads this key already and needs no changes to also show
    // E-Confirm-funded deals in the user's payment history. The
    // "reference" slot holds a payment reference for the user's own
    // records, not a secret — it is never the confirmation_code.
    try {
      final prefs = await SharedPreferences.getInstance();
      final receipts = prefs.getStringList('mpesa_receipts') ?? [];
      final amtStr = _amount.toStringAsFixed(0);
      final shortId = _dealId.length >= 8 ? _dealId.substring(0, 8).toUpperCase() : _dealId.toUpperCase();
      receipts.add(
        '$_dealId|ESCROW-$shortId|${DateTime.now().toIso8601String()}|$_listingName|$amtStr',
      );
      await prefs.setStringList('mpesa_receipts', receipts);
    } catch (_) {
      // Non-critical — losing the local history entry shouldn't block
      // the user from proceeding.
    }
  }

  void _retry() {
    setState(() {
      _phase = _Phase.waiting;
      _secondsLeft = _maxWaitSeconds;
      _error = null;
    });
    _startPolling();
  }

  String get _statusLine {
    switch (_paymentStatus) {
      case 'preparing_payment':
        return 'Preparing payment…';
      case 'stk_prompt_sent':
        return _secondsLeft > _maxWaitSeconds - 15
            ? 'STK prompt sent — check your phone'
            : 'Waiting for M-Pesa confirmation…';
      case 'secured_in_escrow':
      case 'released':
        return 'Payment secured in escrow';
      case 'requires_attention':
        return 'Payment requires attention';
      default:
        return 'Checking payment status…';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Complete Payment')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const SizedBox(height: 12),
              _buildStatusCard(),
              const SizedBox(height: 20),
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_listingName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 8),
                      _row('Amount', 'KES ${_amount.toStringAsFixed(0)}'),
                      _row('Phone', _maskedPhone(_phone)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ProtectionBadge(status: _dealStatus),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Colors.orange[800], fontSize: 12)),
              ],
              const Spacer(),
              if (_phase == _Phase.timedOut || _phase == _Phase.requiresAttention)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _retry,
                    child: const Text('Check again'),
                  ),
                ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final Color color = switch (_phase) {
      _Phase.secured => Colors.green[700]!,
      _Phase.timedOut => Colors.orange[800]!,
      _Phase.requiresAttention => Colors.orange[800]!,
      _Phase.waiting => const Color(0xFF00B300),
    };
    final IconData icon = switch (_phase) {
      _Phase.secured => Icons.verified_user,
      _Phase.timedOut => Icons.timer_off_outlined,
      _Phase.requiresAttention => Icons.error_outline,
      _Phase.waiting => Icons.lock_clock,
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [color.withOpacity(0.10), color.withOpacity(0.02)]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        children: [
          if (_phase == _Phase.waiting)
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Opacity(
                opacity: 0.5 + (_pulse.value * 0.5),
                child: Icon(icon, size: 52, color: color),
              ),
            )
          else
            Icon(icon, size: 52, color: color),
          const SizedBox(height: 14),
          Text(
            _phase == _Phase.timedOut
                ? 'Payment timed out'
                : _phase == _Phase.requiresAttention
                    ? 'Payment requires attention'
                    : _statusLine,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
            textAlign: TextAlign.center,
          ),
          if (_phase == _Phase.waiting) ...[
            const SizedBox(height: 8),
            Text('$_secondsLeft seconds left',
                style: TextStyle(color: color.withOpacity(0.7), fontSize: 13)),
          ],
          if (_phase == _Phase.timedOut) ...[
            const SizedBox(height: 8),
            Text(
              "We didn't hear back from M-Pesa in time. If you approved the "
              'prompt, your payment may still go through — check again in a moment.',
              style: TextStyle(color: color.withOpacity(0.8), fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
          if (_phase == _Phase.requiresAttention) ...[
            const SizedBox(height: 8),
            Text(
              "There's an issue completing this payout. Your delivery "
              'confirmation was recorded and the deal remains protected — '
              'please try again shortly or contact support.',
              style: TextStyle(color: color.withOpacity(0.8), fontSize: 13),
              textAlign: TextAlign.center,
            ),
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
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  String _maskedPhone(String phone) {
    if (phone.length < 6) return phone;
    return '${phone.substring(0, phone.length - 6)}****${phone.substring(phone.length - 2)}';
  }
}
