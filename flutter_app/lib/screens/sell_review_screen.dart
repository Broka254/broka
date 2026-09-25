// BROKA - Sell Wizard Step 7: Review & Activate
//
// Final step - read-only summary of everything entered on the previous
// six screens, plus the actual submission (ListingPublisher: photo ids,
// showcase, POST /listings; the draft is cleared on success). This is
// where _submit() from the old single-screen sell_screen.dart now lives.
//
// No verification-video handling here - that capture step has been
// removed from the wizard entirely, not just hidden. verified_video is
// an Optional field on the backend already (see api/domains/listings),
// so simply omitting it from the payload is a clean, safe change.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../main.dart';
import '../core/network/api_client.dart';
import '../core/utils/result.dart';
import '../services/api_service.dart';
import '../services/listing_publisher.dart';
import '../services/photo_upload_tracker.dart';
import '../services/sell_draft_store.dart';
import '../services/sell_wizard_data.dart';
import '../utils/price_format.dart';
import '../widgets/sell_step_scaffold.dart';
import '../features/stores/data/repositories/stores_repository.dart';
import '../features/stores/domain/models/store.dart';

class SellReviewScreen extends StatefulWidget {
  final SellWizardData data;
  const SellReviewScreen({super.key, required this.data});
  @override
  State<SellReviewScreen> createState() => _SellReviewScreenState();
}

class _SellReviewScreenState extends State<SellReviewScreen> {
  bool _loading = false;
  String? _error;
  // Store feature (spec §11). Null while loading AND null if the seller
  // simply has no store - both render the same way (no selector at all),
  // so there's no separate "loading" flicker for the common case.
  Store? _myStore;

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
      // same as genuinely having no store. Not worth surfacing as an
      // error on a screen whose actual job is the listing itself.
      onFailure: (_, __) {},
    );
  }

  Future<void> _activate() async {
    // One press at a time. The button shows a spinner while this runs, but
    // a second tap can land before that frame is drawn.
    if (_loading) return;
    final data = widget.data;

    if (data.verifiedPhotos.isEmpty) {
      setState(() => _error = 'Please go back and take at least one verified photo.');
      return;
    }
    final price = parseKesInput(data.price);
    if (price == null || price <= 0 || price > maxListingPriceKes) {
      setState(() => _error = 'Please go back and enter a valid asking price.');
      return;
    }
    if (data.location.trim().isEmpty) {
      setState(() => _error = 'Please go back and enter a location.');
      return;
    }
    // A draft picked up days later can hold a closing time that has
    // passed; the server would refuse it, but the fix is on the Price step.
    final endsAt = data.auctionEndsAt;
    if (data.type == 'auction' && endsAt != null && !endsAt.isAfter(DateTime.now())) {
      setState(() => _error =
          "The auction's closing time has passed. Go back to Price and choose a later one.");
      return;
    }

    setState(() { _loading = true; _error = null; });

    try {
      await ListingPublisher().publish(
        data,
        lat: ApiService.currentUserLat ?? -1.286389,
        lng: ApiService.currentUserLng ?? 36.817223,
      );

      if (!mounted) return;
      unawaited(SellDraftStore.clear());
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Listing created! Your verified listing is now live.')));
      // Clears the whole wizard stack (variable depth - and sometimes just
      // this one screen, if reached via the splash screen's crash-recovery
      // replace) rather than a single pop, so this works correctly no
      // matter how the flow was entered.
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    } on PhotoUploadIncomplete catch (e) {
      _showError('$e. Check your connection and try again.');
    } on ApiException catch (e) {
      _showError(e.message);
    } on TimeoutException {
      // The listing may have been created anyway. Pressing Activate again
      // is safe: the draft's key makes the server return it, not a copy.
      _showError('No answer from BROKA - your connection may be slow. Tap Activate '
          "again: your listing won't be posted twice.");
    } catch (_) {
      _showError("Couldn't reach BROKA. Check your connection and try again.");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String message) {
    if (mounted) setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final isAuction = data.type == 'auction';
    return SellStepScaffold(
      step: 7, totalSteps: 7, title: 'Review',
      error: _error,
      loading: _loading,
      nextLabel: 'ACTIVATE LISTING',
      onNext: _activate,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: BrokaColors.gold.withOpacity(0.5)),
                image: DecorationImage(
                  image: FileImage(data.verifiedPhotos[i]),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),

        if (data.showcaseImageDataUri != null) ...[
          sellStepLabel(data.showcaseImageSource == 'ai' ? '✨ AI SHOWCASE' : 'SHOWCASE IMAGE'),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 100, width: double.infinity,
              child: _showcasePreviewImage(data.showcaseImageDataUri!),
            ),
          ),
          const SizedBox(height: 20),
        ],

        if (_myStore != null) ...[
          sellStepLabel('LIST UNDER'),
          const SizedBox(height: 8),
          _storeToggle(data),
          const SizedBox(height: 20),
        ],

        _summaryCard([
          _row('Name', data.name),
          _row('Category', data.subcategoryName != null
              ? '${data.category} → ${data.subcategoryName}'
              : data.category),
          if (data.condition != null)
            _row('Condition', data.condition![0].toUpperCase() + data.condition!.substring(1)),
          ...data.attributes.entries
              .where((e) => e.value.trim().isNotEmpty)
              .map((e) => _row(
                  e.key[0].toUpperCase() + e.key.substring(1).replaceAll('_', ' '),
                  e.value)),
          _row('Type', isAuction ? 'Auction' : 'Direct Sale'),
          _row('Price', _kes(data.price)),
          if (isAuction && data.reserve.isNotEmpty)
            _row('Reserve price', _kes(data.reserve)),
          _row('Location', data.location),
          _row('Description', data.description.isEmpty ? '—' : data.description),
        ]),

        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: BrokaColors.border),
          ),
          child: const Text(
            'Double-check everything above - you can go back to fix any '
            'step before activating. Once live, buyers can find and '
            'negotiate on this listing right away.',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.4),
          ),
        ),
      ]),
    );
  }

  static String _kes(String amount) {
    final value = parseKesInput(amount);
    return value == null ? amount : formatKes(value);
  }

  Widget _summaryCard(List<Widget> rows) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Column(children: rows),
  );

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
      chip('No Store', data.storeId == null, () => setState(() => data.storeId = null)),
      const SizedBox(width: 10),
      chip(store.name, data.storeId == store.id, () => setState(() => data.storeId = store.id)),
    ]);
  }

  /// data.showcaseImageDataUri is a full "data:<mime>;base64,<payload>"
  /// string (see the Listing model comment in lib/models/listing.dart) -
  /// strip everything up to the data-URI comma before base64Decode, same
  /// as product_card.dart's showcase handling.
  Widget _showcasePreviewImage(String dataUri) {
    final idx = dataUri.indexOf(',');
    if (idx == -1) return const ColoredBox(color: BrokaColors.bgCard);
    try {
      return Image.memory(
        base64Decode(dataUri.substring(idx + 1)),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const ColoredBox(color: BrokaColors.bgCard),
      );
    } catch (_) {
      return const ColoredBox(color: BrokaColors.bgCard);
    }
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 96,
        child: Text(label, style: const TextStyle(
            color: BrokaColors.textLow, fontSize: 11, fontWeight: FontWeight.w700)),
      ),
      Expanded(
        child: Text(value, style: const TextStyle(
            color: BrokaColors.textHigh, fontSize: 12.5)),
      ),
    ]),
  );
}
