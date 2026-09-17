// BROKA - Deal Receipt History Screen
// Lists all M-Pesa receipts stored locally in SharedPreferences.
// Format per entry: dealId|receipt|isoDate|listingName|amount

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';

class DealReceiptHistoryScreen extends StatefulWidget {
  const DealReceiptHistoryScreen({super.key});
  @override
  State<DealReceiptHistoryScreen> createState() => _DealReceiptHistoryScreenState();
}

class _DealReceiptHistoryScreenState extends State<DealReceiptHistoryScreen> {
  List<_Receipt> _receipts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final prefs   = await SharedPreferences.getInstance();
      final raw     = prefs.getStringList('mpesa_receipts') ?? [];
      final parsed  = raw.reversed.map(_Receipt.parse).whereType<_Receipt>().toList();
      if (mounted) setState(() { _receipts = parsed; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteReceipt(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getStringList('mpesa_receipts') ?? [];
      // receipts are displayed reversed, so real index = raw.length - 1 - index
      final realIdx = raw.length - 1 - index;
      if (realIdx >= 0 && realIdx < raw.length) {
        raw.removeAt(realIdx);
        await prefs.setStringList('mpesa_receipts', raw);
      }
    } catch (_) {}
    setState(() => _receipts.removeAt(index));
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: BrokaColors.border)),
        title: const Text('Clear All Receipts',
            style: TextStyle(color: BrokaColors.textHigh,
                fontWeight: FontWeight.w800)),
        content: const Text(
            'This removes all receipts from this device only. '
            'Your Safaricom transaction records are not affected.',
            style: TextStyle(color: BrokaColors.textMid, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: BrokaColors.textLow)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Clear All',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('mpesa_receipts');
      } catch (_) {}
      setState(() => _receipts.clear());
    }
  }

  void _copyReceipt(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_outline_rounded,
              color: BrokaColors.neonGreen, size: 16),
          const SizedBox(width: 8),
          Text('Receipt $code copied to clipboard',
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ]),
        backgroundColor: BrokaColors.bgCard,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bgMid,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textHigh, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('PAYMENT RECEIPTS',
            style: TextStyle(color: BrokaColors.textHigh,
                fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1.5)),
        centerTitle: true,
        actions: [
          if (_receipts.isNotEmpty)
            TextButton(
              onPressed: _clearAll,
              child: const Text('Clear All',
                  style: TextStyle(color: Colors.redAccent,
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: BrokaColors.border),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: BrokaColors.gold,
        backgroundColor: BrokaColors.bgMid,
        child: _loading
            ? const Center(child: CircularProgressIndicator(
                color: BrokaColors.gold))
            : _receipts.isEmpty
                ? _buildEmpty()
                : _buildList(),
      ),
    );
  }

  // ── Empty state ───────────────────────────────────────────────────────────

  Widget _buildEmpty() => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 32),
    children: [
      const SizedBox(height: 100),
      Center(child: Container(
        width: 90, height: 90,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF00B300).withOpacity(0.1),
          border: Border.all(
              color: const Color(0xFF00B300).withOpacity(0.3), width: 2),
        ),
        child: const Center(
          child: Text('M-PESA',
              style: TextStyle(color: Color(0xFF00B300),
                  fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 1)),
        ),
      )),
      const SizedBox(height: 24),
      const Text('No Receipts Yet',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 20, fontWeight: FontWeight.w800),
          textAlign: TextAlign.center),
      const SizedBox(height: 10),
      const Text(
          'Completed M-Pesa payments will appear here.\n'
          'Each receipt is saved automatically after a successful transaction.',
          style: TextStyle(color: BrokaColors.textMid,
              fontSize: 13, height: 1.6),
          textAlign: TextAlign.center),
    ],
  );

  // ── Receipt list ──────────────────────────────────────────────────────────

  Widget _buildList() => ListView.builder(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
    itemCount: _receipts.length + 1,
    itemBuilder: (_, i) {
      if (i == 0) return _buildSummaryBanner();
      final r = _receipts[i - 1];
      return _ReceiptCard(
        receipt: r,
        onCopy:    () => _copyReceipt(r.receiptCode),
        onDelete:  () => _deleteReceipt(i - 1),
        onDispute: () => Navigator.pushNamed(context, '/dispute', arguments: {
          'dealId':      r.dealId,
          'listingName': r.listingName,
          'receiptCode': r.receiptCode,
          'amount':      r.amount,
        }),
      );
    },
  );

  Widget _buildSummaryBanner() {
    final total = _receipts.fold<double>(0, (s, r) => s + r.amount);
    final formatted = 'KES ${total.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          const Color(0xFF00B300).withOpacity(0.12),
          const Color(0xFF00B300).withOpacity(0.04),
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF00B300).withOpacity(0.3)),
      ),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_receipts.length} deal${_receipts.length == 1 ? '' : 's'} completed',
              style: const TextStyle(color: BrokaColors.textMid,
                  fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(formatted,
              style: const TextStyle(color: Color(0xFF00B300),
                  fontSize: 24, fontWeight: FontWeight.w900)),
          const Text('Total paid via M-Pesa',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
        ]),
        const Spacer(),
        const Icon(Icons.account_balance_wallet_outlined,
            color: Color(0xFF00B300), size: 40),
      ]),
    );
  }
}

