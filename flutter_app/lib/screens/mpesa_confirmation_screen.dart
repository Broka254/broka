// BROKA - M-Pesa STK Push Confirmation Screen
// Real-time polling: pending → success | failed | timeout
// Receipt number stored in SharedPreferences on success.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../widgets/protection_badge.dart';

enum _PayStatus { pending, success, failed, timeout }

class MpesaConfirmationScreen extends StatefulWidget {
  const MpesaConfirmationScreen({super.key});
  @override
  State<MpesaConfirmationScreen> createState() => _MpesaConfirmationScreenState();
}

class _MpesaConfirmationScreenState extends State<MpesaConfirmationScreen>
    with TickerProviderStateMixin {

  // ── Args (filled in initState) ────────────────────────────────────────────
  String _checkoutRequestId = '';
  String _dealId            = '';
  double _amount            = 0.0;
  String _phone             = '';
  String _listingName       = '';

  // ── State ─────────────────────────────────────────────────────────────────
  _PayStatus _status    = _PayStatus.pending;
  String?    _receipt;
  String?    _errorMsg;
  int        _secondsLeft = 120;
  int        _pollCount   = 0;

  Timer? _pollTimer;
  Timer? _countdownTimer;

  // Volume 2 §2.3/§2.4 - platform-wide reassurance shown while waiting for
  // M-Pesa confirmation, the moment of maximum payment anxiety. Fetched
  // once; failure here must never disrupt the actual payment flow, so
  // _loadDisputeSummary swallows all errors and just leaves this null
  // (the badge below already renders fine with no stat attached).
  Map<String, dynamic>? _disputeSummary;

  // The ProtectionBadge below used to be hardcoded to 'agreed' - correct
  // for the common case (this screen is reached right after an STK push
  // for a deal still sitting at `agreed`, before M-Pesa confirms), but
  // wrong if the screen is ever revisited with stale state after the
  // underlying deal has actually moved on (paid, disputed, etc.) - an
  // external audit caught this as a real gap between what's shown and
  // what's true. Fetched via the same dealId-keyed escrow-state endpoint
  // getEscrowState already uses elsewhere; 'agreed' remains the fallback
  // if this fetch fails, since it's still the correct default for the
  // normal case this screen exists for.
  String _liveDealStatus = 'agreed';

  late AnimationController _pulseCtrl;
  late AnimationController _successCtrl;
  late Animation<double>   _pulseAnim;
  late Animation<double>   _successAnim;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _successCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _pulseAnim   = Tween<double>(begin: 0.85, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _successAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _successCtrl, curve: Curves.elasticOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    if (args != null && _checkoutRequestId.isEmpty) {
      _checkoutRequestId = args['checkoutRequestId'] as String? ?? '';
      _dealId            = args['dealId']            as String? ?? '';
      _amount            = (args['amount']           as num?)?.toDouble() ?? 0.0;
      _phone             = args['phone']             as String? ?? '';
      _listingName       = args['listingName']       as String? ?? '';
      _startPolling();
      _loadDisputeSummary();
      _loadLiveDealStatus();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    _pulseCtrl.dispose();
    _successCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDisputeSummary() async {
    try {
      final stats = await ApiService.getDisputeSummaryStats();
      if (mounted) setState(() => _disputeSummary = stats);
    } catch (_) {
      // Reassurance copy only - never let this block or error out the
      // actual payment screen. Badge below just renders without a stat.
    }
  }

  Future<void> _loadLiveDealStatus() async {
    if (_dealId.isEmpty) return;
    try {
      final state = await ApiService.getEscrowState(_dealId);
      final status = state['status'] as String?;
      if (mounted && status != null) setState(() => _liveDealStatus = status);
    } catch (_) {
      // Keep the 'agreed' default - still correct for the normal case
      // this screen exists for, and a failed fetch here must never block
      // or error out the actual payment flow.
    }
  }

  // ── Polling logic ─────────────────────────────────────────────────────────

  void _startPolling() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_status != _PayStatus.pending) { _countdownTimer?.cancel(); return; }
      if (mounted) setState(() => _secondsLeft = (_secondsLeft - 1).clamp(0, 120));
      if (_secondsLeft == 0) _onTimeout();
    });

    // First poll after 5s (give Safaricom time to send STK push)
    Future.delayed(const Duration(seconds: 5), _poll);
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_status != _PayStatus.pending) { _pollTimer?.cancel(); return; }
      _poll();
    });
  }

  Future<void> _poll() async {
    if (_status != _PayStatus.pending) return;
    _pollCount++;
    try {
      final result = await ApiService.mpesaQuery(
        checkoutRequestId: _checkoutRequestId,
      );
      _handlePollResult(result);
    } catch (_) {
      // Network error - keep polling silently
    }
  }

  void _handlePollResult(Map<String, dynamic> r) {
    // Safaricom response codes: 0 = success, 1032 = cancelled, others = failed
    final resultCode = r['ResultCode']?.toString()
        ?? r['result_code']?.toString()
        ?? r['status']?.toString();
    final receipt = r['MpesaReceiptNumber'] as String?
        ?? r['mpesa_receipt_number']        as String?
        ?? r['receipt_number']              as String?;

    if (resultCode == '0' || r['status'] == 'success') {
      _onSuccess(receipt ?? 'RCP${DateTime.now().millisecondsSinceEpoch}');
    } else if (resultCode == '1032' || r['status'] == 'cancelled') {
      _onFailed('Payment cancelled. Please try again.');
    } else if (resultCode != null && resultCode != 'pending' &&
               resultCode != 'Pending' && resultCode != 'processing') {
      _onFailed(r['ResultDesc'] as String?
          ?? r['result_desc']   as String?
          ?? 'Payment was not completed.');
    }
    // else still pending - keep polling
  }

  Future<void> _onSuccess(String receipt) async {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    _receipt = receipt;
    if (mounted) setState(() => _status = _PayStatus.success);
    _successCtrl.forward();
    HapticFeedback.heavyImpact();

    // Persist receipt
    try {
      final prefs = await SharedPreferences.getInstance();
      final receipts = prefs.getStringList('mpesa_receipts') ?? [];
      final amtStr = _amount.toStringAsFixed(0);
      receipts.add('$_dealId|$receipt|${DateTime.now().toIso8601String()}|$_listingName|$amtStr');
      if (receipts.length > 50) receipts.removeAt(0);
      await prefs.setStringList('mpesa_receipts', receipts);
    } catch (_) {}
  }

  void _onFailed(String msg) {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    if (mounted) setState(() { _status = _PayStatus.failed; _errorMsg = msg; });
    HapticFeedback.mediumImpact();
  }

  void _onTimeout() {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    if (mounted) setState(() => _status = _PayStatus.timeout);
  }

  void _retry() {
    setState(() {
      _status     = _PayStatus.pending;
      _secondsLeft = 120;
      _pollCount  = 0;
      _errorMsg   = null;
    });
    _startPolling();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String get _formattedAmount =>
      'KES ${_amount.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';

  String get _maskedPhone {
    if (_phone.length >= 4) {
      return '${_phone.substring(0, _phone.length - 4)}****';
    }
    return _phone;
  }

  String get _timeLabel {
    final m = _secondsLeft ~/ 60;
    final s = _secondsLeft % 60;
    return '${m}:${s.toString().padLeft(2, '0')}';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bgMid,
        elevation: 0,
        leading: _status == _PayStatus.pending
            ? const SizedBox.shrink()
            : IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded,
                    color: BrokaColors.textHigh, size: 18),
                onPressed: () => Navigator.pop(context),
              ),
        title: const Text('M-PESA PAYMENT',
            style: TextStyle(color: BrokaColors.textHigh,
                fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1.5)),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: BrokaColors.border),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildStatusIcon(),
              const SizedBox(height: 28),
              _buildStatusText(),
              const SizedBox(height: 24),
              _buildAmountCard(),
              const SizedBox(height: 24),
              _buildActionArea(),
              const SizedBox(height: 32),
              if (_status == _PayStatus.pending) _buildSteps(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Status icon ───────────────────────────────────────────────────────────

  Widget _buildStatusIcon() {
    switch (_status) {
      case _PayStatus.pending:
        return AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, __) => Transform.scale(
            scale: _pulseAnim.value,
            child: Container(
              width: 110, height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  const Color(0xFF00B300).withOpacity(0.25),
                  const Color(0xFF00B300).withOpacity(0.05),
                ]),
                border: Border.all(
                    color: const Color(0xFF00B300).withOpacity(0.5), width: 2),
              ),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('M-PESA', style: TextStyle(
                      color: Color(0xFF00B300),
                      fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1)),
                  const SizedBox(height: 4),
                  SizedBox(width: 24, height: 24,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: const Color(0xFF00B300).withOpacity(0.8))),
                ]),
              ),
            ),
          ),
        );

      case _PayStatus.success:
        return AnimatedBuilder(
          animation: _successAnim,
          builder: (_, __) => Transform.scale(
            scale: _successAnim.value,
            child: Container(
              width: 110, height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: BrokaColors.neonGreen.withOpacity(0.15),
                border: Border.all(color: BrokaColors.neonGreen, width: 2),
                boxShadow: [BoxShadow(
                    color: BrokaColors.neonGreen.withOpacity(0.3),
                    blurRadius: 24, spreadRadius: 4)],
              ),
              child: const Icon(Icons.check_circle_outline_rounded,
                  color: BrokaColors.neonGreen, size: 54),
            ),
          ),
        );

      case _PayStatus.failed:
      case _PayStatus.timeout:
        return Container(
          width: 110, height: 110,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.redAccent.withOpacity(0.12),
            border: Border.all(color: Colors.redAccent.withOpacity(0.6), width: 2),
          ),
          child: Icon(
            _status == _PayStatus.timeout
                ? Icons.timer_off_rounded
                : Icons.cancel_outlined,
            color: Colors.redAccent, size: 54),
        );
    }
  }

  // ── Status text ───────────────────────────────────────────────────────────

  Widget _buildStatusText() {
    switch (_status) {
      case _PayStatus.pending:
        return Column(children: [
          const Text('Waiting for payment…',
              style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 20, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('Check your phone (${ _maskedPhone}) and enter your M-Pesa PIN',
              style: const TextStyle(color: BrokaColors.textMid,
                  fontSize: 13, height: 1.5),
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.timer_outlined,
                color: BrokaColors.textLow, size: 14),
            const SizedBox(width: 4),
            Text('Expires in $_timeLabel',
                style: const TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          ]),
        ]);

      case _PayStatus.success:
        return Column(children: [
          const Text('Payment Successful! 🎉',
              style: TextStyle(color: BrokaColors.neonGreen,
                  fontSize: 22, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text('Your payment has been confirmed by Safaricom.',
              style: TextStyle(color: BrokaColors.textMid,
                  fontSize: 13, height: 1.5),
              textAlign: TextAlign.center),
        ]);

      case _PayStatus.failed:
        return Column(children: [
          const Text('Payment Failed',
              style: TextStyle(color: Colors.redAccent,
                  fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(_errorMsg ?? 'The payment was not completed.',
              style: const TextStyle(color: BrokaColors.textMid,
                  fontSize: 13, height: 1.5),
              textAlign: TextAlign.center),
        ]);

      case _PayStatus.timeout:
        return Column(children: [
          const Text('Payment Timed Out',
              style: TextStyle(color: Colors.orange,
                  fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text('No confirmation received within 2 minutes. '
              'If money was deducted, contact Safaricom on *234#.',
              style: TextStyle(color: BrokaColors.textMid,
                  fontSize: 13, height: 1.5),
              textAlign: TextAlign.center),
        ]);
    }
  }

  // ── Amount card ───────────────────────────────────────────────────────────

  Widget _buildAmountCard() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
          colors: BrokaColors.cardGradColors,
          begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _statusBorderColor),
    ),
    child: Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Amount', style: TextStyle(
            color: BrokaColors.textMid, fontSize: 12)),
        Text(_formattedAmount, style: const TextStyle(
            color: BrokaColors.textHigh,
            fontSize: 22, fontWeight: FontWeight.w900)),
      ]),
      const SizedBox(height: 10),
      const Divider(color: BrokaColors.border, height: 1),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('For', style: TextStyle(
            color: BrokaColors.textMid, fontSize: 12)),
        Expanded(child: Text(_listingName,
            style: const TextStyle(color: BrokaColors.textHigh,
                fontSize: 13, fontWeight: FontWeight.w600),
            textAlign: TextAlign.end,
            maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
      if (_receipt != null) ...[
        const SizedBox(height: 10),
        const Divider(color: BrokaColors.border, height: 1),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Receipt', style: TextStyle(
              color: BrokaColors.textMid, fontSize: 12)),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: _receipt!));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Receipt number copied'),
                duration: Duration(seconds: 2),
              ));
            },
            child: Row(children: [
              Text(_receipt!, style: const TextStyle(
                  color: BrokaColors.neonGreen,
                  fontSize: 13, fontWeight: FontWeight.w800,
                  letterSpacing: 0.5)),
              const SizedBox(width: 6),
              const Icon(Icons.copy_rounded,
                  size: 12, color: BrokaColors.neonGreen),
            ]),
          ),
        ]),
      ],
    ]),
  );

  Color get _statusBorderColor {
    switch (_status) {
      case _PayStatus.success: return BrokaColors.neonGreen.withOpacity(0.5);
      case _PayStatus.failed:
      case _PayStatus.timeout: return Colors.redAccent.withOpacity(0.4);
      default: return const Color(0xFF00B300).withOpacity(0.3);
    }
  }

  // ── Action buttons ────────────────────────────────────────────────────────

  Widget _buildActionArea() {
    switch (_status) {
      case _PayStatus.pending:
        return Column(children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel & Go Back',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 13)),
          ),
          const Text('Do NOT close the app until confirmed',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
        ]);

      case _PayStatus.success:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.neonGreen,
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Back to Negotiation',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        );

      case _PayStatus.failed:
      case _PayStatus.timeout:
        return Column(children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _retry,
              style: ElevatedButton.styleFrom(
                backgroundColor: BrokaColors.gold,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Try Again',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back to Negotiation',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 13)),
          ),
        ]);
    }
  }

  // ── Steps guide (shown while pending) ────────────────────────────────────

  Widget _buildSteps() => Column(
    children: [
      const Divider(color: BrokaColors.border),
      const SizedBox(height: 12),
      const Text('HOW TO COMPLETE', style: TextStyle(
          color: BrokaColors.textLow, fontSize: 10,
          fontWeight: FontWeight.w700, letterSpacing: 1.5)),
      const SizedBox(height: 12),
      _step('1', 'A prompt has been sent to $_maskedPhone'),
      _step('2', 'Open your M-Pesa PIN keyboard on your phone'),
      _step('3', 'Enter your 4-digit M-Pesa PIN and confirm'),
      _step('4', 'Wait - this screen will update automatically'),
      const SizedBox(height: 16),
      ProtectionBadge(status: _liveDealStatus),
      if ((_disputeSummary?['resolved_within_24h_pct'] as num?) != null) ...[
        const SizedBox(height: 8),
        Text(
          "${(_disputeSummary!['resolved_within_24h_pct'] as num).toStringAsFixed(0)}% "
          "of reported problems on BROKA are resolved within 24 hours",
          textAlign: TextAlign.center,
          style: const TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.4),
        ),
      ],
    ],
  );

  Widget _step(String num, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(children: [
      Container(
        width: 22, height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF00B300).withOpacity(0.15),
          border: Border.all(
              color: const Color(0xFF00B300).withOpacity(0.5), width: 1),
        ),
        child: Center(child: Text(num,
            style: const TextStyle(
                color: Color(0xFF00B300),
                fontSize: 11, fontWeight: FontWeight.w800))),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: const TextStyle(
          color: BrokaColors.textMid, fontSize: 12, height: 1.4))),
    ]),
  );
}
