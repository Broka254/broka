// BROKA - Seller Verification Purchase Screen
// Seller picks a tier (Basic KES 299 / Gold KES 599), pays via M-Pesa STK Push,
// and receives a BROKA Verified badge on their profile and all listings.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../services/api_service.dart';

enum _VerifyStep { tiers, payment, waiting, success, failed }

class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});
  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen>
    with SingleTickerProviderStateMixin {

  _VerifyStep _step         = _VerifyStep.tiers;
  String      _selectedTier = 'basic';
  String      _phone        = '';
  String?     _errorMsg;
  String?     _receipt;
  String?     _verifyLabel;
  Timer?      _pollTimer;
  int         _pollCount    = 0;
  static const _maxPolls   = 20;   // 20 × 3s = 60s timeout

  final _phoneCtrl = TextEditingController();
  late  AnimationController _pulseCtrl;

  // Tier data - mirrors backend VERIFY_TIERS
  static const _tiers = {
    'basic': _Tier(
      id:          'basic',
      label:       'BROKA Verified',
      price:       299,
      months:      12,
      color:       Color(0xFFFFB800),
      icon:        Icons.verified_rounded,
      perks: [
        'Gold verified badge on all listings',
        'Higher buyer trust score',
        'Visible in verified seller filter',
        '12-month validity',
      ],
    ),
    'gold': _Tier(
      id:          'gold',
      label:       'BROKA Gold',
      price:       599,
      months:      24,
      color:       Color(0xFFFF6B00),
      icon:        Icons.workspace_premium_rounded,
      perks: [
        'Gold premium badge',
        'Priority search placement',
        'Featured seller section',
        '24-month validity',
        'Fraud-protection guarantee label',
      ],
    ),
  };

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    // Pre-fill phone if known
    final userPhone = ApiService.currentUserPhone;
    if (userPhone != null && userPhone.isNotEmpty) {
      _phoneCtrl.text = userPhone;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _phoneCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _initiatePurchase() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.length < 9) {
      setState(() => _errorMsg = 'Enter a valid Safaricom number e.g. 0712 345 678');
      return;
    }
    setState(() { _step = _VerifyStep.payment; _errorMsg = null; });

    try {
      final result = await ApiService.buyVerification(
        tier:  _selectedTier,
        phone: phone,
      );
      _verifyLabel = result['tier_label'] as String?;
      setState(() { _step = _VerifyStep.waiting; });
      HapticFeedback.mediumImpact();
      _startPolling();
    } catch (e) {
      setState(() {
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
        _step     = _VerifyStep.tiers;
      });
    }
  }

  void _startPolling() {
    _pollCount = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      _pollCount++;
      try {
        final status = await ApiService.checkVerificationStatus();
        final pStatus = status['payment_status'] as String?;
        final verified = status['is_verified'] as bool? ?? false;

        if (verified && pStatus == 'success') {
          _pollTimer?.cancel();
          _receipt = status['mpesa_receipt'] as String?;
          setState(() => _step = _VerifyStep.success);
          HapticFeedback.heavyImpact();
        } else if (pStatus == 'failed') {
          _pollTimer?.cancel();
          setState(() {
            _errorMsg = 'M-Pesa payment was not completed. Please try again.';
            _step     = _VerifyStep.failed;
          });
        } else if (_pollCount >= _maxPolls) {
          _pollTimer?.cancel();
          setState(() {
            _errorMsg = 'Payment timed out. If your M-Pesa was deducted, contact support.';
            _step     = _VerifyStep.failed;
          });
        }
      } catch (_) {
        // Network hiccup - keep polling
      }
    });
  }

  void _retry() => setState(() {
    _step     = _VerifyStep.tiers;
    _errorMsg = null;
    _pollCount = 0;
    _pollTimer?.cancel();
  });

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: BrokaColors.bgCard,
          behavior: SnackBarBehavior.floating),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: _buildAppBar(),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: _buildBody(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() => AppBar(
    backgroundColor: BrokaColors.bg,
    elevation: 0,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_rounded,
          color: BrokaColors.textMid, size: 18),
      onPressed: () => Navigator.pop(context),
    ),
    title: Row(children: [
      Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: BrokaColors.gold.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.verified_rounded,
            color: BrokaColors.gold, size: 18),
      ),
      const SizedBox(width: 10),
      const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Get Verified',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 15, fontWeight: FontWeight.w800)),
        Text('Boost buyer trust on BROKA',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 10)),
      ]),
    ]),
  );

  Widget _buildBody() {
    switch (_step) {
      case _VerifyStep.tiers:   return _buildTiers();
      case _VerifyStep.payment: return _buildPaymentLoading();
      case _VerifyStep.waiting: return _buildWaiting();
      case _VerifyStep.success: return _buildSuccess();
      case _VerifyStep.failed:  return _buildFailed();
    }
  }

  // ── Tier selection ─────────────────────────────────────────────────────────

  Widget _buildTiers() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

      // Hero section
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              BrokaColors.gold.withOpacity(0.12),
              BrokaColors.gold.withOpacity(0.08),
            ],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.3)),
        ),
        child: Column(children: [
          const Icon(Icons.verified_rounded,
              color: BrokaColors.gold, size: 42),
          const SizedBox(height: 12),
          const Text('BROKA Verified Seller',
              style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text(
            'Verified sellers on BROKA earn significantly more buyer trust, '
            'appear higher in search results, and close deals faster.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _StatPill(icon: Icons.trending_up_rounded,
                label: '40% more trust', color: BrokaColors.neonGreen),
            const SizedBox(width: 10),
            _StatPill(icon: Icons.search_rounded,
                label: 'Higher in search', color: BrokaColors.neonBlue),
            const SizedBox(width: 10),
            _StatPill(icon: Icons.handshake_rounded,
                label: 'Close faster', color: BrokaColors.gold),
          ]),
        ]),
      ),

      const SizedBox(height: 28),
      const Text('Choose your plan',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 16, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),

      // Tier cards
      ..._tiers.values.map((tier) => _TierCard(
        tier:     tier,
        selected: _selectedTier == tier.id,
        onTap:    () => setState(() => _selectedTier = tier.id),
      )),

      const SizedBox(height: 24),

      // Phone input
      const Text('M-Pesa Phone Number',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 15, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      const Text('You will receive a payment prompt on this number.',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
      const SizedBox(height: 10),
      Container(
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: TextField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          style: const TextStyle(color: BrokaColors.textHigh,
              fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 1.5),
          decoration: const InputDecoration(
            hintText: '0712 345 678',
            hintStyle: TextStyle(color: BrokaColors.textLow,
                fontSize: 14, letterSpacing: 0),
            prefixIcon: Icon(Icons.phone_android_rounded,
                color: BrokaColors.neonGreen, size: 20),
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          ),
          onChanged: (_) => setState(() => _errorMsg = null),
        ),
      ),

      if (_errorMsg != null) ...[
        const SizedBox(height: 10),
        _ErrorBanner(message: _errorMsg!),
      ],

      const SizedBox(height: 24),

      // Price summary + pay button
      _PriceSummary(tier: _tiers[_selectedTier]!),
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _initiatePurchase,
          style: ElevatedButton.styleFrom(
            backgroundColor: BrokaColors.gold,
            foregroundColor: Colors.black87,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
          icon: const Icon(Icons.phone_android_rounded, size: 18),
          label: Text(
            'Pay KES ${_tiers[_selectedTier]!.price} via M-Pesa',
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
          ),
        ),
      ),

      const SizedBox(height: 16),
      const _SecurityNote(),
    ]),
  );

  // ── Sending STK Push ───────────────────────────────────────────────────────

  Widget _buildPaymentLoading() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      CircularProgressIndicator(color: BrokaColors.gold),
      SizedBox(height: 24),
      Text('Sending payment request…',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 16, fontWeight: FontWeight.w700)),
      SizedBox(height: 8),
      Text('Contacting Safaricom…',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
    ]),
  );

  // ── Waiting for STK completion ─────────────────────────────────────────────

  Widget _buildWaiting() => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, __) => Container(
            width: 80 + _pulseCtrl.value * 12,
            height: 80 + _pulseCtrl.value * 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: BrokaColors.gold.withOpacity(0.08 + _pulseCtrl.value * 0.06),
              border: Border.all(
                  color: BrokaColors.gold.withOpacity(0.4 + _pulseCtrl.value * 0.3),
                  width: 2),
            ),
            child: const Icon(Icons.phone_android_rounded,
                color: BrokaColors.gold, size: 36),
          ),
        ),
        const SizedBox(height: 28),
        const Text('Check your phone',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        const Text(
          'A payment prompt has been sent to your Safaricom number.\n\n'
          'Enter your M-Pesa PIN to complete the payment and activate your badge.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.6),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(
                  color: BrokaColors.neonGreen, strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              'Waiting for confirmation… ($_pollCount/$_maxPolls)',
              style: const TextStyle(color: BrokaColors.textMid,
                  fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
        const SizedBox(height: 32),
        TextButton(
          onPressed: _retry,
          child: const Text('Cancel and try again',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
        ),
      ]),
    ),
  );

  // ── Success ────────────────────────────────────────────────────────────────

  Widget _buildSuccess() {
    final tier = _tiers[_selectedTier]!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 88, height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tier.color.withOpacity(0.12),
              border: Border.all(color: tier.color.withOpacity(0.5), width: 2.5),
            ),
            child: Icon(tier.icon, color: tier.color, size: 44),
          ),
          const SizedBox(height: 24),
          Text('You\'re Verified! 🎉',
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontSize: 24, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          Text(
            'Your "${tier.label}" badge is now active on your profile and all your listings.',
            style: const TextStyle(color: BrokaColors.textMid,
                fontSize: 13, height: 1.6),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),

          // Badge preview
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                tier.color.withOpacity(0.15),
                tier.color.withOpacity(0.05),
              ]),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: tier.color.withOpacity(0.4), width: 1.5),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(tier.icon, color: tier.color, size: 22),
              const SizedBox(width: 8),
              Text(tier.label,
                  style: TextStyle(
                      color: tier.color,
                      fontSize: 15, fontWeight: FontWeight.w900)),
            ]),
          ),

          if (_receipt != null) ...[
            const SizedBox(height: 12),
            Text('M-Pesa: $_receipt',
                style: const TextStyle(color: BrokaColors.textLow,
                    fontSize: 10, fontFamily: 'monospace')),
          ],

          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
              style: ElevatedButton.styleFrom(
                backgroundColor: tier.color,
                foregroundColor: Colors.black87,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text('Go to Dashboard',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
            ),
          ),
        ]),
      ),
    );
  }

  // ── Failed ─────────────────────────────────────────────────────────────────

  Widget _buildFailed() => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.redAccent.withOpacity(0.1),
            border: Border.all(color: Colors.redAccent.withOpacity(0.4), width: 2),
          ),
          child: const Icon(Icons.payment_rounded,
              color: Colors.redAccent, size: 38),
        ),
        const SizedBox(height: 24),
        const Text('Payment Not Completed',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Text(_errorMsg ?? 'The payment was not completed. Please try again.',
            style: const TextStyle(color: BrokaColors.textMid,
                fontSize: 13, height: 1.6),
            textAlign: TextAlign.center),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _retry,
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.gold,
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: const Text('Try Again',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Back to Dashboard',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
        ),
      ]),
    ),
  );
}

