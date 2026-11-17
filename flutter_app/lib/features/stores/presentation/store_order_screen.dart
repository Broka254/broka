// One store order, opened from My Store's Orders tab or from its push:
// where it is, what the buyer asked for and what the store offers, how it
// is handed over, the payment record, and everything that happened.
//
// Every button is an action the API says the order allows now
// (allowed_actions), and each asks first, saying what it does. The API
// decides again when it is sent, and the screen shows the order it answers
// with; a refusal (the buyer cancelled meanwhile, an offer lapsed, stock ran
// short) is shown in the server's words and the order is read again.
//
// The same screen serves a buyer who opens their order in the app: the
// actions are theirs then. Choosing how to pay - directly, or through an
// independent escrow service from BROKA's directory - is on the order's
// page on the web.
//
// BROKA records what each side reports about paying and never receives,
// holds or checks the money, so every payment line here says who reported
// it and that BROKA did not verify it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../../../utils/price_format.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store_order.dart';

/// The most of one product a store may offer (backend pricing.MAX_QUANTITY).
const _maxQuantity = 1000;

class StoreOrderScreen extends StatefulWidget {
  const StoreOrderScreen({super.key, required this.orderId, this.repo});

  final String orderId;
  final StoresRepository? repo;

  @override
  State<StoreOrderScreen> createState() => _StoreOrderScreenState();
}

class _StoreOrderScreenState extends State<StoreOrderScreen> {
  StoresRepository get _repo => widget.repo ?? storesRepository;

