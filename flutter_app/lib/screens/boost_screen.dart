// BROKA - Boost Listing Screen
// Seller picks one of their listings, selects a boost plan (1 week KES 99 /
// 4 weeks KES 350), pays via M-Pesa STK Push, and the listing gets a glowing
// FEATURED badge pinned to the top of the home feed.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../services/api_service.dart';

enum _BoostStep { picking, payment, waiting, success, failed }

class BoostScreen extends StatefulWidget {
  const BoostScreen({super.key});
  @override
  State<BoostScreen> createState() => _BoostScreenState();
}

class _BoostScreenState extends State<BoostScreen>
    with SingleTickerProviderStateMixin {

  _BoostStep _step = _BoostStep.picking;

  // Listings
  List<Map<String, dynamic>> _listings = [];
  bool   _listingsLoading = true;
  String? _selectedId;
  String? _selectedName;
  bool   _selectedFeatured = false;
  String? _featuredUntil;

  // Plan
  String _plan = 'week';

  // Phone
  final _phoneCtrl = TextEditingController();
  String? _errorMsg;

  // Waiting / result
  String? _receipt;
  String? _newFeaturedUntil;
  Timer?  _pollTimer;
  int     _pollCount = 0;
  static const _maxPolls = 20;

  // Pulse animation
  late AnimationController _pulseCtrl;

  static const _plans = {
    'week':  _Plan(id: 'week',  label: '1 Week Boost',  price: 99,  days: 7,  bestValue: false),
    'month': _Plan(id: 'month', label: '4 Week Boost',  price: 350, days: 28, bestValue: true),
  };

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    final phone = ApiService.currentUserPhone;
    if (phone != null) _phoneCtrl.text = phone;
    _loadListings();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pulseCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadListings() async {
    setState(() => _listingsLoading = true);
    try {
      final data = await ApiService.getMyBoostableListings();
      if (mounted) {
        setState(() {
          _listings = List<Map<String, dynamic>>.from(data);
          _listingsLoading = false;
          // Auto-select first active listing
          if (_listings.isNotEmpty && _selectedId == null) {
            final first = _listings.first;
            _selectedId      = first['id'] as String;
            _selectedName    = first['name'] as String;
            _selectedFeatured = first['is_featured'] as bool? ?? false;
            _featuredUntil   = first['featured_until'] as String?;
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _listingsLoading = false);
    }
  }

  Future<void> _initiatBoost() async {
    if (_selectedId == null) {
      setState(() => _errorMsg = 'Please select a listing to boost.');
      return;
    }
    final phone = _phoneCtrl.text.trim();
    if (phone.length < 9) {
      setState(() => _errorMsg = 'Enter a valid Safaricom number e.g. 0712 345 678');
      return;
    }
    setState(() { _step = _BoostStep.payment; _errorMsg = null; });

    try {
      await ApiService.boostListing(
        listingId: _selectedId!,
        plan:      _plan,
        phone:     phone,
      );
      setState(() => _step = _BoostStep.waiting);
      HapticFeedback.mediumImpact();
      _startPolling();
    } catch (e) {
      setState(() {
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
        _step = _BoostStep.picking;
      });
    }
  }

  void _startPolling() {
    _pollCount = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      _pollCount++;
      try {
        final status = await ApiService.checkBoostStatus(_selectedId!);
        final pStatus = status['payment_status'] as String?;
        final featured = status['is_featured'] as bool? ?? false;

        if (featured && pStatus == 'success') {
          _pollTimer?.cancel();
          _receipt        = status['mpesa_receipt'] as String?;
          _newFeaturedUntil = status['featured_until'] as String?;
          setState(() => _step = _BoostStep.success);
          HapticFeedback.heavyImpact();
        } else if (pStatus == 'failed') {
          _pollTimer?.cancel();
          setState(() {
            _errorMsg = 'M-Pesa payment was not completed. Please try again.';
            _step = _BoostStep.failed;
          });
        } else if (_pollCount >= _maxPolls) {
          _pollTimer?.cancel();
          setState(() {
            _errorMsg = 'Payment timed out. If M-Pesa was deducted, contact support.';
            _step = _BoostStep.failed;
          });
        }
      } catch (_) {}
    });
  }

  void _retry() => setState(() {
    _step = _BoostStep.picking;
    _errorMsg = null;
    _pollCount = 0;
    _pollTimer?.cancel();
  });

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    appBar: _buildAppBar(),
    body: AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: _buildBody(),
    ),
  );

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
        child: const Icon(Icons.rocket_launch_rounded,
            color: BrokaColors.gold, size: 18),
      ),
      const SizedBox(width: 10),
      const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Boost Listing',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 15, fontWeight: FontWeight.w800)),
        Text('Pin to the top of the feed',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 10)),
      ]),
    ]),
  );

  Widget _buildBody() {
    switch (_step) {
      case _BoostStep.picking:  return _buildPicker();
      case _BoostStep.payment:  return _buildPaymentLoading();
      case _BoostStep.waiting:  return _buildWaiting();
      case _BoostStep.success:  return _buildSuccess();
      case _BoostStep.failed:   return _buildFailed();
    }
  }

  // ── Picker ─────────────────────────────────────────────────────────────────

  Widget _buildPicker() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

      // Hero banner
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            BrokaColors.gold.withOpacity(0.12),
            BrokaColors.neonBlue.withOpacity(0.08),
          ], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.25)),
        ),
        child: Column(children: [
          const Icon(Icons.rocket_launch_rounded,
              color: BrokaColors.gold, size: 40),
          const SizedBox(height: 12),
          const Text('Get More Eyes on Your Listing',
              style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 17, fontWeight: FontWeight.w900),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text(
            'Boosted listings appear at the top of the home feed '
            'with a glowing FEATURED badge - seen first by every buyer in your area.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _StatPill(icon: Icons.visibility_rounded, label: '5x more views',        color: BrokaColors.neonBlue),
            const SizedBox(width: 8),
            _StatPill(icon: Icons.push_pin_rounded,   label: 'Pinned to top',        color: BrokaColors.gold),
            const SizedBox(width: 8),
            _StatPill(icon: Icons.bolt_rounded,       label: 'Sell 3x faster',       color: BrokaColors.gold),
          ]),
        ]),
      ),

      const SizedBox(height: 24),

      // Listing selector
      const Text('Choose a listing to boost',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 15, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),

      if (_listingsLoading)
        const Center(child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: CircularProgressIndicator(color: BrokaColors.gold),
        ))
      else if (_listings.isEmpty)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.border),
          ),
          child: const Column(children: [
            Icon(Icons.inventory_2_outlined, color: BrokaColors.textLow, size: 32),
            SizedBox(height: 10),
            Text('No active listings', style: TextStyle(color: BrokaColors.textMid)),
            SizedBox(height: 4),
            Text('Create a listing first, then boost it.',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          ]),
        )
      else
        ..._listings.map((l) {
          final id         = l['id'] as String;
          final name       = l['name'] as String;
          final category   = l['category'] as String? ?? '';
          final isFeatured = l['is_featured'] as bool? ?? false;
          final selected   = id == _selectedId;
          return GestureDetector(
            onTap: () => setState(() {
              _selectedId       = id;
              _selectedName     = name;
              _selectedFeatured = isFeatured;
              _featuredUntil    = l['featured_until'] as String?;
              _errorMsg         = null;
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: selected
                    ? BrokaColors.gold.withOpacity(0.08)
                    : BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected
                      ? BrokaColors.gold.withOpacity(0.5)
                      : BrokaColors.border,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: BrokaColors.bgMid,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(child: Text(_categoryEmoji(category),
                      style: const TextStyle(fontSize: 20))),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: const TextStyle(color: BrokaColors.textHigh,
                      fontWeight: FontWeight.w700, fontSize: 13),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(category, style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
                ])),
                if (isFeatured)
                  _FeaturedBadge(small: true)
                else if (selected)
                  const Icon(Icons.check_circle_rounded,
                      color: BrokaColors.gold, size: 22),
              ]),
            ),
          );
        }),

      const SizedBox(height: 20),

      // Plan selector
      const Text('Choose a plan',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 15, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),

      Row(children: _plans.values.map((plan) {
        final selected = _plan == plan.id;
        return Expanded(child: GestureDetector(
          onTap: () => setState(() { _plan = plan.id; _errorMsg = null; }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: EdgeInsets.only(right: plan.id == 'week' ? 8 : 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.gold.withOpacity(0.10)
                  : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? BrokaColors.gold.withOpacity(0.5)
                    : BrokaColors.border,
                width: selected ? 2 : 1,
              ),
              boxShadow: selected ? [BoxShadow(
                color: BrokaColors.gold.withOpacity(0.12),
                blurRadius: 12,
              )] : null,
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (plan.bestValue)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: BrokaColors.gold.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('Best value',
                      style: TextStyle(color: BrokaColors.gold,
                          fontSize: 9, fontWeight: FontWeight.w800)),
                ),
              Text(plan.label,
                  style: TextStyle(
                    color: selected ? BrokaColors.gold : BrokaColors.textHigh,
                    fontWeight: FontWeight.w800, fontSize: 13,
                  )),
              const SizedBox(height: 4),
              Text('KES ${plan.price}',
                  style: TextStyle(
                    color: selected ? BrokaColors.gold : BrokaColors.textMid,
                    fontWeight: FontWeight.w900, fontSize: 20,
                  )),
              Text('${plan.days} days',
                  style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
              if (selected) ...[
                const SizedBox(height: 8),
                const Icon(Icons.check_circle_rounded,
                    color: BrokaColors.gold, size: 18),
              ],
            ]),
          ),
        ));
      }).toList()),

      const SizedBox(height: 20),

      // Phone input
      const Text('M-Pesa Phone Number',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 15, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
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

      const SizedBox(height: 20),

      // Price summary
      Container(
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
            Text(
              _selectedName != null
                  ? 'Boost: ${_selectedName!.length > 30 ? _selectedName!.substring(0, 28) + "…" : _selectedName}'
                  : 'Select a listing',
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontWeight: FontWeight.w700, fontSize: 13),
            ),
            Text(_plans[_plan]!.label,
                style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
          ])),
          Text('KES ${_plans[_plan]!.price}',
              style: const TextStyle(color: BrokaColors.gold,
                  fontSize: 16, fontWeight: FontWeight.w900)),
        ]),
      ),

      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _listings.isEmpty ? null : _initiatBoost,
          style: ElevatedButton.styleFrom(
            backgroundColor: BrokaColors.gold,
            foregroundColor: Colors.white,
            disabledBackgroundColor: BrokaColors.bgCard,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
          icon: const Icon(Icons.rocket_launch_rounded, size: 18),
          label: Text(
            'Pay KES ${_plans[_plan]!.price} via M-Pesa',
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

  // ── Waiting for payment ────────────────────────────────────────────────────

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
          'Enter your M-Pesa PIN to activate your FEATURED boost.',
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
    final plan = _plans[_plan]!;
    String expiryText = '${plan.days} days from now';
    if (_newFeaturedUntil != null) {
      try {
        final dt = DateTime.parse(_newFeaturedUntil!).toLocal();
        expiryText = '${dt.day}/${dt.month}/${dt.year}';
      } catch (_) {}
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) => Container(
              width: 88, height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: BrokaColors.gold.withOpacity(0.08 + _pulseCtrl.value * 0.08),
                border: Border.all(
                    color: BrokaColors.gold.withOpacity(0.4 + _pulseCtrl.value * 0.3),
                    width: 2.5),
              ),
              child: const Icon(Icons.rocket_launch_rounded,
                  color: BrokaColors.gold, size: 44),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Your Listing is LIVE! 🚀',
              style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 22, fontWeight: FontWeight.w900),
              textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Text(
            '"${_selectedName ?? 'Your listing'}" is now pinned to the top of the feed '
            'with a FEATURED badge.',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.6),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),

          // Boost preview chip
          const _FeaturedBadge(small: false),

          const SizedBox(height: 12),
          Text('Active until: $expiryText',
              style: const TextStyle(color: BrokaColors.textMid,
                  fontSize: 12, fontWeight: FontWeight.w600)),
          if (_receipt != null) ...[
            const SizedBox(height: 8),
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
                backgroundColor: BrokaColors.gold,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text('Back to Home',
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
          child: const Icon(Icons.payment_rounded, color: Colors.redAccent, size: 38),
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
              foregroundColor: Colors.white,
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
          child: const Text('Back',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
        ),
      ]),
    ),
  );

  String _categoryEmoji(String cat) {
    switch (cat) {
      case 'Vehicles':    return '🚗';
      case 'Property':    return '🏠';
      case 'Electronics': return '📱';
      case 'Livestock':   return '🐄';
      default:            return '📦';
    }
  }
}

