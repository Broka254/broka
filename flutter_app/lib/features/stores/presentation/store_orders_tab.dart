// My Store's Orders tab: the order requests buyers sent the store, in the
// groups an owner works through - what is waiting on the store first - and
// the way into each one (StoreOrderScreen).
//
// Shown only while BROKA has store orders on (Store.ordersEnabled). Every
// count, status and total is the server's (GET /stores/{id}/orders and
// /orders/summary); the app adds nothing up. A request is not a sale, and
// no figure here is money received: buyers pay the store directly or
// through an independent escrow service, outside BROKA.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import '../domain/models/store_order.dart';
import 'store_order_screen.dart';

class StoreOrdersTab extends StatefulWidget {
  const StoreOrdersTab({
    super.key,
    required this.store,
    required this.repo,
    required this.onStoreChanged,
  });

  final Store store;
  final StoresRepository repo;

  /// The store after the owner starts taking orders again from here.
  final ValueChanged<Store> onStoreChanged;

  @override
  State<StoreOrdersTab> createState() => _StoreOrdersTabState();
}

class _StoreOrdersTabState extends State<StoreOrdersTab> {
  StoreOrderGroup _group = StoreOrderGroup.needsAction;
  StoreOrdersPage? _page;
  StoreOrdersOverview? _overview;
  String? _error;
  bool _loading = true;
  bool _resuming = false;

  /// Bumped per load: a slow answer for a group the owner already left
  /// is dropped instead of replacing the newer one.
  int _ticket = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ticket = ++_ticket;
    final group = _group;
    final pageFuture = widget.repo.getStoreOrders(widget.store.id, group: group.value);
    final overviewFuture = widget.repo.getStoreOrdersOverview(widget.store.id);
    final page = await pageFuture;
    final overview = await overviewFuture;
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _loading = false;
      switch (page) {
        case Success(:final data):
          _page = data;
          _error = null;
        case Failure(:final message):
          _error = message;
      }
      if (overview case Success(:final data)) _overview = data;
    });
  }

  void _select(StoreOrderGroup group) {
    if (group == _group) return;
    setState(() {
      _group = group;
      _page = null;
      _loading = true;
      _error = null;
    });
    unawaited(_load());
  }

  Future<void> _open(StoreOrderSummary order) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => StoreOrderScreen(orderId: order.id, repo: widget.repo)));
    if (mounted) await _load();
  }

  Future<void> _resume() async {
    setState(() => _resuming = true);
    final result = await widget.repo.setAcceptingOrders(widget.store.id, true);
    if (!mounted) return;
    setState(() => _resuming = false);
    switch (result) {
      case Success(:final data):
        widget.onStoreChanged(data);
        unawaited(_load());
      case Failure(:final message):
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final accepting = _overview?.acceptingOrders ?? widget.store.acceptingOrders;
    final page = _page;
    return RefreshIndicator(
      color: BrokaColors.gold,
      onRefresh: _load,
      child: CustomScrollView(
        key: const Key('orders-list'),
        slivers: [
          // Below the pinned bar and tabs, like every other tab here.
          SliverOverlapInjector(handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            sliver: SliverList(delegate: SliverChildListDelegate([
              if (!accepting) _pausedBanner(),
              _groups(),
              const SizedBox(height: 14),
              if (_error != null && page == null)
                _Notice(
                  icon: Icons.cloud_off_rounded,
                  text: _error!,
                  action: TextButton(onPressed: _load, child: const Text('Try again')),
                )
              else if (page == null && _loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator(color: BrokaColors.gold)),
                )
              else if (page != null && page.items.isEmpty)
                _Notice(icon: Icons.inbox_outlined, text: _emptyText(_group))
              else if (page != null) ...[
                for (final o in page.items) _OrderRow(order: o, onTap: () => _open(o)),
                if (page.total > page.items.length)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Showing the latest ${page.items.length} of ${page.total}.',
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                  ),
              ],
              const SizedBox(height: 18),
              const Text(
                'Buyers pay you directly or through an independent escrow service they '
                'choose. BROKA does not receive, hold or verify payments: confirm a payment '
                'in an order only once the money is in your account.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.45),
              ),
            ])),
          ),
        ],
      ),
    );
  }

  Widget _groups() {
    final overview = _overview;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final g in StoreOrderGroup.values)
        _GroupChip(
          key: Key('orders-group-${g.value}'),
          label: overview == null ? g.label : '${g.label} · ${overview.count(g)}',
          selected: g == _group,
          urgent: g == StoreOrderGroup.needsAction && (overview?.count(g) ?? 0) > 0,
          onTap: () => _select(g),
        ),
    ]);
  }

  Widget _pausedBanner() {
    final note = widget.store.ordersPauseNote;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        key: const Key('orders-paused'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: BrokaColors.warning.withOpacity(0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.warning.withOpacity(0.45)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text("You've paused new orders",
              style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            note == null || note.trim().isEmpty
                ? "Buyers can still browse your store, but can't send order requests. "
                    'Orders already sent carry on.'
                : 'Buyers see: "${note.trim()}". Orders already sent carry on.',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('orders-resume'),
            onPressed: _resuming ? null : _resume,
            child: Text(_resuming ? 'Starting…' : 'Start taking orders again'),
          ),
        ]),
      ),
    );
  }

  static String _emptyText(StoreOrderGroup group) => switch (group) {
        StoreOrderGroup.needsAction =>
          'Nothing waiting for you. New order requests appear here, and BROKA sends you '
              'a notification when one arrives.',
        StoreOrderGroup.awaitingBuyer => 'No orders waiting on a buyer.',
        StoreOrderGroup.handedOver => 'Nothing ready for collection or on its way.',
        StoreOrderGroup.completed =>
          'No completed orders yet. An order completes when the buyer confirms they received it.',
        StoreOrderGroup.closed => 'No declined, cancelled or expired orders.',
      };
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    super.key,
    required this.label,
    required this.selected,
    required this.urgent,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool urgent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? BrokaColors.gold.withOpacity(0.18) : BrokaColors.bgCard.withOpacity(0.6),
          shape: StadiumBorder(
            side: BorderSide(
              color: selected
                  ? BrokaColors.gold
                  : urgent
                      ? BrokaColors.warning.withOpacity(0.6)
                      : BrokaColors.border,
            ),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(label,
                  style: TextStyle(
                    color: selected ? BrokaColors.textHigh : BrokaColors.textMid,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  )),
            ),
          ),
        ),
      );
}

