// BROKA - Leave a Review Screen
// Buyers open this to rate a seller (1-5 stars) and leave a comment.
// Only for a deal of theirs with the seller that completed (delivery
// confirmed, escrow paid out), once per deal - the backend checks both on
// every submission; this screen only lists the deals that qualify.
//
// Route args: Map<String, dynamic> with keys:
//   deal_id      - if provided, skip deal-picker and review this deal directly
//   seller_id    - pre-select this seller's deals in the picker
//   seller_name  - display name of the seller
//   listing_name - name of the listing (shown for context)
//
// 2026-09-30: on Home's visual system (the constellation, Home's header,
// the brand gradient on its buttons), like the profile it opens from. And
// opened with a deal id alone - the "Deal Complete" notification - it looks
// the deal up for the seller's name, and says so if it was already reviewed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/utils/result.dart';
import '../features/reviews/data/repositories/reviews_repository.dart';
import '../features/reviews/domain/models/review.dart';
import '../main.dart';
import '../widgets/constellation_background.dart';

enum _ReviewStep { loading, pickDeal, form, submitting, success, closed }

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;
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
  List<ReviewableDeal> _deals = [];
  String? _pickedDealId;
  String? _pickedListingName;

  // Form
  int    _rating  = 0;
  final  _commentCtrl = TextEditingController();
  String? _errorMsg;

  /// Why this deal can't be reviewed, when it can't (step closed).
  String _closedMessage = '';

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
      _step = _ReviewStep.form;
      // From a notification: only the deal id. Who and what it was come
      // from the buyer's own reviewable deals.
      if (_sellerName == 'Seller') _describeDeal();
    } else {
      _loadDeals();
    }
  }

  Future<void> _describeDeal() async {
    final result = await reviewsRepository.myReviewableDeals(
        sellerId: _sellerId.isEmpty ? null : _sellerId);
    if (!mounted || result is! Success<List<ReviewableDeal>>) return;
    final deal = result.data.where((d) => d.dealId == _dealId).firstOrNull;
    setState(() {
      if (deal == null) {
        _closedMessage = "This deal can't be reviewed yet - reviews open once "
            'you confirm the goods arrived and the payment is released.';
        _step = _ReviewStep.closed;
      } else if (deal.alreadyReviewed) {
        _sellerName = deal.sellerName;
        _closedMessage = "You've already reviewed ${deal.sellerName} for "
            '"${deal.listingName}". Thank you!';
        _step = _ReviewStep.closed;
      } else {
        _sellerName = deal.sellerName;
        _sellerId = deal.sellerId;
        _listingName = deal.listingName;
        _pickedListingName = deal.listingName;
      }
    });
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDeals() async {
    setState(() => _step = _ReviewStep.loading);
    // The seller's deals only, when the screen was opened from their profile.
    final result = await reviewsRepository.myReviewableDeals(
        sellerId: _sellerId.isEmpty ? null : _sellerId);
    if (!mounted) return;
    result.fold(
      onSuccess: (all) {
        // If only one pending deal and it's not yet reviewed, skip picker
        final pending = all.where((d) => !d.alreadyReviewed).toList();
        if (pending.length == 1) {
          _pickedDealId      = pending.first.dealId;
          _pickedListingName = pending.first.listingName;
          if (_sellerName == 'Seller') _sellerName = pending.first.sellerName;
          setState(() { _deals = pending; _step = _ReviewStep.form; });
        } else {
          setState(() { _deals = all; _step = _ReviewStep.pickDeal; });
        }
      },
      onFailure: (_, __) => setState(() {
        _errorMsg = 'Could not load your deals. Please try again.';
        _step = _ReviewStep.pickDeal;
      }),
    );
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
    final result = await reviewsRepository.submitReview(
      dealId:  id,
      rating:  _rating,
      comment: _commentCtrl.text.trim(),
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (_) {
        HapticFeedback.heavyImpact();
        setState(() => _step = _ReviewStep.success);
      },
      onFailure: (message, _) => setState(() {
        _errorMsg = message;
        _step = _ReviewStep.form;
      }),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  static const _gradient = [BrokaColors.gold, BrokaColors.neonBlue];

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    body: ConstellationBackground(
      animate: widget.animateBackground,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.2,
            colors: [BrokaColors.gold.withOpacity(0.13), Colors.transparent],
            stops: const [0.0, 0.55],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(children: [
            _buildHeader(),
            Expanded(child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              child: _buildBody(),
            )),
          ]),
        ),
      ),
    ),
  );

  /// The header every screen reached from Home wears.
  Widget _buildHeader() {
    final narrow = MediaQuery.sizeOf(context).width < 360;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
      child: Row(children: [
        IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context, _step == _ReviewStep.success),
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textHigh, size: 19),
        ),
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [
              _gradient.first.withOpacity(0.28), _gradient.last.withOpacity(0.14)]),
            border: Border.all(color: _gradient.first.withOpacity(0.5)),
          ),
          child: const Icon(Icons.star_rounded, size: 18, color: BrokaColors.textHigh),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ZoneGlowText('Review', gradient: _gradient,
              fontSize: narrow ? 17 : 19, maxLines: 1, letterSpacing: narrow ? 0.8 : 1.1),
          Text('Rate $_sellerName', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        ])),
      ]),
    );
  }

  /// The brand gradient, as on Home's primary actions. Null [onTap] greys
  /// it out.
  Widget _primaryButton(String label, VoidCallback? onTap, {IconData? icon, Key? key}) =>
      Semantics(
        button: true,
        enabled: onTap != null,
        child: GestureDetector(
          key: key,
          onTap: onTap,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: onTap == null ? 0.4 : 1,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 15),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: _gradient),
                borderRadius: BorderRadius.circular(14),
                boxShadow: onTap == null ? null : [
                  BoxShadow(color: BrokaColors.gold.withOpacity(0.35), blurRadius: 14)],
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: Colors.white),
                  const SizedBox(width: 8),
                ],
                Text(label, style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15)),
              ]),
            ),
          ),
        ),
      );

  Widget _buildBody() {
    switch (_step) {
      case _ReviewStep.loading:    return _buildLoading();
      case _ReviewStep.pickDeal:   return _buildDealPicker();
      case _ReviewStep.form:       return _buildForm();
      case _ReviewStep.submitting: return _buildSubmitting();
      case _ReviewStep.success:    return _buildSuccess();
      case _ReviewStep.closed:     return _buildClosed();
    }
  }

  Widget _buildClosed() => Center(
    key: const Key('review-closed'),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.info_outline_rounded, color: BrokaColors.textMid, size: 40),
        const SizedBox(height: 14),
        Text(_closedMessage, textAlign: TextAlign.center,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 14, height: 1.5)),
        const SizedBox(height: 24),
        _primaryButton('Done', () => Navigator.pop(context, false)),
      ]),
    ),
  );

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
    final pending = _deals.where((d) => !d.alreadyReviewed).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 60),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Which deal would you like to review?',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text('Only completed deals can be reviewed. One review per deal.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
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
              gradient: BrokaColors.cardGradient,
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
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ]),
          )
        else
          ...pending.map((d) {
            final dId     = d.dealId;
            final seller  = d.sellerName;
            final listing = d.listingName;
            final price   = d.agreedPrice;
            final done    = d.completedAt?.toLocal();
            final dateStr = done == null ? '' : '${done.day}/${done.month}/${done.year}';
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
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
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
          _primaryButton('Continue', _pickedDealId == null ? null : () {
            _listingName = _pickedListingName ?? '';
            setState(() { _step = _ReviewStep.form; _errorMsg = null; });
          }),
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
            gradient: BrokaColors.cardGradient,
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
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            gradient: BrokaColors.cardGradient,
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
              hintStyle: TextStyle(color: BrokaColors.textMid, fontSize: 12),
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(14),
              counterStyle: TextStyle(color: BrokaColors.textMid, fontSize: 10),
            ),
          ),
        ),

        if (_errorMsg != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(message: _errorMsg!),
        ],

        const SizedBox(height: 24),
        _primaryButton('Submit Review', _submit, icon: Icons.star_rounded,
            key: const Key('submit-review')),

        const SizedBox(height: 14),
        const Center(child: Text(
          'Your review is public and helps the BROKA community.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 11),
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
        _primaryButton('Done', () => Navigator.pop(context, true)),
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
