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
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/network/api_client.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/listing_publisher.dart';
import '../services/photo_upload_tracker.dart';
import '../services/sell_draft_store.dart';
import '../services/sell_photo_store.dart';
import '../services/sell_wizard_data.dart';
import '../utils/price_format.dart';
import '../widgets/sell_step_scaffold.dart';
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

  const SellZenoAlertScreen({super.key, required this.data, this.publisher});
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
  String? _error;

  SellWizardData get _data => widget.data;
  bool get _still => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    _float = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));
    _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
    _celebrate = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
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

  String get _greeting {
    final name = (ApiService.currentUserName ?? '').trim().split(' ').first;
    return name.isEmpty ? 'Hi there!' : 'Hi $name!';
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
      await (widget.publisher ?? ListingPublisher()).publish(
        _data,
        lat: ApiService.currentUserLat ?? -1.286389,
        lng: ApiService.currentUserLng ?? 36.817223,
      );
      if (!mounted) return;
      unawaited(SellDraftStore.clear());
      unawaited(SellPhotoStore.clear());
      HapticFeedback.heavyImpact();
      setState(() => _live = true);
      await _celebrate.forward(from: 0);
      if (!mounted) return;
      // Clears the whole wizard stack (variable depth - and sometimes just
      // part of it, if reached through the splash screen's crash recovery)
      // rather than a single pop, so this works however the flow was entered.
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    } on PhotoUploadIncomplete catch (e) {
      _showError('$e. Check your connection and try again.');
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

  void _showError(String message) {
    if (mounted) setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final phone = maskedPhone(ApiService.currentUserPhone);
    final item = _data.name.isEmpty ? 'your listing' : '"${_data.name}"';
    return Stack(children: [
      SellStepScaffold(
        step: SellFlow.goLive, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.goLive),
        data: _data,
        error: _error,
        loading: _loading,
        onNext: _goLive,
        bottom: _LaunchButton(
          key: const Key('sell-go-live'),
          loading: _loading,
          animation: _ripple,
          onPressed: _loading ? null : _goLive,
        ),
        child: Column(children: [
          const SizedBox(height: 4),
          _zeno(),
          const SizedBox(height: 18),
          _SpeechBubble(
            still: _still,
            text: '$_greeting 👋 I\'ll look after buyers for $item. When a buyer shows up and '
                'you haven\'t replied yet, should I send you an SMS?',
          ),
          if (phone != null) ...[
            const SizedBox(height: 8),
            Text('I\'d text $phone', style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 18),
          SellChoiceCard(
            key: const Key('sell-sms-yes'),
            emoji: '📲',
            title: 'Yes, SMS me',
            subtitle: 'One text per buyer, only if you haven\'t replied - never at night.',
            selected: _data.smsAlerts == true,
            accent: BrokaColors.neonGreen,
            onTap: () => _choose(true),
          ),
          const SizedBox(height: 10),
          SellChoiceCard(
            key: const Key('sell-sms-no'),
            emoji: '🔕',
            title: "No thanks, I'll check the app",
            subtitle: 'You still get notifications in BROKA.',
            selected: _data.smsAlerts == false,
            accent: BrokaColors.neonBlue,
            onTap: () => _choose(false),
          ),
          const SizedBox(height: 16),
          _summary(),
        ]),
      ),
      if (_live)
        Positioned.fill(child: _Celebration(animation: _celebrate, name: _data.name)),
    ]);
  }

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
                      semanticLabel: 'Zeno, the BROKA broker'),
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

/// Zeno's question, typed out.
class _SpeechBubble extends StatelessWidget {
  const _SpeechBubble({required this.text, required this.still});
  final String text;
  final bool still;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<int>(
      tween: IntTween(begin: still ? text.length : 0, end: text.length),
      duration: Duration(milliseconds: still ? 0 : 22 * text.length),
      builder: (_, n, __) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(6), topRight: Radius.circular(20),
            bottomLeft: Radius.circular(20), bottomRight: Radius.circular(20),
          ),
          gradient: LinearGradient(colors: [
            BrokaColors.gold.withOpacity(0.28), BrokaColors.neonBlue.withOpacity(0.16),
          ]),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.55)),
        ),
        child: Stack(children: [
          // The full text, invisible, holds the bubble at its final size so
          // it doesn't grow line by line as it types.
          Opacity(opacity: 0, child: _text(text)),
          _text(text.substring(0, n) + (n < text.length ? '▍' : '')),
        ]),
      ),
    );
  }

  Widget _text(String s) => Text(s, style: const TextStyle(
      color: Colors.white, fontSize: 15, height: 1.45, fontWeight: FontWeight.w600));
}

class _LaunchButton extends StatelessWidget {
  const _LaunchButton({super.key, required this.loading, required this.animation, required this.onPressed});
  final bool loading;
  final Animation<double> animation;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Go live',
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
                  : const Text('GO LIVE  🚀', style: TextStyle(color: Colors.white,
                      fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1)),
            ),
          ),
        ),
      );
}

/// Confetti and a big tick: the listing is live.
class _Celebration extends StatelessWidget {
  const _Celebration({required this.animation, required this.name});
  final Animation<double> animation;
  final String name;

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
                ]),
              ),
            ]),
          );
        },
      );
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
