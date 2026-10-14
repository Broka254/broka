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
//
// A listing that was never paid for, or whose time ran out, can also be
// removed from here. Without that, a seller who changed their mind - or
// posted the same item three times while a payment failed - had no way to
// clear it: the dashboard's catalogue, where Delete lives, never shows an
// unpaid listing.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../utils/price_format.dart';
import '../../../widgets/broka_image.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../data/listing_fee_repository.dart';
import '../domain/listing_fee.dart';
import 'listing_fee_screen.dart';

class AwaitingPaymentPanel extends StatefulWidget {
  const AwaitingPaymentPanel({super.key, this.reloadSignal = 0, this.repository, this.listings});

  /// Changes whenever the dashboard refreshes; the panel reloads with it.
  final int reloadSignal;

  /// For tests.
  final ListingFeeRepository? repository;
  final ListingsRepository? listings;

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

  /// Asks first, then takes the listing off BROKA - the same soft delete as
  /// the catalogue's Delete (DELETE /listings/{id}), so nothing that points
  /// at it breaks. The server's refusal, if any, is shown as it comes.
  Future<void> _remove(ListingAwaitingFee listing) async {
    HapticFeedback.selectionClick();
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrokaColors.border)),
        title: const Text('Remove this listing?',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 17)),
        content: Text(
            listing.state.unpaid
                ? '"${listing.name}" was never paid for, so buyers have not seen it. '
                    'Removing it deletes it for good - nothing is charged.'
                : '"${listing.name}" will be deleted for good. This can\'t be undone.',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it', style: TextStyle(color: BrokaColors.textMid)),
          ),
          TextButton(
            key: const Key('confirm-remove-unpaid'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: BrokaColors.danger, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final r = await (widget.listings ?? listingsRepository).deleteListing(listing.id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (r) {
      case Success():
        setState(() => _listings = [for (final l in _listings) if (l.id != listing.id) l]);
        messenger.showSnackBar(SnackBar(
          content: Text('"${listing.name}" removed'),
          behavior: SnackBarBehavior.floating,
        ));
      case Failure(:final message):
        messenger.showSnackBar(SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: BrokaColors.danger,
        ));
    }
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
        const Text('Pay to publish or renew - they go live as soon as M-Pesa confirms. '
            'Changed your mind? Remove the ones you no longer want.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        const SizedBox(height: 10),
        for (final l in _listings)
          _Row(
            listing: l,
            onTap: () => _open(l),
            // A listing still running ("ending soon") is deleted from the
            // catalogue like any live one; here only those buyers can't see.
            onRemove: l.state.live ? null : () => _remove(l),
          ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.listing, required this.onTap, this.onRemove});
  final ListingAwaitingFee listing;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

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
        if (onRemove != null) ...[
          const SizedBox(width: 6),
          IconButton(
            key: Key('awaiting-remove-${listing.id}'),
            tooltip: 'Remove listing',
            onPressed: onRemove,
            style: IconButton.styleFrom(
              backgroundColor: BrokaColors.danger.withOpacity(0.12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.delete_outline_rounded, color: BrokaColors.danger, size: 20),
          ),
        ],
      ]),
    );
  }
}
