// Buyer protection, as the two deal chats (Zeno's room and the direct chat)
// show it: paying into escrow at once or in parts, releasing the money with
// a delivery check first, asking for a refund, and the seller's side of each
// (marking the deal delivered, answering a refund request, stating the
// price).
//
// The rules are the backend's (api/domains/escrow/protection.py and
// policy.py): these dialogs only ask and explain. Nothing here decides when
// money moves - a "no" to "has it been delivered?" is a recommendation to
// wait, never a block, because the buyer may know better.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../utils/price_format.dart';
import '../data/repositories/escrow_repository.dart';

double? _num(dynamic v) => (v as num?)?.toDouble();

/// The backend's times are naive UTC ("2026-10-02T15:00:00"), which Dart
/// would read as local time; parsed here as UTC.
DateTime? _utc(dynamic v) {
  if (v is! String || v.isEmpty) return null;
  final hasZone = v.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(v);
  return DateTime.tryParse(hasZone ? v : '${v}Z');
}

/// A fresh X-Idempotency-Key: a double tap on a money button is one request.
String _idempotencyKey() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

void _snack(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(text),
    backgroundColor: error ? BrokaColors.danger : null,
  ));
}

ShapeBorder _dialogShape(Color color) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: color, width: 1),
    );

Widget _title(String emoji, String text) => Row(children: [
      Text(emoji, style: const TextStyle(fontSize: 18)),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text,
            style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
      ),
    ]);

Widget _note(String text, {Color color = BrokaColors.textLow}) =>
    Text(text, style: TextStyle(color: color, fontSize: 12, height: 1.35));

Widget _box(List<Widget> children, {Color border = BrokaColors.border}) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );

Widget _row(String label, double amount, {bool emphasize = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  color: emphasize ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontSize: emphasize ? 13 : 12,
                  fontWeight: emphasize ? FontWeight.w700 : FontWeight.normal)),
        ),
        Text(formatKes(amount),
            style: TextStyle(
                color: emphasize ? BrokaColors.neonGreen : BrokaColors.textMid,
                fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
                fontSize: emphasize ? 13 : 12)),
      ]),
    );

