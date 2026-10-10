// BROKA - Sell Wizard Step 10: Go live
//
// The last step: Zeno asks whether to text the seller when a buyer shows
// up, and the listing is published from here.
//
// What "yes" means, exactly: when a buyer messages about this listing and
// the seller hasn't replied within a few minutes, BROKA sends the seller an
// SMS (the availability nudge - api/core/workers.py, once per buyer, never
// at night). That SMS always went out; there was no way to say no. The
// answer is saved on the listing (sms_alerts) and the sweep respects it.
//
// Publishing is ListingPublisher (photo ids, the cover, POST /listings with
// the draft's retry key); the draft and its kept photos are cleared once
// the listing exists.
//
// The listing fee (PRICING.md). While listing fees are on, the screen says
// up front what listing will cost ("from KES 84 a month"), and a listing
// the server creates unpaid - hidden from buyers until paid - goes straight
// on to the Listing fee screen. Paid, it celebrates as before; not paid, it
// says the listing is saved and offers to pay now or later (the Seller
// Dashboard lists it until it is paid).
//
// Texts from Zeno are premium (PRICING.md section 4). While plans are on,
// a seller whose plan has no texts left is told before answering that the
// alert will come as a notification in BROKA instead - the sweep skips the
// SMS for them - and where the plans are.
//
// 2026-10-08: and why a text is worth paying for. Under the question, a
// seller without texts sees the text Zeno would send them (the wording of
// api/core/nudge_templates.py) and that the seller who answers first is the
// one a buyer deals with; "See plans" opens the plans' case for texts
// (premium_upsell.dart) rather than dropping them on the plans screen.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/network/api_client.dart';
import '../core/utils/result.dart';
import '../features/listing_fee/data/listing_fee_repository.dart';
import '../features/listing_fee/domain/listing_fee.dart';
import '../features/listing_fee/presentation/listing_fee_screen.dart';
import '../features/premium/data/premium_repository.dart';
import '../features/premium/domain/premium.dart';
import '../features/premium/presentation/premium_upsell.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../widgets/delivery_nudge.dart';
import '../services/listing_publisher.dart';
import '../services/photo_upload_tracker.dart';
import '../services/sell_draft_store.dart';
import '../services/sell_photo_store.dart';
import '../services/sell_wizard_data.dart';
import '../services/zeno_sms_prompts.dart';
import '../utils/price_format.dart';
import '../widgets/sell_step_scaffold.dart';
import '../widgets/zeno_streaming_text.dart';
import 'sell_flow.dart';

/// "07•• ••• 123" - enough for the seller to recognise the number Zeno
/// would text, without printing it whole on a screen others may see.
String? maskedPhone(String? phone) {
  final digits = (phone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 9) return null;
  final local = digits.startsWith('254') ? '0${digits.substring(3)}' : digits;
  return '${local.substring(0, 2)}•• ••• ${local.substring(local.length - 3)}';
}

class SellZenoAlertScreen extends StatefulWidget {
  final SellWizardData data;

  /// For tests.
  final ListingPublisher? publisher;

  /// For tests: the question, instead of one picked at random.
  final String? question;

  /// For tests: the listing-fee quote and payment.
  final ListingFeeRepository? feeRepository;

  /// For tests: what the seller's plan leaves of texts.
  final PremiumRepository? premiumRepository;

  const SellZenoAlertScreen({
    super.key, required this.data, this.publisher, this.question, this.feeRepository,
    this.premiumRepository,
  });
  @override
  State<SellZenoAlertScreen> createState() => _SellZenoAlertScreenState();
}

class _SellZenoAlertScreenState extends State<SellZenoAlertScreen> with TickerProviderStateMixin {
  // Created in initState, not lazily - see _CompareSliderState.
  late final AnimationController _float;
  late final AnimationController _ripple;
  late final AnimationController _celebrate;

  bool _loading = false;
  bool _live = false;
  // The celebration has played: the "what next" buttons can show.
  bool _celebrated = false;
  String? _error;

  // Zeno's question, one of several phrasings (ZenoSmsPrompts), and
  // whether it has finished "writing" - the answers wait for it.
  String? _question;
  bool _questionDone = false;

