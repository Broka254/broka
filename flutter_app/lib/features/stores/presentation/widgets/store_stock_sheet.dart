// A product's stock, as its owner manages it for store orders
// (PATCH /stores/{id}/manage/listings/{listing_id}/stock):
//
//   counted     the owner says how many are on hand. Accepting an order
//               sets units aside; handing it over takes them off; an order
//               that ends without a sale gives them back.
//   not counted every product until its owner chooses. The store confirms
//               availability on each order - never "out of stock".
//   paused      shown to buyers, labelled, and not orderable for now.
//
// The server checks again: on hand can't go below what accepted orders
// hold, and its refusal is shown in its own words.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/utils/result.dart';
import '../../../../main.dart' show BrokaColors;
import '../../data/repositories/stores_repository.dart';
import '../../domain/models/store_order.dart';
import '../../domain/models/store_product.dart';

/// Opens the stock sheet for [product]; the saved stock, or null.
Future<StoreListingStock?> showStoreStockSheet(
  BuildContext context, {
  required String storeId,
  required StoreProduct product,
  required StoresRepository repo,
}) =>
    showModalBottomSheet<StoreListingStock>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => StoreStockSheet(storeId: storeId, product: product, repo: repo),
    );

class StoreStockSheet extends StatefulWidget {
  const StoreStockSheet({
    super.key,
    required this.storeId,
    required this.product,
    required this.repo,
  });

  final String storeId;
  final StoreProduct product;
  final StoresRepository repo;

  @override
  State<StoreStockSheet> createState() => _StoreStockSheetState();
}

class _StoreStockSheetState extends State<StoreStockSheet> {
  late bool _tracked = widget.product.stockTracked;
  late bool _paused = widget.product.temporarilyUnavailable;
  late final _quantity = TextEditingController(
      text: widget.product.stockTracked && widget.product.stockQuantity != null
          ? '${widget.product.stockQuantity}'
          : '');
  bool _saving = false;
  String? _problem;

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    int? quantity;
    if (_tracked) {
      quantity = int.tryParse(_quantity.text.trim());
      if (quantity == null || quantity < 0) {
        setState(() => _problem = 'Say how many you have - 0 if none are left.');
        return;
      }
      final reserved = widget.product.stockReserved;
      if (quantity < reserved) {
        setState(() => _problem =
            '$reserved of these are set aside for accepted orders. Set at least $reserved.');
        return;
      }
    }
    setState(() {
      _saving = true;
      _problem = null;
    });
    final result = await widget.repo.setListingStock(
      widget.storeId,
      widget.product.id,
      tracked: _tracked,
      quantity: quantity,
      temporarilyUnavailable: _paused,
    );
    if (!mounted) return;
    switch (result) {
      case Success(:final data):
        Navigator.pop(context, data);
      case Failure(:final message):
        setState(() {
          _saving = false;
          _problem = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    const hint = TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4);
    return SafeArea(
      child: Padding(
        // Above the keyboard while the quantity is typed.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: BrokaColors.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),
            Text(p.listing.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Stock and availability for orders', style: hint),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('stock-tracked-switch'),
              contentPadding: EdgeInsets.zero,
              value: _tracked,
              activeColor: BrokaColors.gold,
              onChanged: _saving ? null : (on) => setState(() => _tracked = on),
              title: const Text('Count stock for this product',
                  style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w600)),
              subtitle: const Text(
                  'Accepting an order sets units aside; they come off when the order is '
                  'handed over, and go back if it ends without a sale.',
                  style: hint),
            ),
            if (_tracked) ...[
              TextField(
                key: const Key('stock-quantity-field'),
                controller: _quantity,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: const InputDecoration(labelText: 'How many you have on hand'),
              ),
              if (p.stockReserved > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('${p.stockReserved} set aside for accepted orders.', style: hint),
                ),
            ] else
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  "Not counted: you confirm what you have on each order, and buyers never see "
                  "it as out of stock. A buyer can ask for up to ${p.stockQuantity ?? 1}.",
                  style: hint,
                ),
              ),
            SwitchListTile(
              key: const Key('stock-paused-switch'),
              contentPadding: EdgeInsets.zero,
              value: _paused,
              activeColor: BrokaColors.warning,
              onChanged: _saving ? null : (on) => setState(() => _paused = on),
              title: const Text('Pause new orders for it',
                  style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w600)),
              subtitle: const Text('Buyers still see it, marked as unavailable for now.', style: hint),
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Text(_problem!,
                    key: const Key('stock-problem'),
                    style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5)),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('stock-save'),
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                    backgroundColor: BrokaColors.gold, foregroundColor: Colors.black),
                child: Text(_saving ? 'Saving…' : 'Save',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A short stock line for the product list, or null when there's nothing
/// to say.
String? storeStockNote(StoreProduct p) {
  if (p.temporarilyUnavailable) return 'Paused for new orders';
  if (!p.stockTracked) return null;
  if (p.outOfStock) return 'Out of stock';
  final left = p.availableQuantity ?? 0;
  return p.stockReserved > 0
      ? '$left in stock to order · ${p.stockReserved} set aside'
      : '$left in stock';
}
