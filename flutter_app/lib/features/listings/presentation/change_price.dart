// Changing a listing's price, from the seller dashboard and My Store.
//
// The server holds every rule (PATCH /listings/{id}: two changes a week, 12
// hours apart, none while a deal stands, a raise of at most 25% once buyers
// have seen the price) and explains each refusal itself, so this only asks
// for the number, passes the server's words on, and - when a raise would
// shorten the listing's paid time - asks the seller before sending it again.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../data/repositories/listings_repository.dart';

/// Asks for a new price and changes it. True when the price changed.
Future<bool> changeListingPrice(
  BuildContext context, {
  required ListingsRepository repo,
  required String listingId,
  required String name,
  required double currentPrice,
}) async {
  final price = await showDialog<double>(
      context: context,
      builder: (_) => ListingPriceDialog(name: name, currentPrice: currentPrice));
  if (price == null || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);

  var result = await repo.changePrice(listingId, price);
  if (result case Success(:final data) when data.needsConfirmation) {
    if (!context.mounted) return false;
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Your paid time gets shorter',
            style: TextStyle(color: BrokaColors.textHigh)),
        content: Text(data.confirmMessage!,
            style: const TextStyle(color: BrokaColors.textMid, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep the price')),
          TextButton(
            key: const Key('confirm-shorter-paid-time'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Change it', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (yes != true) return false;
    result = await repo.changePrice(listingId, price, acceptShorterPaidTime: true);
  }

  switch (result) {
    case Success(:final data):
      messenger.showSnackBar(SnackBar(content: Text(switch (data.changesRemaining) {
        null => 'Price updated',
        0 => "Price updated. That was this week's last price change.",
        1 => 'Price updated. You can change it once more this week.',
        final n => 'Price updated. You can change it $n more times this week.',
      })));
      return true;
    case Failure(:final message):
      // The server's own words: they say which limit applies and when it lifts.
      messenger.showSnackBar(SnackBar(content: Text(message)));
      return false;
  }
}

class ListingPriceDialog extends StatefulWidget {
  const ListingPriceDialog({super.key, required this.name, required this.currentPrice});
  final String name;
  final double currentPrice;

  @override
  State<ListingPriceDialog> createState() => _ListingPriceDialogState();
}

class _ListingPriceDialogState extends State<ListingPriceDialog> {
  late final _ctrl = TextEditingController(text: widget.currentPrice.round().toString());
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final value = double.tryParse(_ctrl.text.trim());
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter a price in shillings');
      return;
    }
    // The same price isn't a change, and would spend one of the week's two.
    Navigator.pop(context, value == widget.currentPrice ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: BrokaColors.bgMid,
      title: const Text('Change the price', style: TextStyle(color: BrokaColors.textHigh)),
      content: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.name, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textMid)),
        const SizedBox(height: 14),
        TextField(
          key: const Key('price-field'),
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => _save(),
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18,
              fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            prefixText: 'KES ',
            prefixStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 18),
            errorText: _error,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
            'A price can change twice a week, at least 12 hours apart, and go up by '
            'at most 25% at a time. A higher price means a higher listing fee, so '
            'raising it shortens the time you have paid for.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          key: const Key('save-price'),
          onPressed: _save,
          child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}