  // What listing will cost, shown before Go live - null while fees are off
  // or the quote hasn't come (it is a courtesy, not a gate).
  ListingFeeQuote? _fee;
  // Plans are on and the seller's has no texts left: "yes" would bring a
  // notification, not an SMS, and the screen says so.
  bool _smsNeedsPlan = false;

  // The listing Go live created but that still waits for its fee: the
  // button now reopens the Listing fee screen instead of publishing again.
  String? _unpaidListingId;

  SellWizardData get _data => widget.data;
  bool get _still => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    _float = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));
    _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
    _celebrate = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
    _question = widget.question;
    _loadFee();
    _loadPlan();
    if (_question == null) {
      ZenoSmsPrompts.next(sellerName: ApiService.currentUserName, itemName: _data.name)
          .then((q) {
        if (mounted) setState(() => _question = q);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_still) {
      _float.stop();
      _ripple.stop();
    } else {
      if (!_float.isAnimating) _float.repeat(reverse: true);
      if (!_ripple.isAnimating) _ripple.repeat();
    }
  }

  @override
  void dispose() {
    _float.dispose();
    _ripple.dispose();
    _celebrate.dispose();
    super.dispose();
  }

  Future<void> _loadFee() async {
    final price = parseKesInput(_data.price);
    if (_data.isAuction || price == null || price <= 0) return;
    final r = await (widget.feeRepository ?? listingFeeRepository).quoteForDraft(
      category: _data.category,
      price: price,
      quantity: int.tryParse(_data.quantity) ?? 1,
    );
    if (!mounted) return;
    if (r case Success(:final data) when data.feesEnabled) setState(() => _fee = data);
  }

  Future<void> _loadPlan() async {
    final r = await (widget.premiumRepository ?? premiumRepository).me();
    if (!mounted) return;
    if (r case Success(:final data)) {
      setState(() => _smsNeedsPlan = !data.canUse(PremiumFeature.sms));
    }
  }

  Future<void> _seePlans() async {
    final opened = await showPremiumUpsell(context,
        message: 'Texts from Zeno come with BROKA Plus and up.',
        upgradeTo: 'plus',
        feature: PremiumFeature.sms,
        premium: widget.premiumRepository);
    if (opened && mounted) _loadPlan();
  }

  /// Opens the Listing fee screen for the listing just created, and
  /// celebrates once it is paid.
  Future<void> _payFee() async {
    final id = _unpaidListingId;
    if (id == null) return;
    final paid = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ListingFeeScreen(
        listingId: id, listingName: _data.name, afterCreate: true,
        repository: widget.feeRepository,
      ),
    ));
    if (!mounted || paid != true) return;
    setState(() {
      _unpaidListingId = null;
      _live = true;
    });
    await _celebrate.forward(from: 0);
    if (mounted) setState(() => _celebrated = true);
  }

  void _choose(bool value) {
    HapticFeedback.selectionClick();
    setState(() {
      _data.smsAlerts = value;
      _error = null;
    });
    _data.persist();
  }

  Future<void> _goLive() async {
    // One press at a time. The button shows a spinner while this runs, but
    // a second tap can land before that frame is drawn.
    if (_loading || _live) return;
    if (_unpaidListingId != null) return _payFee();
    if (_data.smsAlerts == null) {
      setState(() => _error = 'Tell Zeno yes or no first.');
      return;
    }
    for (var step = SellFlow.photos; step < SellFlow.review; step++) {
      if (!SellFlow.isComplete(step, _data)) {
        setState(() => _error = 'Go back to ${SellFlow.title(step)} - something there still needs '
            'an answer.');
        return;
      }
    }
    // A draft picked up days later can hold a closing time that has
    // passed; the server would refuse it, but the fix is on the Price step.
    final endsAt = _data.auctionEndsAt;
    if (_data.isAuction && endsAt != null && !endsAt.isAfter(DateTime.now())) {
      setState(() => _error =
          "The auction's closing time has passed. Go back to Price and choose a later one.");
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final created = await (widget.publisher ?? ListingPublisher()).publish(
        _data,
        lat: ApiService.currentUserLat ?? -1.286389,
        lng: ApiService.currentUserLng ?? 36.817223,
      );
      if (!mounted) return;
      unawaited(SellDraftStore.clear());
      unawaited(SellPhotoStore.clear());
      // Created, but hidden from buyers until its fee is paid.
      if (FeeState.fromJson(created['listing_fee'])?.unpaid == true) {
        setState(() {
          _unpaidListingId = created['id'] as String?;
          _loading = false;
        });
        await _payFee();
        return;
      }
      HapticFeedback.heavyImpact();
      setState(() => _live = true);
      await _celebrate.forward(from: 0);
      if (mounted) setState(() => _celebrated = true);
    } on PhotoUploadIncomplete catch (e) {
      _showError("Photo ${e.index + 1} couldn't be uploaded. Check your connection and try again.");
    } on ApiException catch (e) {
      _showError(e.message);
    } on TimeoutException {
      // The listing may have been created anyway. Pressing again is safe:
      // the draft's key makes the server return it, not a copy.
      _showError('No answer from BROKA - your connection may be slow. Tap Go live '
          "again: your listing won't be posted twice.");
    } catch (_) {
      _showError("Couldn't reach BROKA. Check your connection and try again.");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Leaves the wizard for Home - clearing the whole wizard stack (variable
  /// depth, and sometimes only part of it when reached through the splash
  /// screen's crash recovery) rather than one pop - and, if the seller
  /// asked, opens the Seller Dashboard on top, so Back from it is Home.
  /// Many new sellers never find the dashboard on their own; this is the
  /// moment it has something of theirs to show.
  void _leave({required bool toDashboard}) {
    final nav = Navigator.of(context);
    nav.pushNamedAndRemoveUntil('/home', (route) => false);
    if (toDashboard) nav.pushNamed('/seller-dashboard');
  }

  void _showError(String message) {
    if (mounted) setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final phone = maskedPhone(ApiService.currentUserPhone);
    return Stack(children: [
      SellStepScaffold(
        step: SellFlow.goLive, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.goLive),
        data: _data,
        error: _error,
        // Once live there's no going back into the wizard: the draft is
        // gone, and the way out is the celebration's buttons.
        loading: _loading || _live,
        onNext: _goLive,
        bottom: _LaunchButton(
          key: const Key('sell-go-live'),
          loading: _loading,
          animation: _ripple,
          label: _unpaidListingId != null ? 'PAY TO GO LIVE' : 'GO LIVE  🚀',
          onPressed: _loading ? null : _goLive,
        ),
        child: Column(children: [
          const SizedBox(height: 4),
          _zeno(),
          const SizedBox(height: 18),
          ZenoStreamingBubble(
            key: const Key('zeno-question'),
            text: _question,
            onDone: () {
              if (mounted) setState(() => _questionDone = true);
            },
          ),
          // The answers arrive once Zeno has finished asking.
          _AfterQuestion(
            visible: _questionDone,
            index: 0,
            child: phone == null
                ? const SizedBox(height: 18)
                : Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 18),
                    child: Text('I\'d text $phone', style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
          ),
          _AfterQuestion(
            visible: _questionDone,
            index: 1,
            child: SellChoiceCard(
              key: const Key('sell-sms-yes'),
              emoji: '📲',
              title: 'Yes, SMS me',
              subtitle: _smsNeedsPlan
                  ? 'Texts come with a BROKA plan - they reach you even with the app closed and no '
                      'data. Without one, Zeno tells you in BROKA instead.'
                  : 'One text per buyer, only if you haven\'t replied - never at night.',
              selected: _data.smsAlerts == true,
              accent: BrokaColors.neonGreen,
              onTap: () => _choose(true),
            ),
          ),
          SellGap.item,
          _AfterQuestion(
            visible: _questionDone,
            index: 2,
            child: SellChoiceCard(
              key: const Key('sell-sms-no'),
              emoji: '🔕',
              title: "No thanks, I'll check the app",
              subtitle: 'You still get notifications in BROKA.',
              selected: _data.smsAlerts == false,
              accent: BrokaColors.neonBlue,
              onTap: () => _choose(false),
            ),
          ),
          if (_smsNeedsPlan)
            _AfterQuestion(
              visible: _questionDone,
              index: 3,
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _SmsPitch(
                  listingName: _data.name,
                  firstName: (ApiService.currentUserName ?? '').trim().split(' ').first,
                  onPlans: _seePlans,
                ),
              ),
            ),
          SellGap.section,
          _summary(),
          if (_unpaidListingId != null) _savedUnpaid()
          else if (_fee != null) _feeTeaser(_fee!),
        ]),
      ),
      if (_live)
        Positioned.fill(child: _Celebration(
          animation: _celebrate,
          name: _data.name,
          showActions: _celebrated,
          onDashboard: () => _leave(toDashboard: true),
          onHome: () => _leave(toDashboard: false),
        )),
    ]);
  }

  /// "Listing fee from KES 84 a month" - so the price is no surprise.
  Widget _feeTeaser(ListingFeeQuote fee) => Padding(
        key: const Key('sell-fee-teaser'),
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          'Listing fee KES ${formatKesAmount(fee.monthlyFee)} a month'
          '${fee.discountPercent > 0 ? ' (${fee.discountPercent}% off)' : ''}'
          ' - choose 1 to 6 months next.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
        ),
      );

  /// Created, not paid: where it is, and the way back to paying later.
  Widget _savedUnpaid() => Padding(
        key: const Key('sell-saved-unpaid'),
        padding: const EdgeInsets.only(top: 14),
        child: Column(children: [
          const Text('Your listing is saved. Buyers see it once the listing fee is paid.',
              textAlign: TextAlign.center,
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w700)),
          TextButton(
            key: const Key('sell-pay-later'),
            onPressed: () => _leave(toDashboard: true),
            child: const Text('Pay later - it waits in your Seller Dashboard',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
          ),
        ]),
      );

  Widget _summary() {
    final amount = parseKesInput(_data.price);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.verified_rounded, color: BrokaColors.gold, size: 15),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          '${_data.verifiedPhotos.length} verified photos · '
          '${amount == null ? '' : formatKes(amount)}${_data.priceUnit == null ? '' : ' / ${_data.priceUnit}'}'
          ' · ${_data.location}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
        ),
      ),
    ]);
  }

  Widget _zeno() {
    return SizedBox(
      width: 230, height: 230,
      child: AnimatedBuilder(
        animation: Listenable.merge([_float, _ripple]),
        builder: (_, __) {
          final bob = _still ? 0.0 : sin(_float.value * pi) * 8 - 4;
          return Stack(alignment: Alignment.center, children: [
            // Ripples: rings leaving Zeno like a signal going out.
            for (var i = 0; i < 3; i++)
              _rippleRing((_ripple.value + i / 3) % 1.0),
            // Message bubbles orbiting.
            for (var i = 0; i < 3; i++)
              _orbitingIcon(i),
            Transform.translate(
              offset: Offset(0, bob),
              child: Container(
                width: 168, height: 168,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: BrokaColors.gold.withOpacity(0.55), blurRadius: 36),
                    BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.35), blurRadius: 60),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset('assets/images/zeno_full.png', fit: BoxFit.cover,
                      semanticLabel: "Zeno, BROKA's personal assistant"),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _rippleRing(double t) {
    if (_still) return const SizedBox.shrink();
    final size = 168 + 62 * t;
    return IgnorePointer(
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Color.lerp(BrokaColors.gold, BrokaColors.neonCyan, t)!.withOpacity(0.55 * (1 - t)),
            width: 2,
          ),
        ),
      ),
    );
  }

  Widget _orbitingIcon(int i) {
    const icons = ['💬', '📲', '🔔'];
    final angle = (_still ? 0.0 : _ripple.value * 2 * pi * 0.5) + i * 2 * pi / 3;
    const radius = 104.0;
    return Transform.translate(
      offset: Offset(cos(angle) * radius, sin(angle) * radius * 0.55),
      child: Container(
        width: 34, height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: BrokaColors.bgCard,
          border: Border.all(color: BrokaColors.gold.withOpacity(0.6)),
          boxShadow: const [BrokaColors.glowGold],
        ),
        child: Text(icons[i], style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}

class _LaunchButton extends StatelessWidget {
  const _LaunchButton({
    super.key, required this.loading, required this.animation, required this.onPressed,
    required this.label,
  });
  final bool loading;
  final Animation<double> animation;
  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onPressed,
          child: AnimatedBuilder(
            animation: animation,
            builder: (_, __) => Container(
              height: 58,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                    colors: [Color(0xFF8B5CF6), Color(0xFF3B82F6), Color(0xFF22D3EE)]),
                boxShadow: [BoxShadow(
                    color: BrokaColors.gold.withOpacity(0.3 + 0.25 * sin(animation.value * 2 * pi)),
                    blurRadius: 24)],
              ),
              alignment: Alignment.center,
              child: loading
                  ? const SizedBox(width: 22, height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                  : Text(label, style: const TextStyle(color: Colors.white,
                      fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1)),
            ),
          ),
        ),
      );
}

/// Confetti and a big tick: the listing is live.
class _Celebration extends StatelessWidget {
  const _Celebration({
    required this.animation,
    required this.name,
    required this.showActions,
    required this.onDashboard,
    required this.onHome,
  });
  final Animation<double> animation;
  final String name;
  // Once the confetti has flown: the seller chooses where to go next.
  final bool showActions;
  final VoidCallback onDashboard;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: animation,
        builder: (_, __) {
          final t = animation.value;
          final pop = Curves.elasticOut.transform((t * 1.6).clamp(0.0, 1.0));
          return Container(
            color: const Color(0xE603040A),
            child: Stack(children: [
              Positioned.fill(child: CustomPaint(painter: _ConfettiPainter(t))),
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Transform.scale(
                      scale: pop,
                      child: Container(
                        width: 110, height: 110,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [BrokaColors.neonGreen, BrokaColors.neonCyan]),
                          boxShadow: [BoxShadow(color: Color(0x8810B981), blurRadius: 40)],
                        ),
                        child: const Icon(Icons.check_rounded, color: Colors.white, size: 64),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Opacity(
                      opacity: (t * 2).clamp(0.0, 1.0),
                      child: Column(children: [
                        const Text('Your listing is live!', style: TextStyle(color: Colors.white,
                            fontSize: 22, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
                      ]),
                    ),
                    // Buyers are about to write: make sure this phone hears
                    // them (shows only when it can't - delivery_nudge.dart).
                    if (showActions) const DeliveryNudge.listingLive(),
                    _WhatNext(
                      visible: showActions,
                      onDashboard: onDashboard,
                      onHome: onHome,
                    ),
                  ]),
                ),
              ),
            ]),
          );
        },
      );
}