  StoreOrder? _order;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // Opening the order is reading its updates. Best-effort.
    unawaited(_repo.markOrderUpdatesRead(widget.orderId));
  }

  Future<void> _load() async {
    final result = await _repo.getOrder(widget.orderId);
    if (!mounted) return;
    setState(() {
      switch (result) {
        case Success(:final data):
          _order = data;
          _error = null;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  /// Sends one action and shows the order the server answers with.
  Future<void> _run(Future<Result<StoreOrder>> Function() send, String done) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final result = await send();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result) {
      case Success(:final data):
        setState(() {
          _order = data;
          _busy = false;
        });
        messenger.showSnackBar(SnackBar(content: Text(done)));
      case Failure(:final message):
        setState(() => _busy = false);
        messenger.showSnackBar(SnackBar(content: Text(message)));
        // The order may have moved on meanwhile: show it as it is now.
        await _load();
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String yes,
    bool danger = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        title: Text(title, style: const TextStyle(color: BrokaColors.textHigh)),
        content: Text(body, style: const TextStyle(color: BrokaColors.textMid, height: 1.45)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not now')),
          TextButton(
            key: const Key('order-confirm-yes'),
            onPressed: () => Navigator.pop(d, true),
            child: Text(yes,
                style: TextStyle(
                    color: danger ? BrokaColors.danger : BrokaColors.gold,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// A line of text before an action: null when the person backed out.
  Future<String?> _ask({
    required String title,
    required String body,
    required String label,
    required String yes,
    bool mustAnswer = false,
    int minLength = 3,
    int maxLength = 300,
    String problem = 'Say why, in a few words - the buyer will see it.',
    bool danger = false,
  }) =>
      showDialog<String>(
        context: context,
        builder: (_) => _TextPrompt(
          title: title,
          body: body,
          label: label,
          yes: yes,
          mustAnswer: mustAnswer,
          minLength: minLength,
          maxLength: maxLength,
          problem: problem,
          danger: danger,
        ),
      );

  Future<void> _act(StoreOrderAction action) async {
    final o = _order;
    if (o == null || _busy) return;
    final total = formatMinorKes(o.displayTotalMinor);
    switch (action) {
      case StoreOrderAction.accept:
        final answer = await showDialog<_AcceptAnswer>(
            context: context, builder: (_) => _AcceptDialog(order: o));
        if (answer == null || !mounted) return;
        await _run(
            () => _repo.acceptOrder(o.id,
                deliveryFeeMinor: answer.deliveryFeeMinor, sellerNote: answer.note),
            'Accepted. The buyer confirms the final details next.');
      case StoreOrderAction.propose:
        final proposal = await Navigator.of(context)
            .push<_Proposal>(MaterialPageRoute(builder: (_) => _ProposeScreen(order: o)));
        if (proposal == null || !mounted) return;
        await _run(
            () => _repo.proposeOrderChanges(o.id,
                items: proposal.items,
                fulfilment: proposal.fulfilment,
                deliveryFeeMinor: proposal.deliveryFeeMinor,
                sellerNote: proposal.note),
            'Changes sent. The buyer reviews them next.');
      case StoreOrderAction.decline:
        final reason = await _ask(
          title: 'Decline this order?',
          body: 'The request ends and the buyer is told at once, with your reason.',
          label: 'Why (the buyer sees this)',
          yes: 'Decline order',
          mustAnswer: true,
          danger: true,
        );
        if (reason == null || !mounted) return;
        await _run(() => _repo.declineOrder(o.id, reason), 'Order declined.');
      case StoreOrderAction.startPreparing:
        if (!await _confirm(
          title: 'Start preparing?',
          body: 'The buyer sees that you are preparing their order. From now on only you '
              'can cancel it, with a reason.',
          yes: 'Start preparing',
        )) return;
        await _run(() => _repo.startPreparingOrder(o.id), 'Marked as being prepared.');
      case StoreOrderAction.markReady:
        final note = await _ask(
          title: 'Ready for collection?',
          body: 'The buyer is told it is ready. Say where and when to collect it, if you like.',
          label: 'Collection details (optional)',
          yes: 'Mark ready',
        );
        if (note == null || !mounted) return;
        await _run(() => _repo.markOrderReady(o.id, note: note), 'The buyer has been told it is ready.');
      case StoreOrderAction.dispatch:
        final note = await _ask(
          title: 'Dispatch this order?',
          body: 'The buyer is told it is on its way. Add who is delivering it and when, if you like.',
          label: 'Delivery details (optional)',
          yes: 'Dispatch',
        );
        if (note == null || !mounted) return;
        await _run(() => _repo.dispatchOrder(o.id, note: note), 'Marked as on its way.');
      case StoreOrderAction.markDelivered:
        if (!await _confirm(
          title: 'Report it delivered?',
          body: 'Only once the buyer has it. The buyer then confirms they received it, which '
              'completes the order.',
          yes: 'Report delivered',
        )) return;
        await _run(() => _repo.markOrderDelivered(o.id), 'Reported delivered.');
      case StoreOrderAction.cancel:
        final reason = await _ask(
          title: 'Cancel this order?',
          body: o.isSeller
              ? 'The buyer is told at once, with your reason. Anything set aside for them is released.'
              : "The order ends and can't be reopened. Anything the store set aside for you is released.",
          label: o.isSeller ? 'Why (the buyer sees this)' : 'Tell the store why (optional)',
          yes: 'Cancel order',
          mustAnswer: o.isSeller,
          danger: true,
        );
        if (reason == null || !mounted) return;
        await _run(() => _repo.cancelOrder(o.id, reason: reason), 'Order cancelled.');
      case StoreOrderAction.confirm:
        if (!await _confirm(
          title: 'Confirm this order?',
          body: 'You agree to buy it for $total'
              '${o.isDelivery ? ', delivered' : ', collected from the store'}. The store then '
              "prepares it. Payment is between you and the store - BROKA doesn't take it.",
          yes: 'Confirm order',
        )) return;
        await _run(() => _repo.confirmOrder(o.id, o.revision), 'Confirmed. The store prepares it next.');
      case StoreOrderAction.rejectProposal:
        final note = await _ask(
          title: "Reject the store's changes?",
          body: 'Your request goes back to the store as you sent it.',
          label: 'Tell the store why (optional)',
          yes: 'Reject the changes',
          danger: true,
        );
        if (note == null || !mounted) return;
        await _run(() => _repo.rejectOrderProposal(o.id, note: note), 'Sent back to the store.');
      case StoreOrderAction.confirmReceived:
        if (!await _confirm(
          title: 'Did you receive everything?',
          body: 'Confirm only once you have it and it is as agreed. This completes the order.',
          yes: 'Yes, I have it',
        )) return;
        await _run(() => _repo.confirmOrderReceived(o.id), 'Order completed.');
      case StoreOrderAction.reportProblem:
        final note = await _ask(
          title: 'Report a problem',
          body: 'The store is told at once. Say what is wrong.',
          label: 'What went wrong',
          yes: 'Send to the store',
          mustAnswer: true,
          minLength: 5,
          maxLength: 500,
          problem: 'Say what went wrong, in a few words.',
        );
        if (note == null || !mounted) return;
        await _run(() => _repo.reportOrderProblem(o.id, note), 'The store has been told.');
    }
  }

  Future<void> _reportPayment(StoreOrder o, String kind) async {
    final copy = _reportCopy(kind);
    final reference = await _ask(
      title: copy.title,
      body: copy.body,
      label: 'Reference (optional) - never a PIN or password',
      yes: 'Record it',
      maxLength: 64,
    );
    if (reference == null || !mounted) return;
    await _run(
        () => _repo.reportOrderPayment(o.id, kind: kind, reference: reference),
        'Recorded. It shows on the order as your report.');
  }

  Future<void> _openOnWeb(StoreOrder o) async {
    // The storefront's own site (the store link's origin), where the order
    // has its page: broka.co.ke/store/orders/<id>.
    var origin = 'https://broka.co.ke';
    final base = o.storeUrl == null ? null : Uri.tryParse(o.storeUrl!);
    if (base != null && (base.scheme == 'https' || base.scheme == 'http') && base.host.isNotEmpty) {
      origin = base.origin;
    }
    final uri = Uri.parse('$origin/store/orders/${Uri.encodeComponent(o.id)}');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Open ${uri.toString()} in your browser.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
        title: Text(o == null || o.reference.isEmpty ? 'Order' : 'Order ${o.reference}',
            style: const TextStyle(
                color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 17)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _busy ? null : _load,
          ),
        ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2, color: BrokaColors.gold),
              )
            : null,
      ),
      body: o == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: BrokaColors.gold)
                  : Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error!,
                            key: const Key('order-load-error'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: BrokaColors.textMid)),
                        TextButton(onPressed: _load, child: const Text('Try again')),
                      ]),
                    ),
            )
          : RefreshIndicator(
              color: BrokaColors.gold,
              onRefresh: _load,
              child: ListView(
                key: const Key('store-order-view'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  _statusCard(o),
                  if (o.allowedActions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _actions(o),
                  ],
                  const SizedBox(height: 16),
                  _section('What was ordered', _items(o)),
                  _section(o.isDelivery ? 'Delivery' : 'Collection', _handover(o)),
                  if (!o.status.endedWithoutSale) _section('Payment', _payment(o)),
                  _section('History', _history(o)),
                ],
              ),
            ),
    );
  }

  Widget _statusCard(StoreOrder o) {
    final deadline = _deadline(o);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(o.statusLabel,
            key: const Key('order-status-label'),
            style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          [
            if (o.isSeller && o.buyerName != null) 'From ${o.buyerName}',
            if (!o.isSeller && o.storeName != null) o.storeName!,
            if (o.createdAt != null) 'sent ${formatOrderWhen(o.createdAt)}',
          ].join(' · '),
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5),
        ),
        if (o.isSeller && (o.source != null || o.campaignTitle != null)) ...[
          const SizedBox(height: 2),
          Text(
            o.campaignTitle != null
                ? 'Came through your campaign "${o.campaignTitle}"'
                : 'Came from ${o.source}',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12),
          ),
        ],
        if (deadline != null) ...[
          const SizedBox(height: 8),
          Text(deadline,
              key: const Key('order-deadline'),
              style: const TextStyle(color: BrokaColors.warning, fontSize: 12.5, height: 1.4)),
        ],
        if (o.status == StoreOrderStatus.sellerProposedChanges && !o.isSeller) ...[
          const SizedBox(height: 8),
          const Text(
            'The store changed your order. Check every line below - nothing goes ahead '
            'unless you confirm the new details.',
            style: TextStyle(color: BrokaColors.warning, fontSize: 12.5, height: 1.4),
          ),
        ],
        if (o.declineReason != null) _reasonLine('Declined', o.declineReason!),
        if (o.cancelReason != null)
          _reasonLine(
              o.cancelledBy == 'seller'
                  ? (o.isSeller ? 'You cancelled' : 'The store cancelled')
                  : (o.isSeller ? 'The buyer cancelled' : 'You cancelled'),
              o.cancelReason!),
        if (o.problemNote != null)
          _reasonLine(
              o.isSeller ? 'The buyer reported a problem' : 'You reported a problem', o.problemNote!),
        if (o.sellerNote != null)
          _reasonLine(o.isSeller ? 'Your note to the buyer' : 'From the store', o.sellerNote!),
      ]),
    );
  }

  Widget _reasonLine(String label, String text) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('$label: $text',
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, height: 1.4)),
      );

  String? _deadline(StoreOrder o) {
    final at = o.expiresAt;
    if (at == null) return null;
    final when = formatOrderWhen(at);
    return switch (o.expiryStage) {
      'seller_response' => o.isSeller
          ? 'Answer by $when, or the request expires and the buyer moves on.'
          : 'The store has until $when to answer.',
      'buyer_confirmation' => o.isSeller
          ? "The buyer has until $when to confirm. Anything you set aside is released if they don't."
          : 'Confirm by $when, or the offer lapses.',
      _ => null,
    };
  }

  /// The order's actions, in the order a person takes them.
  Widget _actions(StoreOrder o) {
    const order = [
      StoreOrderAction.accept,
      StoreOrderAction.confirm,
      StoreOrderAction.startPreparing,
      StoreOrderAction.markReady,
      StoreOrderAction.dispatch,
      StoreOrderAction.markDelivered,
      StoreOrderAction.confirmReceived,
      StoreOrderAction.propose,
      StoreOrderAction.rejectProposal,
      StoreOrderAction.reportProblem,
      StoreOrderAction.decline,
      StoreOrderAction.cancel,
    ];
    final actions = [for (final a in order) if (o.can(a)) a];
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (var i = 0; i < actions.length; i++)
        _actionButton(o, actions[i], primary: i == 0),
    ]);
  }

  Widget _actionButton(StoreOrder o, StoreOrderAction action, {required bool primary}) {
    final label = switch (action) {
      StoreOrderAction.accept => 'Accept order',
      StoreOrderAction.propose => 'Propose changes',
      StoreOrderAction.decline => 'Decline',
      StoreOrderAction.startPreparing => 'Start preparing',
      StoreOrderAction.markReady => 'Ready for collection',
      StoreOrderAction.dispatch => 'Dispatch',
      StoreOrderAction.markDelivered => 'Report delivered',
      StoreOrderAction.cancel => 'Cancel order',
      StoreOrderAction.confirm => 'Confirm order - ${formatMinorKes(o.displayTotalMinor)}',
      StoreOrderAction.rejectProposal => 'Reject the changes',
      StoreOrderAction.confirmReceived => 'I received it',
      StoreOrderAction.reportProblem => 'Report a problem',
    };
    final key = Key('order-action-${action.value}');
    final onPressed = _busy ? null : () => _act(action);
    final danger = action == StoreOrderAction.decline || action == StoreOrderAction.cancel;
    if (danger) {
      return TextButton(
        key: key,
        onPressed: onPressed,
        style: TextButton.styleFrom(foregroundColor: BrokaColors.danger),
        child: Text(label),
      );
    }
    if (primary) {
      return FilledButton(
        key: key,
        onPressed: onPressed,
        style: FilledButton.styleFrom(backgroundColor: BrokaColors.gold, foregroundColor: Colors.black),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      );
    }
    return OutlinedButton(
      key: key,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: BrokaColors.textHigh,
        side: const BorderSide(color: BrokaColors.border),
      ),
      child: Text(label),
    );
  }

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.6),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 14.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );

  List<Widget> _items(StoreOrder o) {
    final delivery = o.isDelivery
        ? (o.deliveryFeeMinor != null
            ? formatMinorKes(o.deliveryFeeMinor)
            : o.totalMinor != null
                ? 'No charge'
                : 'To be confirmed by the store')
        : 'Collection';
    final totalLabel = o.isFinal
        ? 'Agreed total'
        : o.totalMinor != null
            ? (o.isSeller ? 'Your offer' : "The store's total")
            : 'At listed prices';
    return [
      for (final i in o.items) _itemRow(o, i),
      const Divider(color: BrokaColors.border, height: 20),
      _amountRow(o.sellerSubtotalMinor != null ? 'Subtotal' : 'Subtotal at listed prices',
          formatMinorKes(o.sellerSubtotalMinor ?? o.requestedSubtotalMinor)),
      _amountRow('Delivery', delivery),
      _amountRow(totalLabel, formatMinorKes(o.displayTotalMinor),
          strong: true, key: const Key('order-total')),
      if (!o.isFinal && !o.status.endedWithoutSale)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Not final until the buyer confirms the details.',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        ),
    ];
  }

  Widget _itemRow(StoreOrder o, StoreOrderItem i) {
    final quantity = i.quantityChanged
        ? 'Asked for ${i.requestedQuantity}, offered ${i.quantity}'
        : '${i.quantity}';
    final price = i.priceChanged
        ? '${formatMinorKes(i.requestedUnitPriceMinor)} → ${formatMinorKes(i.unitPriceMinor)}'
        : formatMinorKes(i.unitPriceMinor);
    return Padding(
      key: Key('order-item-${i.id}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(i.name,
                style: const TextStyle(
                    color: BrokaColors.textHigh, fontWeight: FontWeight.w600, fontSize: 13.5)),
            const SizedBox(height: 2),
            if (i.removed)
              const Text("Not available - the store can't supply it",
                  style: TextStyle(color: BrokaColors.danger, fontSize: 12))
            else
              Text('$quantity × $price${i.priceUnit != null ? ' / ${i.priceUnit}' : ''}',
                  style: TextStyle(
                      color: i.changed ? BrokaColors.warning : BrokaColors.textMid, fontSize: 12)),
            if (o.isSeller && i.stockTracked)
              Text(
                'Stock: ${i.stockOnHand ?? 0} on hand, ${i.stockAvailable ?? 0} free to order'
                '${i.reservedQuantity > 0 ? ', ${i.reservedQuantity} set aside for this order' : ''}',
                style: const TextStyle(color: BrokaColors.textLow, fontSize: 11.5),
              ),
          ]),
        ),
        const SizedBox(width: 10),
        Text(formatMinorKes(i.lineTotalMinor),
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _amountRow(String label, String value, {bool strong = false, Key? key}) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            flex: 3,
            child: Text(label,
                style: TextStyle(
                    color: strong ? BrokaColors.textHigh : BrokaColors.textMid,
                    fontWeight: strong ? FontWeight.w800 : FontWeight.w500)),
          ),
          const SizedBox(width: 12),
          // A long value ("To be confirmed by the store") wraps under itself
          // rather than pushing the label off a narrow phone or large text.
          Flexible(
            flex: 2,
            child: Text(value,
                key: key,
                textAlign: TextAlign.right,
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontWeight: strong ? FontWeight.w800 : FontWeight.w600)),
          ),
        ]),
      );

  List<Widget> _handover(StoreOrder o) {
    const style = TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4);
    return [
      if (o.fulfilment != o.requestedFulfilment)
        Text(
            'The buyer asked for ${o.requestedFulfilment}; the store offers ${o.fulfilment}.',
            style: const TextStyle(color: BrokaColors.warning, fontSize: 12.5)),
      if (o.address != null) Text('To: ${o.address}', style: style),
      if (o.contactPhone != null) Text('Phone: ${o.contactPhone}', style: style),
      if (o.buyerNote != null) Text("Buyer's note: ${o.buyerNote}", style: style),
      if (o.fulfilmentNote != null) Text('Handover: ${o.fulfilmentNote}', style: style),
      if (o.dispatchNote != null) Text('Dispatch: ${o.dispatchNote}', style: style),
      if (o.address == null &&
          o.contactPhone == null &&
          o.buyerNote == null &&
          o.fulfilmentNote == null &&
          o.dispatchNote == null)
        Text(o.isDelivery ? 'No details yet.' : 'Collected from the store.', style: style),
    ];
  }

  List<Widget> _payment(StoreOrder o) {
    final p = o.payment;
    const small = TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4);
    return [
      if (p.notice.isNotEmpty) Text(p.notice, key: const Key('order-payment-notice'), style: small),
      const SizedBox(height: 8),
      if (p.arrangementLabel != null)
        Text(
          p.providerName != null ? '${p.arrangementLabel} - ${p.providerName}' : p.arrangementLabel!,
          style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700),
        )
      else
        Text(
            o.isSeller
                ? 'The buyer has not said how they will pay yet.'
                : 'You have not chosen how to pay yet.',
            style: small),
      if (p.providerNotice != null) ...[
        const SizedBox(height: 4),
        Text(p.providerNotice!, style: small),
      ],
      if (p.providerDomain != null) ...[
        const SizedBox(height: 2),
        Text("Its official website: ${p.providerDomain}", style: small),
      ],
      if (p.summaryLabel.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          p.statusNote != null ? '${p.summaryLabel} · ${p.statusNote}' : p.summaryLabel,
          key: const Key('order-payment-summary'),
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5),
        ),
      ],
      for (final r in p.reports)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.label,
                style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w600)),
            Text(
              [
                _reportedBy(o, r),
                if (r.createdAt != null) formatOrderWhen(r.createdAt),
                'not verified by BROKA',
                if (r.reference != null) 'reference ${r.reference}',
              ].join(' · '),
              style: small,
            ),
          ]),
        ),
      if (p.allowedReports.isNotEmpty) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final kind in p.allowedReports)
            OutlinedButton(
              key: Key('order-report-$kind'),
              onPressed: _busy ? null : () => _reportPayment(o, kind),
              style: OutlinedButton.styleFrom(
                foregroundColor: BrokaColors.textHigh,
                side: const BorderSide(color: BrokaColors.border),
              ),
              child: Text(_reportCopy(kind).button),
            ),
        ]),
      ],
      if (!o.isSeller && p.arrangement == null && o.open) ...[
        const SizedBox(height: 10),
        const Text(
          "Choose how you pay - directly, or through an independent escrow service - on this "
          "order's page on the web.",
          style: small,
        ),
        TextButton(
          key: const Key('order-open-web'),
          onPressed: () => _openOnWeb(o),
          child: const Text('Open the order on the web'),
        ),
      ],
    ];
  }

  String _reportedBy(StoreOrder o, StoreOrderPaymentReport r) {
    final mine = (r.actorRole == 'seller') == o.isSeller;
    if (mine) return 'Reported by you';
    return r.actorRole == 'seller' ? 'Reported by the store' : 'Reported by the buyer';
  }

  List<Widget> _history(StoreOrder o) => [
        for (final e in o.events.reversed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.label,
                  style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w600)),
              if (e.note != null)
                Text(e.note!, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
              Text(formatOrderWhen(e.createdAt),
                  style: const TextStyle(color: BrokaColors.textLow, fontSize: 11.5)),
            ]),
          ),
        if (o.events.isEmpty)
          const Text('Nothing yet.', style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
      ];
}

