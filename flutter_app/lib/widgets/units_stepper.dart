// How many of a listing's units a deal is for - 3 of the seller's 100 bags.
//
// The backend takes that many from the listing's stock when the deal is
// agreed and refuses more than are left (backend/api/domains/listings/
// stock.py); without it every deal was one unit, so a 100-bag listing needed
// 100 deals to sell out. Shown only for a listing of more than one unit.
import 'package:flutter/material.dart';

import '../main.dart';
import '../models/listing.dart';
import '../utils/price_unit.dart';

/// The most a buyer can take: what the backend said is left, else the
/// listing's quantity. At least one.
int unitsAvailable(Listing l) {
  final most = l.unitsLeft ?? l.quantity ?? 1;
  return most < 1 ? 1 : most;
}

/// Whether a deal on [l] needs to say how many units it is for.
bool hasUnits(Listing l) => l.listingType != 'auction' && (l.quantity ?? 1) > 1;

class UnitsStepper extends StatelessWidget {
  const UnitsStepper({
    super.key,
    required this.value,
    required this.max,
    required this.onChanged,
    this.unit,
  });

  final int value;
  final int max;
  final String? unit;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget step(IconData icon, bool enabled, int to, String tip) => IconButton(
          tooltip: tip,
          onPressed: enabled ? () => onChanged(to) : null,
          icon: Icon(icon, size: 20,
              color: enabled ? BrokaColors.textHigh : BrokaColors.textLow),
          style: IconButton.styleFrom(
            backgroundColor: BrokaColors.bgCard,
            side: const BorderSide(color: BrokaColors.border),
          ),
        );
    return Row(children: [
      step(Icons.remove_rounded, value > 1, value - 1, 'Fewer'),
      Expanded(
        child: Column(children: [
          Text('$value', key: const Key('units-value'), style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 22, fontWeight: FontWeight.w900)),
          Text(value == 1 ? (unit ?? 'item') : PriceUnits.plural(unit ?? 'item'),
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        ]),
      ),
      step(Icons.add_rounded, value < max, value + 1, 'More'),
    ]);
  }
}

/// Asks how many units an already-agreed price covers. Null if cancelled.
Future<int?> askUnitsForPrice(BuildContext context, Listing l, String priceLabel) {
  final max = unitsAvailable(l);
  var units = 1;
  return showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: BrokaColors.neonBlue)),
        title: Text('How many ${PriceUnits.plural(l.priceUnit ?? 'item')}?',
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$priceLabel is for how many of the seller\'s '
              '${PriceUnits.quantity(max, l.priceUnit)} left?',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.4)),
          const SizedBox(height: 14),
          UnitsStepper(value: units, max: max, unit: l.priceUnit,
              onChanged: (v) => setState(() => units = v)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: BrokaColors.textLow))),
          ElevatedButton(
            key: const Key('units-confirm'),
            onPressed: () => Navigator.pop(ctx, units),
            style: ElevatedButton.styleFrom(
                backgroundColor: BrokaColors.neonBlue, foregroundColor: Colors.white),
            child: const Text('Continue', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    ),
  );
}