/// Where to go once the listing is live: the Seller Dashboard - offered,
/// with a line on what it's for, because new sellers don't know it exists -
/// or straight back Home.
class _WhatNext extends StatelessWidget {
  const _WhatNext({required this.visible, required this.onDashboard, required this.onHome});
  final bool visible;
  final VoidCallback onDashboard;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final buttons = Padding(
      padding: const EdgeInsets.only(top: 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('sell-open-dashboard'),
              borderRadius: BorderRadius.circular(20),
              onTap: onDashboard,
              child: Ink(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(colors: [
                    BrokaColors.gold.withOpacity(0.32), BrokaColors.neonBlue.withOpacity(0.22),
                  ]),
                  border: Border.all(color: BrokaColors.gold.withOpacity(0.7), width: 1.4),
                  boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.25), blurRadius: 24)],
                ),
                child: Row(children: [
                  Container(
                    width: 46, height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.08),
                      border: Border.all(color: BrokaColors.gold.withOpacity(0.5)),
                    ),
                    child: const Text('📊', style: TextStyle(fontSize: 22)),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Open my Seller Dashboard', style: TextStyle(color: Colors.white,
                          fontSize: 15.5, fontWeight: FontWeight.w900)),
                      SizedBox(height: 3),
                      Text('Track views, buyer interest and deals - and get Zeno\'s tips on '
                          'pricing.', style: TextStyle(color: BrokaColors.textMid,
                          fontSize: 12, height: 1.35)),
                    ]),
                  ),
                  const Icon(Icons.arrow_forward_rounded, color: BrokaColors.gold),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            key: const Key('sell-back-home'),
            onPressed: onHome,
            style: TextButton.styleFrom(
              foregroundColor: BrokaColors.textMid,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text('Back to Home', style: TextStyle(fontSize: 14,
                fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
    // Rises in under the headline. (No AnimatedSize: at zero duration,
    // under reduced motion, it re-dirties its own layout and asserts.)
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return buttons;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 24 * (1 - v)), child: child),
      ),
      child: buttons,
    );
  }
}

