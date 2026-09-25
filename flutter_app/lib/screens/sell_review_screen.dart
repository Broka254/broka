// BROKA - Sell Wizard Step 9: Review
//
// A read-only summary of everything entered on the steps before, and the
// store choice for sellers who have one. Publishing moved to the step after
// this (sell_zeno_alert_screen.dart), where Zeno asks one last question -
// so this is where the seller checks the listing, and that is where it
// goes live.
import 'dart:io';
import 'package:flutter/material.dart';
import '../main.dart';
import '../core/utils/result.dart';
import '../services/sell_wizard_data.dart';
import '../utils/land_size.dart';
import '../utils/price_format.dart';
import '../utils/price_unit.dart';
import '../widgets/broka_image.dart';
import '../widgets/sell_step_scaffold.dart';
import '../features/stores/data/repositories/stores_repository.dart';
import '../features/stores/domain/models/store.dart';
import 'sell_flow.dart';

class SellReviewScreen extends StatefulWidget {
  final SellWizardData data;
  const SellReviewScreen({super.key, required this.data});
  @override
  State<SellReviewScreen> createState() => _SellReviewScreenState();
}

class _SellReviewScreenState extends State<SellReviewScreen> {
  String? _error;
  // Store feature (spec §11). Null while loading AND null if the seller
  // simply has no store - both render the same way (no selector at all),
  // so there's no separate "loading" flicker for the common case.
  Store? _myStore;

  SellWizardData get _data => widget.data;

  @override
  void initState() {
    super.initState();
    _loadMyStore();
  }

  Future<void> _loadMyStore() async {
    final result = await storesRepository.getMyStore();
    if (!mounted) return;
    result.fold(
      onSuccess: (store) => setState(() => _myStore = store),
      // A failed lookup (e.g. offline) just means no selector shows -
      // same as genuinely having no store.
      onFailure: (_, __) {},
    );
  }

  void _next() {
    // Every earlier step, checked again: a restored draft or a step
    // revisited with Back can leave one incomplete.
    for (var step = SellFlow.photos; step < SellFlow.review; step++) {
      if (!SellFlow.isComplete(step, _data)) {
        setState(() => _error = 'Go back to ${SellFlow.title(step)} - something there still needs '
            'an answer.');
        return;
      }
    }
    setState(() => _error = null);
    SellFlow.next(context, _data, from: SellFlow.review);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final amount = parseKesInput(data.price);
    final quantity = int.tryParse(data.quantity) ?? 1;
    final land = data.isLand ? LandSize.describe(data.attributes) : null;
    return SellStepScaffold(
      step: SellFlow.review, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.review),
      subtitle: 'Check everything. Tap Back to fix any step.',
      data: data,
      error: _error,
      nextLabel: 'LOOKS GOOD',
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (data.hasShowcase) ...[
          sellStepLabel(data.showcaseImageSource == 'ai' ? '✨ AI COVER' : 'COVER'),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: data.showcaseLocalPath != null
                  ? Image.file(File(data.showcaseLocalPath!), fit: BoxFit.cover, cacheWidth: 900,
                      errorBuilder: (_, __, ___) => const ColoredBox(color: BrokaColors.bgCard))
                  : BrokaImage(data.showcasePreviewUrl, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 16),
        ],
        sellStepLabel('PHOTOS'),
        const SizedBox(height: 8),
        SizedBox(
          height: 80,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: data.verifiedPhotos.length,
            itemBuilder: (_, i) => Container(
              margin: const EdgeInsets.only(right: 8),
              width: 80, height: 80,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: BrokaColors.gold.withOpacity(0.5)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.file(data.verifiedPhotos[i], fit: BoxFit.cover, cacheWidth: 240,
                  errorBuilder: (_, __, ___) => const ColoredBox(color: BrokaColors.bgCard)),
            ),
          ),
        ),
        const SizedBox(height: 20),

        if (_myStore != null) ...[
          sellStepLabel('LIST UNDER'),
          const SizedBox(height: 8),
          _storeToggle(data),
          const SizedBox(height: 20),
        ],

        SellCard(child: Column(children: [
          _row('Name', data.name),
          _row('Category', data.subcategoryName != null
              ? '${data.category} → ${data.subcategoryName}'
              : data.category),
          if (land != null) _row('Land size', land),
          if (data.condition != null)
            _row('Condition', data.condition![0].toUpperCase() + data.condition!.substring(1)),
          ...data.attributes.entries
              .where((e) => e.value.trim().isNotEmpty && !LandSize.fieldNames.contains(e.key))
              .map((e) => _row(
                  e.key[0].toUpperCase() + e.key.substring(1).replaceAll('_', ' '),
                  e.value)),
          _row('Type', data.isAuction ? 'Auction' : 'Direct sale'),
          _row(data.isAuction ? 'Starting price' : 'Price',
              amount == null ? data.price : PriceUnits.priceLabel(formatKes(amount), data.priceUnit)),
          if (!data.isAuction)
            _row('Negotiable', data.priceNegotiable == false ? 'No - fixed price' : 'Yes - open to offers'),
          if (data.isAuction && data.reserve.isNotEmpty)
            _row('Reserve price', _kes(data.reserve)),
          if (!data.isAuction) _row('Available', PriceUnits.quantity(quantity, data.priceUnit)),
          _row('Delivery', data.deliveryAvailable == true
              ? (data.deliveryNote.isEmpty ? 'Can arrange' : 'Can arrange - ${data.deliveryNote}')
              : 'Buyer picks up'),
          _row('Location', data.location),
          _row('Description', data.description),
        ])),
      ]),
    );
  }

  static String _kes(String amount) {
    final value = parseKesInput(amount);
    return value == null ? amount : formatKes(value);
  }

  /// Spec §11: "[No Store] / [My Store]" - a seller with a store chooses
  /// per-listing, defaulting to whatever data.storeId already holds (null
  /// = personal, the safe default for a brand-new listing). Never shown
  /// at all when _myStore is null (spec: "Do not force Store ownership
  /// onto every listing").
  Widget _storeToggle(SellWizardData data) {
    final store = _myStore!;
    Widget chip(String label, bool selected, VoidCallback onTap) => Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? BrokaColors.gold.withOpacity(0.12) : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? BrokaColors.gold : BrokaColors.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? BrokaColors.gold : BrokaColors.textMid,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                fontSize: 13,
              )),
        ),
      ),
    );

    return Row(children: [
      chip('No Store', data.storeId == null, () {
        setState(() => data.storeId = null);
        data.persist();
      }),
      const SizedBox(width: 10),
      chip(store.name, data.storeId == store.id, () {
        setState(() => data.storeId = store.id);
        data.persist();
      }),
    ]);
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 100,
        child: Text(label, style: const TextStyle(
            color: BrokaColors.textMid, fontSize: 11, fontWeight: FontWeight.w700)),
      ),
      Expanded(
        child: Text(value, style: const TextStyle(
            color: BrokaColors.textHigh, fontSize: 12.5, height: 1.35)),
      ),
    ]),
  );
}
