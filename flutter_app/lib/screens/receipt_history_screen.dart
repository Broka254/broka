// BROKA — payment receipts
//
// Every completed payment on this seller's deals.
//
// The "Payment Receipts" button on the dashboard has pointed at
// '/receipt-history' since before this work started, and nothing was ever
// registered at that route — tapping it threw. This is the screen it was
// promising.
//
// Provider-neutral throughout. The backing table is named for M-Pesa
// because that is the rail that exists today, but nothing here says so: the
// API returns a generic `provider` and `reference`, so when Airtel Money or
// anything else settles into the same escrow it appears without a client
// change. Naming one provider in the UI is how the others come to look
// unsupported.

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/api_service.dart';
import '../widgets/chat_ambient_background.dart';
import '../widgets/motion_widgets.dart';

class ReceiptHistoryScreen extends StatefulWidget {
  const ReceiptHistoryScreen({super.key});

  @override
  State<ReceiptHistoryScreen> createState() => _ReceiptHistoryScreenState();
}

class _ReceiptHistoryScreenState extends State<ReceiptHistoryScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = ApiService.currentUserId;
    if (uid == null) {
      setState(() { _loading = false; _error = 'Not signed in.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final d = await ApiService.getSellerReceipts(uid);
      if (mounted) setState(() { _data = d; _loading = false; });
    } catch (e) {
      // Distinguishes "could not load" from "nothing to show". An empty
      // list after a failed request would tell a seller they have never
      // been paid, which is a considerably worse thing to get wrong.
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  String _money(num v) {
    final s = v.toStringAsFixed(0);
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return 'KES $buf';
  }

  String _date(String? iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    const months = ['Jan','Feb','Mar','Apr','May','Jun',
                    'Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} ${d.year} · $h:$m';
  }

  @override
  Widget build(BuildContext context) => ChatAmbientBackground(
        intensity: 0.85,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: BrokaColors.bg.withOpacity(0.55),
            elevation: 0,
            scrolledUnderElevation: 0,
            title: const Text('PAYMENT RECEIPTS',
                style: TextStyle(fontSize: 13, letterSpacing: 1.5,
                    fontWeight: FontWeight.w900, color: BrokaColors.textHigh)),
            centerTitle: false,
          ),
          body: _loading
              ? _skeleton()
              : (_error != null ? _errorState() : _content()),
        ),
      );

  Widget _skeleton() => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: const [
          ShimmerBox(height: 92, radius: BorderRadius.all(Radius.circular(16))),
          SizedBox(height: 12),
          ShimmerBox(height: 76, radius: BorderRadius.all(Radius.circular(14))),
          SizedBox(height: 10),
          ShimmerBox(height: 76, radius: BorderRadius.all(Radius.circular(14))),
        ],
      );

  Widget _errorState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.receipt_long_rounded,
                color: BrokaColors.textMid, size: 34),
            const SizedBox(height: 12),
            const Text("Couldn't load your receipts",
                textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 14)),
            const SizedBox(height: 6),
            const Text('This is a connection problem, not an empty history.',
                textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
            const SizedBox(height: 14),
            PressableScale(
              onTap: _load,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: BrokaColors.neonBlue.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.35)),
                ),
                child: const Text('Try again',
                    style: TextStyle(color: BrokaColors.neonBlue,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      );

  Widget _content() {
    final receipts = (_data?['receipts'] as List?) ?? const [];
    final total = (_data?['total'] as num?)?.toDouble() ?? 0;

    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        itemCount: receipts.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) return _summary(total, receipts.length);
          final r = receipts[i - 1] as Map;
          return FadeSlideIn(index: i, child: _receiptCard(r));
        },
      ),
    );
  }

  Widget _summary(double total, int count) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              Color.alphaBlend(
                  BrokaColors.neonGreen.withOpacity(0.12), BrokaColors.bg),
              BrokaColors.bg,
            ], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.28)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('RELEASED TO YOU',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 10,
                    letterSpacing: 1.4, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(_money(total),
                style: const TextStyle(color: BrokaColors.neonGreen,
                    fontSize: 28, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(count == 0
                    ? 'No completed payments yet'
                    : 'Across $count completed ${count == 1 ? "payment" : "payments"}',
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 11.5)),
          ]),
        ),
      );

  Widget _receiptCard(Map r) {
    final ref = r['reference'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(r['listing'] as String? ?? 'Listing',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh,
                    fontSize: 13.5, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Text(_money((r['amount'] as num?) ?? 0),
              style: const TextStyle(color: BrokaColors.neonGreen,
                  fontSize: 15, fontWeight: FontWeight.w900)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          const Icon(Icons.person_outline_rounded,
              size: 12, color: BrokaColors.textMid),
          const SizedBox(width: 4),
          Expanded(
            child: Text(r['buyer'] as String? ?? '',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 11.5)),
          ),
          Text(_date(r['paid_at'] as String?),
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5)),
        ]),
        if (ref != null && ref.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: BrokaColors.bg.withOpacity(0.6),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              // Provider comes from the API, not hardcoded - so a payment
              // that settles over a different rail labels itself correctly
              // without a client change.
              Text('${r['provider'] ?? 'Payment'} · ',
                  style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 10)),
              Text(ref,
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontSize: 10.5, fontFamily: 'monospace',
                      fontWeight: FontWeight.w700)),
            ]),
          ),
        ],
      ]),
    );
  }
}
