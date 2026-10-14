// BROKA — payment receipts
//
// Every completed payment on this seller's deals - and, on the second tab,
// what the seller paid BROKA: listing fees and premium plans, each with its
// M-Pesa receipt. Those were the receipts sellers were asked for most and
// could not find anywhere in the app.
//
// Two tabs rather than one list: a sale is money in and a fee is money
// out, and one running total over both would be neither.
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
import '../core/errors/user_facing_error.dart';

class ReceiptHistoryScreen extends StatefulWidget {
  const ReceiptHistoryScreen({super.key, this.loader});

  /// For tests: what GET /listings/seller/{id}/receipts would answer.
  final Future<Map<String, dynamic>> Function()? loader;

  @override
  State<ReceiptHistoryScreen> createState() => _ReceiptHistoryScreenState();
}

class _ReceiptHistoryScreenState extends State<ReceiptHistoryScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  /// 0: sales released to the seller. 1: fees and plans paid to BROKA.
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = ApiService.currentUserId;
    if (uid == null && widget.loader == null) {
      setState(() { _loading = false; _error = 'Not signed in.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final d = await (widget.loader?.call() ?? ApiService.getSellerReceipts(uid!));
      if (mounted) setState(() { _data = d; _loading = false; });
    } catch (e) {
      // Distinguishes "could not load" from "nothing to show". An empty
      // list after a failed request would tell a seller they have never
      // been paid, which is a considerably worse thing to get wrong.
      if (mounted) setState(() { _loading = false; _error = userFacingError(e); });
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
    final sales = _tab == 0;
    final items = (_data?[sales ? 'receipts' : 'charges'] as List?) ?? const [];
    final total = (_data?[sales ? 'total' : 'charges_total'] as num?)?.toDouble() ?? 0;

    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        itemCount: items.length + 2,
        itemBuilder: (_, i) {
          if (i == 0) return _tabs();
          if (i == 1) return sales ? _summary(total, items.length) : _chargesSummary(total, items.length);
          final r = items[i - 2] as Map;
          return FadeSlideIn(index: i, child: sales ? _receiptCard(r) : _chargeCard(r));
        },
      ),
    );
  }

  /// Sales | Fees & plans, in the dashboard's pill-switcher language.
  Widget _tabs() {
    Widget pill(int index, String label) {
      final selected = _tab == index;
      return Expanded(
        child: GestureDetector(
          key: Key('receipts-tab-$index'),
          onTap: () => setState(() => _tab = index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: selected ? const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]) : null,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(label,
                style: TextStyle(
                    color: selected ? Colors.white : BrokaColors.textMid,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        height: 42,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.86),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(children: [pill(0, 'Sales'), pill(1, 'Fees & plans')]),
      ),
    );
  }

  Widget _chargesSummary(double total, int count) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          key: const Key('charges-summary'),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              Color.alphaBlend(BrokaColors.gold.withOpacity(0.14), BrokaColors.bg),
              BrokaColors.bg,
            ], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BrokaColors.gold.withOpacity(0.3)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('PAID TO BROKA',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 10,
                    letterSpacing: 1.4, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(_money(total),
                style: const TextStyle(color: BrokaColors.gold,
                    fontSize: 28, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(count == 0
                    ? 'No listing fees or plans paid yet'
                    : 'Listing fees and premium plans · $count ${count == 1 ? "payment" : "payments"}',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
          ]),
        ),
      );

  /// A listing fee or a plan: what it was for, the amount, and the receipt.
  Widget _chargeCard(Map r) {
    final ref = r['reference'] as String?;
    final premium = r['kind'] == 'premium';
    final colour = premium ? BrokaColors.gold : BrokaColors.neonBlue;
    return Container(
      key: Key('charge-${r['id']}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colour.withOpacity(0.14),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(premium ? Icons.workspace_premium_rounded : Icons.sell_rounded, size: 12, color: colour),
              const SizedBox(width: 4),
              Text(r['title'] as String? ?? (premium ? 'Premium plan' : 'Listing fee'),
                  style: TextStyle(color: colour, fontSize: 10.5, fontWeight: FontWeight.w800)),
            ]),
          ),
          const Spacer(),
          Text(_money((r['amount'] as num?) ?? 0),
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w900)),
        ]),
        const SizedBox(height: 8),
        Text(r['subject'] as String? ?? '',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: Text(r['detail'] as String? ?? '',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
          ),
          Text(_date(r['paid_at'] as String?),
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5)),
        ]),
        if (ref != null && ref.isNotEmpty) ...[
          const SizedBox(height: 8),
          _reference(r['provider'] as String?, ref),
        ],
      ]),
    );
  }

  Widget _reference(String? provider, String ref) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: BrokaColors.bg.withOpacity(0.6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${provider ?? 'Payment'} · ', style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
          Text(ref,
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontSize: 10.5, fontFamily: 'monospace', fontWeight: FontWeight.w700)),
        ]),
      );

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