/// What each payment report is called and what recording it means.
({String button, String title, String body}) _reportCopy(String kind) => switch (kind) {
      'seller_confirmed_receipt' => (
          button: 'I received the payment',
          title: 'Record that you received the payment?',
          body: 'Only once the money is in your M-Pesa, bank account or till. It shows on the '
              'order as your report; BROKA does not see or verify payments.',
        ),
      'seller_reported_escrow_release' => (
          button: 'The escrow service paid me',
          title: 'Record that the escrow service released the payment?',
          body: 'Only once the independent escrow service has paid you. It shows on the order '
              'as your report; BROKA does not see or verify payments.',
        ),
      'buyer_reported_payment_sent' => (
          button: 'I paid the store',
          title: 'Record that you paid the store?',
          body: 'It tells the store what you did and shows on the order as your report. BROKA '
              'does not see or verify payments.',
        ),
      'buyer_reported_escrow_initiated' => (
          button: 'I started the escrow payment',
          title: 'Record that you paid into the escrow service?',
          body: 'It tells the store what you did and shows on the order as your report. The '
              'escrow service is independent of BROKA, and BROKA does not see or verify payments.',
        ),
      _ => (
          button: 'Record a payment',
          title: 'Record a payment?',
          body: 'It shows on the order as your report. BROKA does not see or verify payments.',
        ),
    };