/// "Yes" / "No" for one question; null until answered.
class _YesNo extends StatelessWidget {
  final String question;
  final bool? value;
  final ValueChanged<bool> onChanged;
  const _YesNo({required this.question, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget choice(String label, bool v) => Expanded(
          child: ChoiceChip(
            label: Center(child: Text(label)),
            selected: value == v,
            onSelected: (_) => onChanged(v),
            selectedColor: v ? BrokaColors.neonGreen.withOpacity(0.25) : BrokaColors.danger.withOpacity(0.25),
            labelStyle: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700),
            backgroundColor: BrokaColors.bgCard,
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(question,
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Row(children: [choice('Yes', true), const SizedBox(width: 8), choice('No', false)]),
    ]);
  }
}

// ── Paying ──────────────────────────────────────────────────────────────────

/// Pay into escrow: the whole balance, or part of it now and the rest
/// later (a deal's price can be paid in several payments). Fetches a real
/// quote for whatever amount is entered - the total is never guessed here.
/// Returns true once the M-Pesa prompt is on its way and the payment screen
/// is open.
Future<bool> showEscrowPayDialog(
  BuildContext context, {
  required String dealId,
  String listingName = '',
  EscrowRepository? repository,
}) async {
  final repo = repository ?? escrowRepository;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator(color: BrokaColors.neonGreen)),
  );
  final first = await repo.feeQuote(dealId);
  if (!context.mounted) return false;
  Navigator.pop(context); // the spinner
  if (first is Failure<Map<String, dynamic>>) {
    _snack(context, first.message, error: true);
    return false;
  }
  var quote = first.data;
  final balance = _num(quote['balance']) ?? _num(quote['goods_amount']) ?? 0;
  final paid = _num(quote['amount_paid']) ?? 0;
  final price = _num(quote['agreed_price']) ?? balance;
  final minPart = _num(quote['min_part_payment']) ?? balance;
  final partsAllowed = minPart < balance;

  final amountCtrl = TextEditingController(text: balance.toStringAsFixed(0));
  final phoneCtrl = TextEditingController();
  final key = _idempotencyKey();
  var paying = false;
  var quoting = false;
  String? error;
  Timer? debounce;
  var opened = false;

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
      double? entered() => double.tryParse(amountCtrl.text.replaceAll(',', '').trim());

      void requote() {
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 600), () async {
          final a = entered();
          if (a == null || a <= 0) return;
          setDlg(() => quoting = true);
          final q = await repo.feeQuote(dealId, amount: a);
          if (!ctx.mounted) return;
          setDlg(() {
            quoting = false;
            if (q is Success<Map<String, dynamic>>) {
              quote = q.data;
              error = null;
            } else {
              error = (q as Failure<Map<String, dynamic>>).message;
            }
          });
        });
      }

      final goods = _num(quote['goods_amount']) ?? 0;
      final commission = _num(quote['merchant_commission']) ?? 0;
      final fee = _num(quote['provider_fee']) ?? 0;
      final total = _num(quote['total_to_pay']) ?? goods + commission + fee;

      return AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: _dialogShape(BrokaColors.neonGreen),
        title: _title('🔒', paid > 0 ? 'Add a payment' : 'Pay & Secure in Escrow'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (paid > 0) ...[
              _note('Paid so far: ${formatKes(paid)} of ${formatKes(price)}. Balance: ${formatKes(balance)}.',
                  color: BrokaColors.textMid),
              const SizedBox(height: 10),
            ],
            TextField(
              key: const Key('escrow-pay-amount'),
              controller: amountCtrl,
              enabled: partsAllowed && !paying,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: BrokaColors.textHigh),
              onChanged: (_) => requote(),
              decoration: InputDecoration(
                labelText: 'Amount to pay now (KES)',
                helperText: partsAllowed
                    ? 'Pay it all, or part now (at least ${formatKes(minPart)}) and the rest later.'
                    : null,
                helperMaxLines: 2,
                prefixIcon: const Icon(Icons.payments_outlined, color: BrokaColors.neonGreen, size: 20),
              ),
            ),
            const SizedBox(height: 12),
            _box([
              _row('Item price (this payment)', goods),
              _row('BROKA commission', commission),
              _row('Payment processing fee', fee),
              const Divider(color: BrokaColors.border, height: 16),
              _row(quoting ? 'Total to pay (updating...)' : 'Total to pay', total, emphasize: true),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: const InputDecoration(
                labelText: 'M-Pesa Phone',
                hintText: '07XXXXXXXX',
                prefixIcon: Icon(Icons.phone_android_rounded, color: BrokaColors.neonGreen, size: 20),
              ),
            ),
            const SizedBox(height: 10),
            _note('Your money is held in escrow until you release it to the seller.'),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ]),
        ),
        actions: [
          TextButton(
            onPressed: paying ? null : () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: BrokaColors.textLow)),
          ),
          ElevatedButton(
            onPressed: paying || quoting
                ? null
                : () async {
                    final phone = phoneCtrl.text.trim();
                    final amount = entered();
                    if (amount == null || amount <= 0) {
                      setDlg(() => error = 'Enter the amount to pay');
                      return;
                    }
                    if (phone.isEmpty) {
                      setDlg(() => error = 'Enter your phone number');
                      return;
                    }
                    setDlg(() {
                      paying = true;
                      error = null;
                    });
                    final r = await repo.fund(dealId,
                        payerPhone: phone,
                        amount: (amount - balance).abs() < 0.01 ? null : amount,
                        idempotencyKey: key);
                    if (r is Failure<Map<String, dynamic>>) {
                      setDlg(() {
                        paying = false;
                        error = r.message;
                      });
                      return;
                    }
                    final sent = r.data;
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      opened = true;
                      Navigator.pushNamed(context, '/escrow-payment', arguments: {
                        'deal_id': dealId,
                        'amount': _num(sent['total_to_pay']) ?? total,
                        'phone': phone,
                        'listing_name': listingName,
                      });
                    }
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.neonGreen,
              foregroundColor: Colors.black87,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: paying
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black87))
                : const Text('Pay', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      );
    }),
  );
  debounce?.cancel();
  return opened;
}

// ── Releasing ───────────────────────────────────────────────────────────────

