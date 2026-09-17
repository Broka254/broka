// BROKA - Leave a Review Screen
// Buyers open this to rate a seller (1-5 stars) and leave a comment.
// One review per deal is enforced by the backend.
//
// Route args: Map<String, dynamic> with keys:
//   deal_id      - if provided, skip deal-picker and review this deal directly
//   seller_id    - pre-select this seller's deals in the picker
//   seller_name  - display name of the seller
//   listing_name - name of the listing (shown for context)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../services/api_service.dart';

enum _ReviewStep { loading, pickDeal, form, submitting, success }

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  // Args
  String _dealId      = '';
  String _sellerId    = '';
  String _sellerName  = 'Seller';
  String _listingName = '';
  bool   _initialized = false;

  // Deal picker
  List<Map<String, dynamic>> _deals       = [];
  String? _pickedDealId;
  String? _pickedListingName;

  // Form
  int    _rating  = 0;
  final  _commentCtrl = TextEditingController();
  String? _errorMsg;

  _ReviewStep _step = _ReviewStep.loading;

  static const _labels = ['', 'Poor', 'Fair', 'Good', 'Great', 'Excellent'];
  static const _emojis = ['', '😞', '😐', '🙂', '😊', '🤩'];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      _dealId      = (args['deal_id']      as String?) ?? '';
      _sellerId    = (args['seller_id']    as String?) ?? '';
      _sellerName  = (args['seller_name']  as String?) ?? 'Seller';
      _listingName = (args['listing_name'] as String?) ?? '';
    }
    // If deal is already known, go straight to the form
    if (_dealId.isNotEmpty) {
      _pickedDealId      = _dealId;
      _pickedListingName = _listingName;
      setState(() => _step = _ReviewStep.form);
    } else {
      _loadDeals();
    }
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDeals() async {
    setState(() => _step = _ReviewStep.loading);
    try {
      final all = await ApiService.getMyReviewableDeals();
      // Filter by seller_id if known; fall back to all if empty (shouldn't happen)
      final filtered = _sellerId.isNotEmpty
          ? all.where((d) => d['seller_id'] == _sellerId).toList()
          : all;
      if (mounted) {
        // If only one pending deal and it's not yet reviewed, skip picker
        final pending = filtered.where((d) => d['already_reviewed'] != true).toList();
        if (pending.length == 1) {
          _pickedDealId      = pending.first['deal_id'] as String;
          _pickedListingName = pending.first['listing_name'] as String? ?? '';
          if (_sellerName == 'Seller') {
            _sellerName = pending.first['seller_name'] as String? ?? 'Seller';
          }
          setState(() { _deals = pending; _step = _ReviewStep.form; });
        } else {
          setState(() { _deals = filtered; _step = _ReviewStep.pickDeal; });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = 'Could not load your deals. Please try again.';
          _step = _ReviewStep.pickDeal;
        });
      }
    }
  }

  Future<void> _submit() async {
    final id = _pickedDealId ?? _dealId;
    if (id.isEmpty) {
      setState(() => _errorMsg = 'Please select a deal first.');
      return;
    }
    if (_rating == 0) {
      setState(() => _errorMsg = 'Please select a star rating before submitting.');
      return;
    }
    setState(() { _step = _ReviewStep.submitting; _errorMsg = null; });
    try {
      await ApiService.submitReview(
        dealId:  id,
        rating:  _rating,
        comment: _commentCtrl.text.trim(),
      );
      HapticFeedback.heavyImpact();
      if (mounted) setState(() => _step = _ReviewStep.success);
    } catch (e) {
      if (mounted) setState(() {
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
        _step = _ReviewStep.form;
      });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    appBar: _buildAppBar(),
    body: AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: _buildBody(),
    ),
  );

  PreferredSizeWidget _buildAppBar() => AppBar(
    backgroundColor: BrokaColors.bg,
    elevation: 0,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_rounded,
          color: BrokaColors.textMid, size: 18),
      onPressed: () => Navigator.pop(context,
          _step == _ReviewStep.success ? true : false),
    ),
    title: Row(children: [
      Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: BrokaColors.gold.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.star_rounded, color: BrokaColors.gold, size: 18),
      ),
      const SizedBox(width: 10),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Leave a Review',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 15, fontWeight: FontWeight.w800)),
        Text('Rate $_sellerName',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
      ]),
    ]),
  );

  Widget _buildBody() {
    switch (_step) {
      case _ReviewStep.loading:    return _buildLoading();
      case _ReviewStep.pickDeal:   return _buildDealPicker();
      case _ReviewStep.form:       return _buildForm();
      case _ReviewStep.submitting: return _buildSubmitting();
      case _ReviewStep.success:    return _buildSuccess();
    }
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  Widget _buildLoading() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      CircularProgressIndicator(color: BrokaColors.gold),
      SizedBox(height: 16),
      Text('Loading your deals…',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
    ]),
  );

  // ── Deal Picker ────────────────────────────────────────────────────────────

  Widget _buildDealPicker() {
    final pending = _deals.where((d) => d['already_reviewed'] != true).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 60),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Which deal would you like to review?',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text('Only completed deals can be reviewed. One review per deal.',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
        const SizedBox(height: 20),
        if (_errorMsg != null) ...[
          _ErrorBanner(message: _errorMsg!),
          const SizedBox(height: 16),
        ],
        if (pending.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Column(children: [
              Text('🤝', style: TextStyle(fontSize: 40)),
              SizedBox(height: 12),
              Text('No deals to review',
                  style: TextStyle(color: BrokaColors.textMid,
                      fontWeight: FontWeight.w700, fontSize: 14)),
              SizedBox(height: 6),
              Text(
                'You can only review sellers you have completed a deal with.',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ]),
          )
        else
          ...pending.map((d) {
            final dId     = d['deal_id']      as String;
            final seller  = d['seller_name']  as String? ?? 'Seller';
            final listing = d['listing_name'] as String? ?? 'Listing';
            final price   = (d['agreed_price'] as num?)?.toDouble() ?? 0;
            final rawDate = d['created_at']   as String?;
            String dateStr = '';
            if (rawDate != null) {
              try {
                final dt = DateTime.parse(rawDate).toLocal();
                dateStr = '${dt.day}/${dt.month}/${dt.year}';
              } catch (_) {}
            }
            final picked = _pickedDealId == dId;
            return GestureDetector(
              onTap: () => setState(() {
                _pickedDealId      = dId;
                _pickedListingName = listing;
                _sellerName        = seller;
                _errorMsg          = null;
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: picked
                      ? BrokaColors.gold.withOpacity(0.08)
                      : BrokaColors.bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: picked
                        ? BrokaColors.gold.withOpacity(0.5)
                        : BrokaColors.border,
                    width: picked ? 2 : 1,
                  ),
                ),
                child: Row(children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [BrokaColors.gold, BrokaColors.goldDim]),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(child: Text(
                      seller.isNotEmpty ? seller[0].toUpperCase() : 'S',
                      style: const TextStyle(color: Colors.white,
                          fontSize: 16, fontWeight: FontWeight.w900),
                    )),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(seller, style: const TextStyle(color: BrokaColors.textHigh,
                        fontWeight: FontWeight.w700, fontSize: 13)),
                    Text(listing, style: const TextStyle(color: BrokaColors.textMid,
                        fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('KES ${price.toStringAsFixed(0)} · $dateStr',
                        style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
                  ])),
                  if (picked)
                    const Icon(Icons.check_circle_rounded,
                        color: BrokaColors.gold, size: 22),
                ]),
              ),
            );
          }),
        if (pending.isNotEmpty) ...[
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _pickedDealId == null ? null : () {
                _listingName = _pickedListingName ?? '';
                setState(() { _step = _ReviewStep.form; _errorMsg = null; });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: BrokaColors.gold,
                foregroundColor: Colors.black87,
                disabledBackgroundColor: BrokaColors.bgCard,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text('Continue',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
            ),
          ),
        ],
      ]),
    );
  }

  // ── Form ───────────────────────────────────────────────────────────────────

  Widget _buildForm() {
    final displayListing = (_pickedListingName?.isNotEmpty == true)
        ? _pickedListingName!
        : (_listingName.isNotEmpty ? _listingName : 'Deal with $_sellerName');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 60),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Deal context card
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [BrokaColors.gold, BrokaColors.goldDim]),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(child: Text(
                _sellerName.isNotEmpty ? _sellerName[0].toUpperCase() : 'S',
                style: const TextStyle(color: Colors.white,
                    fontSize: 18, fontWeight: FontWeight.w900),
              )),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_sellerName,
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontWeight: FontWeight.w800, fontSize: 14)),
              const SizedBox(height: 2),
              Text(displayListing,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: BrokaColors.neonGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.3)),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.handshake_rounded, color: BrokaColors.neonGreen, size: 12),
                SizedBox(width: 4),
                Text('Deal done', style: TextStyle(
                    color: BrokaColors.neonGreen, fontSize: 10, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),

        const SizedBox(height: 28),
        const Center(child: Text('How was your experience?',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 18, fontWeight: FontWeight.w800))),
        const SizedBox(height: 10),
        Center(child: Text(
          _rating > 0 ? _emojis[_rating] : '⭐',
          style: TextStyle(fontSize: 48,
              color: _rating > 0 ? null : Colors.transparent),
        )),
        const SizedBox(height: 14),

        // Stars
        Center(child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(5, (i) {
            final star = i + 1;
            final filled = star <= _rating;
            return GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() { _rating = star; _errorMsg = null; });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                margin: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  filled ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: filled ? 48 : 42,
                  color: filled ? BrokaColors.gold : BrokaColors.textLow,
                ),
              ),
            );
          }),
        )),

        const SizedBox(height: 8),
        if (_rating > 0)
          Center(child: Text(_labels[_rating],
              style: TextStyle(
                  color: _ratingColor(_rating),
                  fontSize: 16, fontWeight: FontWeight.w800))),

        const SizedBox(height: 24),
        const Text('Add a comment (optional)',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Help other buyers know what to expect.',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.border),
          ),
          child: TextField(
            controller: _commentCtrl,
            maxLines: 5,
            maxLength: 500,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
            decoration: const InputDecoration(
              hintText: 'e.g. Item was exactly as described, very quick to respond. Would buy again!',
              hintStyle: TextStyle(color: BrokaColors.textLow, fontSize: 12),
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(14),
              counterStyle: TextStyle(color: BrokaColors.textLow, fontSize: 10),
            ),
          ),
        ),

        if (_errorMsg != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(message: _errorMsg!),
        ],

        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.gold,
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.star_rounded, size: 18),
              SizedBox(width: 8),
              Text('Submit Review',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
            ]),
          ),
        ),

        const SizedBox(height: 14),
        const Center(child: Text(
          'Your review is public and helps the BROKA community.',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11),
          textAlign: TextAlign.center,
        )),
      ]),
    );
  }

  // ── Submitting ─────────────────────────────────────────────────────────────

  Widget _buildSubmitting() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      CircularProgressIndicator(color: BrokaColors.gold),
      SizedBox(height: 20),
      Text('Submitting your review…',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 14)),
    ]),
  );

  // ── Success ────────────────────────────────────────────────────────────────

  Widget _buildSuccess() => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 88, height: 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: BrokaColors.gold.withOpacity(0.12),
            border: Border.all(color: BrokaColors.gold.withOpacity(0.5), width: 2.5),
          ),
          child: const Icon(Icons.star_rounded, color: BrokaColors.gold, size: 44),
        ),
        const SizedBox(height: 24),
        const Text('Review Submitted! 🌟',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 22, fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        Text(
          'Your ${_labels[_rating].toLowerCase()} rating for $_sellerName has been posted. '
          'Thank you for helping the BROKA community!',
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.6),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) => Icon(
              i < _rating ? Icons.star_rounded : Icons.star_outline_rounded,
              color: i < _rating ? BrokaColors.gold : BrokaColors.textLow,
              size: 34,
            ))),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.gold,
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: const Text('Done',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
          ),
        ),
      ]),
    ),
  );

  Color _ratingColor(int r) {
    if (r <= 1) return Colors.redAccent;
    if (r == 2) return Colors.orange;
    if (r == 3) return BrokaColors.gold;
    if (r == 4) return BrokaColors.neonGreen;
    return const Color(0xFF22C55E);
  }
}

// ── Sub-widgets ────────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.redAccent.withOpacity(0.1),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
    ),
    child: Row(children: [
      const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(message, style: const TextStyle(
          color: Colors.redAccent, fontSize: 12, height: 1.4))),
    ]),
  );
}