/// A dialog with one text field: the text ('' when left empty), or null.
class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.body,
    required this.label,
    required this.yes,
    required this.mustAnswer,
    required this.minLength,
    required this.maxLength,
    required this.problem,
    required this.danger,
  });

  final String title;
  final String body;
  final String label;
  final String yes;
  final bool mustAnswer;
  final int minLength;
  final int maxLength;
  final String problem;
  final bool danger;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  final _text = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _text.text.trim();
    if (widget.mustAnswer && value.length < widget.minLength) {
      setState(() => _problem = widget.problem);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        scrollable: true,
        title: Text(widget.title, style: const TextStyle(color: BrokaColors.textHigh)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.body, style: const TextStyle(color: BrokaColors.textMid, height: 1.45)),
            const SizedBox(height: 12),
            TextField(
              key: const Key('order-prompt-field'),
              controller: _text,
              maxLength: widget.maxLength,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: InputDecoration(labelText: widget.label, errorText: _problem),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
          TextButton(
            key: const Key('order-prompt-yes'),
            onPressed: _submit,
            child: Text(widget.yes,
                style: TextStyle(
                    color: widget.danger ? BrokaColors.danger : BrokaColors.gold,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      );
}

class _AcceptAnswer {
  const _AcceptAnswer({this.deliveryFeeMinor, this.note});
  final int? deliveryFeeMinor;
  final String? note;
}

/// Accepting as the buyer asked: an optional delivery charge and note.
class _AcceptDialog extends StatefulWidget {
  const _AcceptDialog({required this.order});
  final StoreOrder order;

  @override
  State<_AcceptDialog> createState() => _AcceptDialogState();
}

class _AcceptDialogState extends State<_AcceptDialog> {
  final _fee = TextEditingController();
  final _note = TextEditingController();
  String? _feeProblem;

  @override
  void dispose() {
    _fee.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    int? fee;
    final raw = _fee.text.trim();
    if (widget.order.isDelivery && raw.isNotEmpty) {
      final kes = parseKesInput(raw);
      if (kes == null || kes < 0) {
        setState(() => _feeProblem = 'Enter the delivery charge in shillings, or leave it empty.');
        return;
      }
      fee = (kes * 100).round();
    }
    Navigator.pop(context, _AcceptAnswer(deliveryFeeMinor: fee, note: _note.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    return AlertDialog(
      backgroundColor: BrokaColors.bgMid,
      scrollable: true,
      title: const Text('Accept this order?', style: TextStyle(color: BrokaColors.textHigh)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You can supply everything as the buyer asked, for '
            '${formatMinorKes(o.requestedSubtotalMinor)}'
            '${o.isDelivery ? ' plus any delivery charge' : ''}. The buyer confirms the final '
            'details next, and stock you count is set aside for them meanwhile.',
            style: const TextStyle(color: BrokaColors.textMid, height: 1.45),
          ),
          if (o.isDelivery) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('accept-delivery-fee'),
              controller: _fee,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: InputDecoration(
                labelText: 'Delivery charge in KES (optional)',
                errorText: _feeProblem,
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const Key('accept-note'),
            controller: _note,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(labelText: 'Note to the buyer (optional)'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
        TextButton(
          key: const Key('accept-yes'),
          onPressed: _submit,
          child: const Text('Accept order',
              style: TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

class _Proposal {
  const _Proposal({required this.items, this.fulfilment, this.deliveryFeeMinor, this.note});
  final List<ProposedOrderItem> items;
  final String? fulfilment;
  final int? deliveryFeeMinor;
  final String? note;
}

/// The store's changes: quantities (0 = can't supply), prices, how it is
/// handed over, a delivery charge and a note. The buyer must accept them.
class _ProposeScreen extends StatefulWidget {
  const _ProposeScreen({required this.order});
  final StoreOrder order;

  @override
  State<_ProposeScreen> createState() => _ProposeScreenState();
}

class _ProposeScreenState extends State<_ProposeScreen> {
  late final List<int> _quantities = [for (final i in widget.order.items) i.quantity];
  late final List<TextEditingController> _prices = [
    for (final i in widget.order.items) TextEditingController(text: _shillings(i.unitPriceMinor)),
  ];
  late String _fulfilment = widget.order.fulfilment;
  final _fee = TextEditingController();
  final _note = TextEditingController();
  String? _problem;

  static String _shillings(int minor) =>
      minor % 100 == 0 ? '${minor ~/ 100}' : (minor / 100).toStringAsFixed(2);

  @override
  void dispose() {
    for (final c in _prices) {
      c.dispose();
    }
    _fee.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final order = widget.order;
    final items = <ProposedOrderItem>[];
    for (var i = 0; i < order.items.length; i++) {
      final kes = parseKesInput(_prices[i].text);
      if (kes == null || kes <= 0) {
        setState(() => _problem = 'Give every product a price in shillings.');
        return;
      }
      items.add(ProposedOrderItem(
        itemId: order.items[i].id,
        quantity: _quantities[i],
        unitPriceMinor: (kes * 100).round(),
      ));
    }
    if (items.every((i) => i.quantity == 0)) {
      setState(() => _problem = 'Keep at least one product, or decline the order instead.');
      return;
    }
    int? fee;
    if (_fulfilment == 'delivery' && _fee.text.trim().isNotEmpty) {
      final kes = parseKesInput(_fee.text);
      if (kes == null || kes < 0) {
        setState(() => _problem = 'Enter the delivery charge in shillings, or leave it empty.');
        return;
      }
      fee = (kes * 100).round();
    }
    Navigator.pop(
      context,
      _Proposal(
        items: items,
        fulfilment: _fulfilment == order.fulfilment ? null : _fulfilment,
        deliveryFeeMinor: fee,
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    // Delivery needs an address the buyer gave; collection is always possible.
    final canDeliver = order.address != null;
    const hint = TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
        title: const Text('Propose changes',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 17)),
      ),
      body: ListView(
        key: const Key('propose-list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const Text(
            "Change what you can supply. The buyer sees every change and must accept it "
            'before anything goes ahead. Set a quantity to 0 for a product you can\'t supply.',
            style: hint,
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < order.items.length; i++)
            Padding(
              key: Key('propose-item-${order.items[i].id}'),
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(order.items[i].name,
                    style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
                Text('The buyer asked for ${order.items[i].requestedQuantity} at '
                    '${formatMinorKes(order.items[i].requestedUnitPriceMinor)}', style: hint),
                Row(children: [
                  IconButton(
                    key: Key('propose-less-${order.items[i].id}'),
                    tooltip: 'One fewer',
                    icon: const Icon(Icons.remove_circle_outline_rounded, color: BrokaColors.textMid),
                    onPressed: _quantities[i] > 0 ? () => setState(() => _quantities[i] -= 1) : null,
                  ),
                  Text('${_quantities[i]}',
                      key: Key('propose-qty-${order.items[i].id}'),
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
                  IconButton(
                    key: Key('propose-more-${order.items[i].id}'),
                    tooltip: 'One more',
                    icon: const Icon(Icons.add_circle_outline_rounded, color: BrokaColors.textMid),
                    onPressed:
                        _quantities[i] < _maxQuantity ? () => setState(() => _quantities[i] += 1) : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: Key('propose-price-${order.items[i].id}'),
                      controller: _prices[i],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: BrokaColors.textHigh),
                      decoration: const InputDecoration(labelText: 'Price each, KES'),
                    ),
                  ),
                ]),
              ]),
            ),
          const Text('How the buyer gets it',
              style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            ChoiceChip(
              key: const Key('propose-delivery'),
              label: const Text('Delivery'),
              selected: _fulfilment == 'delivery',
              onSelected: canDeliver ? (_) => setState(() => _fulfilment = 'delivery') : null,
            ),
            ChoiceChip(
              key: const Key('propose-collection'),
              label: const Text('Collection'),
              selected: _fulfilment == 'collection',
              onSelected: (_) => setState(() => _fulfilment = 'collection'),
            ),
          ]),
          if (!canDeliver)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('The buyer gave no delivery address, so this order is collected.',
                  style: hint),
            ),
          if (_fulfilment == 'delivery') ...[
            const SizedBox(height: 10),
            TextField(
              key: const Key('propose-delivery-fee'),
              controller: _fee,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: const InputDecoration(labelText: 'Delivery charge in KES (optional)'),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            key: const Key('propose-note'),
            controller: _note,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(labelText: 'Note to the buyer (optional)'),
          ),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_problem!,
                  key: const Key('propose-problem'),
                  style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5)),
            ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('propose-send'),
            onPressed: _submit,
            style: FilledButton.styleFrom(backgroundColor: BrokaColors.gold, foregroundColor: Colors.black),
            child: const Text('Send the changes to the buyer',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