// ── Receipt card (swipe-to-dismiss) ────────────────────────────────────────

class _ReceiptCard extends StatelessWidget {
  final _Receipt receipt;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onDispute;

  const _ReceiptCard({
    required this.receipt,
    required this.onCopy,
    required this.onDelete,
    required this.onDispute,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key(receipt.receiptCode + receipt.date.toIso8601String()),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
            SizedBox(width: 6),
            Text('Delete', style: TextStyle(
                color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Top row: listing name + amount
          Row(children: [
            Expanded(
              child: Text(
                receipt.listingName.isNotEmpty
                    ? receipt.listingName
                    : 'BROKA Deal',
                style: const TextStyle(
                    color: BrokaColors.textHigh,
                    fontWeight: FontWeight.w700, fontSize: 14),
                maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(receipt.formattedAmount,
                style: const TextStyle(
                    color: Color(0xFF00B300),
                    fontWeight: FontWeight.w900, fontSize: 15)),
          ]),

          const SizedBox(height: 10),
          const Divider(color: BrokaColors.border, height: 1),
          const SizedBox(height: 10),

          // Receipt number
          Row(children: [
            const Icon(Icons.receipt_long_outlined,
                color: BrokaColors.textLow, size: 14),
            const SizedBox(width: 6),
            const Text('Receipt: ',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
            Expanded(
              child: Text(receipt.receiptCode,
                  style: const TextStyle(
                      color: BrokaColors.neonGreen,
                      fontWeight: FontWeight.w800, fontSize: 13,
                      letterSpacing: 0.5)),
            ),
            GestureDetector(
              onTap: onCopy,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: BrokaColors.neonGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: BrokaColors.neonGreen.withOpacity(0.3)),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.copy_rounded,
                      size: 11, color: BrokaColors.neonGreen),
                  SizedBox(width: 4),
                  Text('Copy', style: TextStyle(
                      color: BrokaColors.neonGreen,
                      fontSize: 10, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ]),

          const SizedBox(height: 8),

          // Date row
          Row(children: [
            const Icon(Icons.access_time_rounded,
                color: BrokaColors.textLow, size: 13),
            const SizedBox(width: 6),
            Text(receipt.formattedDate,
                style: const TextStyle(
                    color: BrokaColors.textLow, fontSize: 11)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF00B300).withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('PAID',
                  style: TextStyle(
                      color: Color(0xFF00B300),
                      fontSize: 9, fontWeight: FontWeight.w900,
                      letterSpacing: 1.2)),
            ),
          ]),
          const SizedBox(height: 10),
          // Dispute button
          GestureDetector(
            onTap: onDispute,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Colors.redAccent.withOpacity(0.25)),
              ),
              child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                Icon(Icons.gavel_rounded,
                    color: Colors.redAccent, size: 13),
                SizedBox(width: 6),
                Text('Open Dispute with Zeno',
                    style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Data model ────────────────────────────────────────────────────────────

class _Receipt {
  final String dealId;
  final String receiptCode;
  final DateTime date;
  final String listingName;
  final double amount;

  const _Receipt({
    required this.dealId,
    required this.receiptCode,
    required this.date,
    required this.listingName,
    required this.amount,
  });

  /// Parse from stored format: dealId|receiptCode|isoDate[|listingName|amount]
  static _Receipt? parse(String raw) {
    try {
      final parts = raw.split('|');
      if (parts.length < 3) return null;
      return _Receipt(
        dealId:      parts[0],
        receiptCode: parts[1],
        date:        DateTime.parse(parts[2]),
        listingName: parts.length > 3 ? parts[3] : '',
        amount:      parts.length > 4 ? double.tryParse(parts[4]) ?? 0.0 : 0.0,
      );
    } catch (_) { return null; }
  }

  String get formattedAmount {
    if (amount <= 0) return '';
    return 'KES ${amount.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';
  }

  String get formattedDate {
    final now  = DateTime.now();
    final diff = now.difference(date);
    if (diff.inSeconds < 60)  return 'Just now';
    if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24)  return '${diff.inHours}h ago';
    if (diff.inDays    < 7)   return '${diff.inDays}d ago';
    final months = ['Jan','Feb','Mar','Apr','May','Jun',
                    'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}