class _OrderRow extends StatelessWidget {
  const _OrderRow({required this.order, required this.onTap});
  final StoreOrderSummary order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final deadline = o.status == StoreOrderStatus.submitted && o.expiresAt != null
        ? 'Answer by ${formatOrderWhen(o.expiresAt)}'
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: Key('store-order-${o.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: o.needsAction
                      ? BrokaColors.gold.withOpacity(0.55)
                      : BrokaColors.border.withOpacity(0.6)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    [o.reference, if (o.buyerName != null) o.buyerName!].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 3),
                  Text(o.itemsLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
                  const SizedBox(height: 6),
                  Text(o.statusLabel,
                      style: TextStyle(
                          color: o.needsAction ? BrokaColors.gold : BrokaColors.textMid,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                  if (deadline != null) ...[
                    const SizedBox(height: 2),
                    Text(deadline,
                        style: const TextStyle(color: BrokaColors.warning, fontSize: 11.5)),
                  ],
                  if (o.problemReported) ...[
                    const SizedBox(height: 2),
                    const Text('The buyer reported a problem',
                        style: TextStyle(color: BrokaColors.danger, fontSize: 11.5)),
                  ],
                ]),
              ),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(formatMinorKes(o.totalMinor),
                    style: const TextStyle(
                        color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 13.5)),
                const SizedBox(height: 3),
                Text(o.isFinal ? 'Agreed' : 'Not final',
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
                const SizedBox(height: 3),
                Text(formatOrderWhen(o.updatedAt ?? o.createdAt),
                    style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(children: [
          Icon(icon, color: BrokaColors.textMid, size: 34),
          const SizedBox(height: 10),
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45)),
          if (action != null) ...[const SizedBox(height: 6), action!],
        ]),
      );
}

/// Asks the owner what buyers should be told while new orders are paused.
/// Returns the note ('' for none), or null when they changed their mind.
Future<String?> askPauseOrdersNote(BuildContext context) => showDialog<String>(
      context: context,
      builder: (_) => const _PauseOrdersDialog(),
    );

class _PauseOrdersDialog extends StatefulWidget {
  const _PauseOrdersDialog();

  @override
  State<_PauseOrdersDialog> createState() => _PauseOrdersDialogState();
}

class _PauseOrdersDialogState extends State<_PauseOrdersDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Pause new orders?', style: TextStyle(color: BrokaColors.textHigh)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            "Buyers can still see your store and products, but can't send order requests. "
            'Orders already sent carry on as usual.',
            style: TextStyle(color: BrokaColors.textMid, height: 1.45),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pause-orders-note'),
            controller: _note,
            maxLength: 160,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(
              labelText: 'What buyers see (optional)',
              hintText: 'Back on Monday',
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm-pause-orders'),
            onPressed: () => Navigator.pop(context, _note.text.trim()),
            child: const Text('Pause orders',
                style: TextStyle(color: BrokaColors.warning, fontWeight: FontWeight.w700)),
          ),
        ],
      );
}