/// The buyer releases the money to the seller, after saying whether the
/// item (and, for land or a vehicle, the ownership documents) reached them.
/// A "no" brings a recommendation to wait; the buyer can still go ahead.
/// Returns true when the release went through or is being finalised.
Future<bool> showReleaseDialog(
  BuildContext context, {
  required String dealId,
  required double amount,
  bool requiresOwnershipTransfer = false,
  EscrowRepository? repository,
}) async {
  final repo = repository ?? escrowRepository;
  bool? received;
  bool? transferred;
  var busy = false;
  String? error;
  var done = false;

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
      final answered = received != null && (!requiresOwnershipTransfer || transferred != null);
      final notYet = received == false || (requiresOwnershipTransfer && transferred == false);
      return AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: _dialogShape(BrokaColors.neonGreen),
        title: _title('✅', 'Release payment to the seller?'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _YesNo(
              question: 'Has the item been delivered to you?',
              value: received,
              onChanged: (v) => setDlg(() => received = v),
            ),
            if (requiresOwnershipTransfer) ...[
              const SizedBox(height: 12),
              _YesNo(
                question: 'Have the ownership documents (title deed, logbook) been transferred to you?',
                value: transferred,
                onChanged: (v) => setDlg(() => transferred = v),
              ),
            ],
            const SizedBox(height: 12),
            if (notYet)
              _box([
                _note(
                    'We recommend waiting until '
                    '${received == false ? 'you have the item' : 'the transfer is complete'} '
                    'before releasing. Once released, ${formatKes(amount)} goes to the seller and '
                    "can't be taken back through BROKA.",
                    color: BrokaColors.warning),
              ], border: BrokaColors.warning)
            else
              _note('${formatKes(amount)} will be paid to the seller. This cannot be undone.'),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ]),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(ctx),
            child: Text(notYet ? "I'll wait" : 'Cancel', style: const TextStyle(color: BrokaColors.textLow)),
          ),
          ElevatedButton(
            key: const Key('escrow-release-confirm'),
            onPressed: busy || !answered
                ? null
                : () async {
                    setDlg(() {
                      busy = true;
                      error = null;
                    });
                    final r = await repo.release(dealId,
                        itemReceived: received,
                        ownershipTransferred: requiresOwnershipTransfer ? transferred : null);
                    if (r is Failure<Map<String, dynamic>>) {
                      setDlg(() {
                        busy = false;
                        error = r.message;
                      });
                      return;
                    }
                    done = true;
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      final status = r.data['status'];
                      _snack(
                          context,
                          status == 'released'
                              ? 'Payment released to the seller.'
                              : (r.data['detail'] as String?) ?? 'Release requested - it will show shortly.');
                    }
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: notYet ? BrokaColors.warning : BrokaColors.neonGreen,
              foregroundColor: Colors.black87,
            ),
            child: Text(notYet ? 'Release anyway' : 'Release payment',
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      );
    }),
  );
  return done;
}

// ── Refund requests ─────────────────────────────────────────────────────────

const _refundReasons = [
  "The seller isn't responding",
  "The item hasn't arrived",
  "The item isn't what we agreed",
  'Something else',
];

/// The buyer asks for their money back. Before the seller has marked the
/// deal delivered, the seller has 48 hours to answer and silence refunds
/// the buyer; afterwards it opens a dispute instead.
Future<bool> showRefundRequestDialog(
  BuildContext context, {
  required String dealId,
  required double amount,
  bool sellerClaimedDelivery = false,
  EscrowRepository? repository,
}) async {
  final repo = repository ?? escrowRepository;
  String? reason;
  final detailCtrl = TextEditingController();
  final key = _idempotencyKey();
  var busy = false;
  String? error;
  var done = false;

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
      return AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: _dialogShape(BrokaColors.danger),
        title: _title('↩️', 'Ask for a refund'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _note(
              sellerClaimedDelivery
                  ? 'The seller says this was delivered, so a refund request opens a dispute. '
                      'The ${formatKes(amount)} stays in escrow until it is resolved.'
                  : "Zeno tells the seller right away (in the app and by SMS). They have 48 hours "
                      "to accept or explain. If they don't respond, you get your ${formatKes(amount)} "
                      'back automatically.',
              color: BrokaColors.textMid,
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in _refundReasons)
                ChoiceChip(
                  label: Text(r),
                  selected: reason == r,
                  onSelected: (_) => setDlg(() => reason = r),
                  selectedColor: BrokaColors.danger.withOpacity(0.25),
                  backgroundColor: BrokaColors.bgCard,
                  labelStyle: const TextStyle(color: BrokaColors.textHigh, fontSize: 12),
                ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: detailCtrl,
              maxLength: 300,
              maxLines: 2,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: const InputDecoration(labelText: 'Anything to add? (optional)'),
            ),
            if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: BrokaColors.textLow)),
          ),
          ElevatedButton(
            onPressed: busy || reason == null
                ? null
                : () async {
                    setDlg(() {
                      busy = true;
                      error = null;
                    });
                    final extra = detailCtrl.text.trim();
                    final text = extra.isEmpty ? reason! : '${reason!}: $extra';
                    final r = await repo.requestRefund(dealId, text, idempotencyKey: key);
                    if (r is Failure<Map<String, dynamic>>) {
                      setDlg(() {
                        busy = false;
                        error = r.message;
                      });
                      return;
                    }
                    done = true;
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      _snack(
                          context,
                          r.data['outcome'] == 'disputed'
                              ? 'Dispute opened - Zeno will help sort it out.'
                              : 'Refund requested - the seller has been told.');
                    }
                  },
            style: ElevatedButton.styleFrom(backgroundColor: BrokaColors.danger, foregroundColor: Colors.white),
            child: Text(sellerClaimedDelivery ? 'Open a dispute' : 'Request refund',
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      );
    }),
  );
  return done;
}

