// The Seller Dashboard's "waiting for payment" list: listings buyers can't
// see until they are paid for, or soon won't.
//
// It has to exist because nothing else shows them. Every public listing
// read hides an unpaid listing (backend listings/paid.py), and the
// dashboard's catalogue is built from one - so a listing left unpaid at Go
// live, or one whose paid time ran out, would simply vanish from its
// seller's view, with no way back to paying for it.
//
// Draws nothing when there is nothing to pay, or when the list can't be
// loaded: it is a prompt, not a section the dashboard depends on.
import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../utils/price_format.dart';
import '../../../widgets/broka_image.dart';
import '../data/listing_fee_repository.dart';
import '../domain/listing_fee.dart';
import 'listing_fee_screen.dart';

class AwaitingPaymentPanel extends StatefulWidget {
  const AwaitingPaymentPanel({super.key, this.reloadSignal = 0, this.repository});

  /// Changes whenever the dashboard refreshes; the panel reloads with it.
  final int reloadSignal;

  /// For tests.
  final ListingFeeRepository? repository;

  @override
  State<AwaitingPaymentPanel> createState() => _AwaitingPaymentPanelState();
}

class _AwaitingPaymentPanelState extends State<AwaitingPaymentPanel> {
  List<ListingAwaitingFee> _listings = const [];

  ListingFeeRepository get _repo => widget.repository ?? listingFeeRepository;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AwaitingPaymentPanel old) {
    super.didUpdateWidget(old);
    if (old.reloadSignal != widget.reloadSignal) _load();
  }

  Future<void> _load() async {
    final r = await _repo.awaitingPayment();
    if (!mounted) return;
    if (r case Success(:final data)) setState(() => _listings = data);
  }

  Future<void> _open(ListingAwaitingFee listing) async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(
      builder: (_) => ListingFeeScreen(listingId: listing.id, listingName: listing.name),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_listings.isEmpty) return const SizedBox.shrink();
    final hidden = _listings.where((l) => !l.state.live).length;
    return Container(
      key: const Key('awaiting-payment-panel'),
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.warning.withOpacity(0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.visibility_off_rounded, color: BrokaColors.warning, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hidden > 0
                  ? '$hidden ${hidden == 1 ? 'listing buyers can\'t see' : 'listings buyers can\'t see'}'
                  : 'Listings ending soon',
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        const Text('Pay to publish or renew - they go live as soon as M-Pesa confirms.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        const SizedBox(height: 10),
        for (final l in _listings) _Row(listing: l, onTap: () => _open(l)),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.listing, required this.onTap});
  final ListingAwaitingFee listing;
  final VoidCallback onTap;

  String get _status => switch (listing.state.status) {
        'unpaid' => 'Not published yet',
        'expired' => 'Ended - hidden from buyers',
        _ => listing.state.paidUntil == null
            ? 'Ending soon'
            : 'Ends ${_daysLeft(listing.state.paidUntil!)}',
      };

  static String _daysLeft(DateTime until) {
    final days = until.difference(DateTime.now()).inDays;
    if (days <= 0) return 'today';
    return days == 1 ? 'tomorrow' : 'in $days days';
  }

  @override
  Widget build(BuildContext context) {
    final action = listing.state.unpaid ? 'Pay' : 'Renew';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: BrokaImage(listing.coverThumb, width: 44, height: 44,
              placeholder: Container(width: 44, height: 44, color: BrokaColors.bgMid)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(listing.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w700)),
            Text('${formatKes(listing.price)} · $_status',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
          ]),
        ),
        TextButton(
          key: Key('awaiting-payment-${listing.id}'),
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor: BrokaColors.neonGreen.withOpacity(0.15),
            foregroundColor: BrokaColors.neonGreen,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(action, style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }
}