// ── Sub-widgets ────────────────────────────────────────────────────────────────

class _Tier {
  final String   id, label;
  final int      price, months;
  final Color    color;
  final IconData icon;
  final List<String> perks;
  const _Tier({
    required this.id, required this.label, required this.price,
    required this.months, required this.color, required this.icon,
    required this.perks,
  });
}

class _TierCard extends StatelessWidget {
  final _Tier tier;
  final bool  selected;
  final VoidCallback onTap;
  const _TierCard({required this.tier, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: selected
            ? LinearGradient(colors: [
                tier.color.withOpacity(0.12),
                BrokaColors.bgCard,
              ], begin: Alignment.topLeft, end: Alignment.bottomRight)
            : null,
        color: selected ? null : BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? tier.color.withOpacity(0.6) : BrokaColors.border,
          width: selected ? 2 : 1,
        ),
        boxShadow: selected
            ? [BoxShadow(color: tier.color.withOpacity(0.15),
                blurRadius: 16, spreadRadius: 1)]
            : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: tier.color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(tier.icon, color: tier.color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tier.label,
                style: TextStyle(
                    color: selected ? tier.color : BrokaColors.textHigh,
                    fontSize: 15, fontWeight: FontWeight.w800)),
            Text('${tier.months}-month validity',
                style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('KES ${tier.price}',
                style: TextStyle(
                    color: selected ? tier.color : BrokaColors.textHigh,
                    fontSize: 18, fontWeight: FontWeight.w900)),
            Text('one-time',
                style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
          ]),
          if (selected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check_circle_rounded, color: tier.color, size: 22),
          ],
        ]),
        const SizedBox(height: 12),
        ...tier.perks.map((p) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Icon(Icons.check_rounded, color: tier.color, size: 14),
            const SizedBox(width: 6),
            Text(p, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 12)),
          ]),
        )),
        if (tier.id == 'gold') ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: tier.color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('Best value',
                style: TextStyle(
                    color: tier.color,
                    fontSize: 10, fontWeight: FontWeight.w700)),
          ),
        ],
      ]),
    ),
  );
}