Future<bool> withdrawRefundRequest(BuildContext context, {required String dealId, EscrowRepository? repository}) async {
  final repo = repository ?? escrowRepository;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: BrokaColors.bgMid,
      title: const Text('Withdraw your refund request?', style: TextStyle(color: BrokaColors.textHigh)),
      content: _note('The deal carries on as before, and your money stays in escrow.', color: BrokaColors.textMid),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Withdraw')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final r = await repo.withdrawRefund(dealId);
  if (!context.mounted) return false;
  if (r is Failure<Map<String, dynamic>>) {
    _snack(context, r.message, error: true);
    return false;
  }
  _snack(context, 'Refund request withdrawn.');
  return true;
}

/// The seller answers the buyer's refund request: accept it, or contest it
/// (a dispute, with the money frozen until it is resolved).
Future<bool> showRefundResponseDialog(
  BuildContext context, {
  required String dealId,
  required double amount,
  String? reason,
  String? respondBy,
  EscrowRepository? repository,
}) async {
  final repo = repository ?? escrowRepository;
  final noteCtrl = TextEditingController();
  final key = _idempotencyKey();
  var busy = false;
  String? error;
  var done = false;
  final deadline = _utc(respondBy);
  final left = deadline?.difference(DateTime.now());

  Future<void> answer(BuildContext ctx, StateSetter setDlg, bool accept) async {
    setDlg(() {
      busy = true;
      error = null;
    });
    final r = await repo.respondToRefund(dealId, accept: accept, note: noteCtrl.text.trim(), idempotencyKey: key);
    if (r is Failure<Map<String, dynamic>>) {
      setDlg(() {
        busy = false;
        error = r.message;
      });
      return;
    }
    done = true;
    if (ctx.mounted) Navigator.pop(ctx);
    if (context.mounted) {
      _snack(context, accept ? 'Refund accepted - the buyer gets their money back.' : 'Dispute opened - Zeno will mediate.');
    }
  }

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
      return AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: _dialogShape(BrokaColors.warning),
        title: _title('↩️', 'The buyer wants a refund'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (reason != null && reason.isNotEmpty) ...[
              _note('"$reason"', color: BrokaColors.textHigh),
              const SizedBox(height: 8),
            ],
            _note(
              'Accept to return ${formatKes(amount)} to the buyer, or contest it if you have delivered '
              'or the buyer is wrong - that opens a dispute and the money stays in escrow.'
              '${left != null && !left.isNegative ? ' If you do nothing within about ${left.inHours} hours, the buyer is refunded automatically.' : ''}',
              color: BrokaColors.textMid,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: noteCtrl,
              maxLength: 300,
              maxLines: 2,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: const InputDecoration(labelText: 'Note for the record (optional)'),
            ),
            if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(ctx),
            child: const Text('Later', style: TextStyle(color: BrokaColors.textLow)),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => answer(ctx, setDlg, false),
            child: const Text('Contest'),
          ),
          ElevatedButton(
            onPressed: busy ? null : () => answer(ctx, setDlg, true),
            style: ElevatedButton.styleFrom(backgroundColor: BrokaColors.danger, foregroundColor: Colors.white),
            child: const Text('Accept refund', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      );
    }),
  );
  return done;
}