/// Fades and lifts [child] in once [visible] - the answers under Zeno's
/// question, one after another by [index]. Hidden, it takes no taps.
class _AfterQuestion extends StatelessWidget {
  const _AfterQuestion({required this.visible, required this.index, required this.child});
  final bool visible;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = still ? Duration.zero : Duration(milliseconds: 380 + index * 140);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, 0.25),
        duration: duration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: duration,
          curve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.t);
  final double t;
  static final _pieces = List.generate(70, (i) {
    final r = Random(i * 31 + 7);
    return (
      angle: r.nextDouble() * 2 * pi,
      speed: 0.35 + r.nextDouble() * 0.65,
      spin: r.nextDouble() * 8 - 4,
      color: const [BrokaColors.gold, BrokaColors.neonCyan, BrokaColors.neonPink,
          BrokaColors.neonGreen, Color(0xFFFFD166)][i % 5],
      w: 5.0 + r.nextDouble() * 5,
    );
  });

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height * 0.42);
    final reach = size.longestSide * 0.62;
    for (final p in _pieces) {
      final d = reach * p.speed * Curves.easeOutCubic.transform(t);
      final gravity = 260 * t * t;
      final pos = origin + Offset(cos(p.angle) * d, sin(p.angle) * d + gravity);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.spin * t * pi);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.w, height: p.w * 0.45),
          Paint()..color = p.color.withOpacity((1 - t * 0.7).clamp(0.0, 1.0)));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) => oldDelegate.t != t;
}