class _PriceSummary extends StatelessWidget {
  final _Tier tier;
  const _PriceSummary({required this.tier});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(children: [
      const Icon(Icons.receipt_outlined, color: BrokaColors.textLow, size: 18),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tier.label,
            style: const TextStyle(color: BrokaColors.textHigh,
                fontWeight: FontWeight.w700, fontSize: 13)),
        Text('${tier.months} months validity',
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
      ])),
      Text('KES ${tier.price}',
          style: TextStyle(
              color: tier.color,
              fontSize: 16, fontWeight: FontWeight.w900)),
    ]),
  );
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  const _StatPill({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.25)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 12),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(
          color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    ]),
  );
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.redAccent.withOpacity(0.1),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
    ),
    child: Row(children: [
      const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(message,
          style: const TextStyle(color: Colors.redAccent,
              fontSize: 12, height: 1.4))),
    ]),
  );
}

class _SecurityNote extends StatelessWidget {
  const _SecurityNote();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: BrokaColors.border),
    ),
    child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.lock_outline_rounded, color: BrokaColors.neonGreen, size: 14),
      SizedBox(width: 8),
      Expanded(child: Text(
        'Payment is processed securely via Safaricom Daraja. '
        'BROKA never stores your M-Pesa PIN. '
        'You will receive an M-Pesa SMS confirmation.',
        style: TextStyle(color: BrokaColors.textLow, fontSize: 10, height: 1.5),
      )),
    ]),
  );
}