// ── Seller ──────────────────────────────────────────────────────────────────

/// The seller says the item was delivered. The buyer then has 3 days to
/// release or object; after that the money is released automatically.
/// [balance] is what the buyer has not paid yet: the automatic release pays
/// what is in escrow, so delivering before it is paid means accepting less.
Future<bool> markDealDelivered(BuildContext context,
    {required String dealId, double balance = 0, EscrowRepository? repository}) async {
  final repo = repository ?? escrowRepository;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: BrokaColors.bgMid,
      shape: _dialogShape(BrokaColors.gold),
      title: _title('📦', 'Mark as delivered?'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        _note(
          'Only do this once the buyer has the item (or the ownership documents). Zeno then asks the buyer '
          "to confirm. If they don't respond or report a problem within 3 days, the money is released "
          'to you automatically.',
          color: BrokaColors.textMid,
        ),
        if (balance > 0) ...[
          const SizedBox(height: 10),
          _box([
            _note(
                'The buyer still owes ${formatKes(balance)}. Only what is in escrow is released, so '
                'delivering now means accepting what has been paid unless they pay the rest.',
                color: BrokaColors.warning),
          ], border: BrokaColors.warning),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, delivered')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final r = await repo.markDelivered(dealId);
  if (!context.mounted) return false;
  if (r is Failure<Map<String, dynamic>>) {
    _snack(context, r.message, error: true);
    return false;
  }
  _snack(
      context,
      r.data['outcome'] == 'disputed'
          ? 'The buyer had asked for a refund, so this is now a dispute.'
          : 'Marked as delivered - the buyer has 3 days to confirm.');
  return true;
}

/// The seller states the price they agreed to, so a buyer who paid less
/// sees the balance. Never below what the buyer has already paid.
Future<bool> showSetPriceDialog(
  BuildContext context, {
  required String dealId,
  required double currentPrice,
  double amountPaid = 0,
  EscrowRepository? repository,
}) async {
  final repo = repository ?? escrowRepository;
  final ctrl = TextEditingController(text: currentPrice.toStringAsFixed(0));
  var busy = false;
  String? error;
  var done = false;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
      return AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: _dialogShape(BrokaColors.gold),
        title: _title('🏷️', 'Confirm the agreed price'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _note(
            amountPaid > 0
                ? 'The buyer has paid ${formatKes(amountPaid)} so far. Enter the full price you agreed; '
                    'the buyer will be asked to pay the balance.'
                : 'Enter the full price you agreed with the buyer.',
            color: BrokaColors.textMid,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(labelText: 'Agreed price (KES)'),
          ),
          if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: busy
                ? null
                : () async {
                    final price = double.tryParse(ctrl.text.replaceAll(',', '').trim());
                    if (price == null || price <= 0) {
                      setDlg(() => error = 'Enter the price');
                      return;
                    }
                    setDlg(() {
                      busy = true;
                      error = null;
                    });
                    final r = await repo.setPrice(dealId, price);
                    if (r is Failure<Map<String, dynamic>>) {
                      setDlg(() {
                        busy = false;
                        error = r.message;
                      });
                      return;
                    }
                    done = true;
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) _snack(context, 'Price confirmed - the buyer has been told.');
                  },
            child: const Text('Confirm'),
          ),
        ],
      );
    }),
  );
  return done;
}

/// "Paid 30,000 of 100,000" / "Released in 2 days" lines for a deal's
/// status, from the protection fields every deal response carries.
String? escrowSummary(Map<String, dynamic> deal, {required bool isBuyer}) {
  final paid = _num(deal['amount_paid']);
  final balance = _num(deal['balance']) ?? 0;
  final price = _num(deal['agreed_price']);
  final parts = <String>[];
  if (paid != null && price != null && balance > 0) {
    parts.add('Paid ${formatKes(paid)} of ${formatKes(price)}');
  }
  final releaseAt = _utc(deal['auto_release_at']);
  if (releaseAt != null) {
    final left = releaseAt.difference(DateTime.now());
    final when = left.inHours >= 24 ? '${(left.inHours / 24).ceil()} day(s)' : '${max(left.inHours, 1)} hour(s)';
    parts.add(isBuyer
        ? 'Released to the seller automatically in about $when unless you report a problem'
        : 'Paid to you automatically in about $when if the buyer stays silent');
  }
  return parts.isEmpty ? null : parts.join(' · ');
}