/// What a text from Zeno looks like, and why a seller wants one: shown to a
/// seller whose plan has no texts, under the question.
class _SmsPitch extends StatelessWidget {
  const _SmsPitch({required this.listingName, required this.firstName, required this.onPlans});
  final String listingName;
  final String firstName;
  final VoidCallback onPlans;

  @override
  Widget build(BuildContext context) {
    final who = firstName.isEmpty ? '' : ' $firstName';
    final what = listingName.trim().isEmpty ? 'item' : listingName.trim();
    return SellCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('WHAT ZENO WOULD TEXT YOU', style: TextStyle(
            color: BrokaColors.neonGreen, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
        const SizedBox(height: 10),
        // An SMS bubble, as the phone's own messages app shows one.
        Container(
          key: const Key('sell-sms-preview'),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2F3A),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4), topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16)),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.sms_rounded, size: 14, color: BrokaColors.neonGreen),
              SizedBox(width: 6),
              Text('BROKA', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
              Spacer(),
              Text('now', style: TextStyle(color: BrokaColors.textMid, fontSize: 11)),
            ]),
            const SizedBox(height: 6),
            Text('Hi$who. Zeno from BROKA: a buyer wants your $what. Still available at the same '
                'price? Reply in the BROKA app to continue.',
                style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.45)),
          ]),
        ),
        const SizedBox(height: 14),
        const Text(
          'Buyers ask several sellers at once. The one who answers first is the one they deal with - '
          'a text reaches you even with the app closed and no data.',
          style: TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, height: 1.45),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('sell-sms-plans'),
            onPressed: onPlans,
            icon: const Icon(Icons.workspace_premium_rounded, color: BrokaColors.gold, size: 18),
            label: const Text('Get texts from Zeno', style: TextStyle(
                color: BrokaColors.gold, fontSize: 13.5, fontWeight: FontWeight.w800)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              side: BorderSide(color: BrokaColors.gold.withOpacity(0.6)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ]),
    );
  }
}