// ── Sub-widgets ────────────────────────────────────────────────────────────────

class _Plan {
  final String id, label;
  final int price, days;
  final bool bestValue;
  const _Plan({required this.id, required this.label, required this.price,
      required this.days, required this.bestValue});
}

class _FeaturedBadge extends StatelessWidget {
  final bool small;
  const _FeaturedBadge({required this.small});

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
        horizontal: small ? 8 : 16, vertical: small ? 4 : 8),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
          colors: [BrokaColors.gold, BrokaColors.neonBlue]),
      borderRadius: BorderRadius.circular(small ? 20 : 12),
      boxShadow: [BoxShadow(
          color: BrokaColors.gold.withOpacity(0.4),
          blurRadius: small ? 8 : 16, spreadRadius: 1)],
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.rocket_launch_rounded,
          color: Colors.white, size: small ? 10 : 16),
      const SizedBox(width: 4),
      Text('FEATURED',
          style: TextStyle(color: Colors.white,
              fontSize: small ? 9 : 13, fontWeight: FontWeight.w900,
              letterSpacing: 0.5)),
    ]),
  );
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
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
      Text(label, style: TextStyle(color: color,
          fontSize: 10, fontWeight: FontWeight.w700)),
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
          style: const TextStyle(color: Colors.redAccent, fontSize: 12, height: 1.4))),
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
        'Payment processed securely via Safaricom Daraja. '
        'BROKA never stores your M-Pesa PIN.',
        style: TextStyle(color: BrokaColors.textLow, fontSize: 10, height: 1.5),
      )),
    ]),
  );
}
