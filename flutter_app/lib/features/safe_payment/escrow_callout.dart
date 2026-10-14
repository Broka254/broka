// "Pay with escrow" - the callout every place a deal is struck carries
// (2026-10-08): Home, a listing, both deal chats, the store cart, the Menu
// and How BROKA works.
//
// It has to be impossible to miss. With BROKA holding no payments, the
// buyer who never sees it pays a stranger by M-Pesa and hopes - and that
// buyer's lost money is what a first-time BROKA user remembers. So it is
// loud by design: escrow green on a glowing border, a shine that crosses
// it once as it appears, and Zeno named on it, so the user also learns
// that Zeno will walk them through it (zeno_assistant/escrow_walkthrough).
//
// The shine runs once, not in a loop: a looping animation never lets a
// screen settle, which costs battery and stalls every widget test that
// waits for one.

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../theme/motion.dart';
import 'safe_payment.dart';

class EscrowCallout extends StatefulWidget {
  const EscrowCallout({
    super.key,
    this.compact = false,
    this.title = 'Pay with escrow',
    this.subtitle = 'Your money is held until you have the item. Zeno walks you through it, step by step.',
    this.onOpen,
    this.onZeno,
    this.margin = EdgeInsets.zero,
  });

  /// One line, for the deal chats: the full card would push the
  /// conversation off a small phone.
  final bool compact;
  final String title;
  final String subtitle;

  /// What tapping it does: the escrow services by default. Tests pass
  /// their own.
  final VoidCallback? onOpen;

  /// "Ask Zeno": the walkthrough by default.
  final VoidCallback? onZeno;
  final EdgeInsetsGeometry margin;

  @override
  State<EscrowCallout> createState() => _EscrowCalloutState();
}

class _EscrowCalloutState extends State<EscrowCallout> with SingleTickerProviderStateMixin {
  late final AnimationController _shine = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
        _shine.value = 1;
      } else {
        _shine.forward();
      }
    });
  }

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  void _open() => (widget.onOpen ?? () => openEscrowServices(context))();
  void _zeno() => (widget.onZeno ?? () => openZenoEscrowGuide(context))();

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.compact ? 14 : 18);
    final body = widget.compact ? _compact() : _full();
    return Padding(
      padding: widget.margin,
      child: Semantics(
        button: true,
        label: '${widget.title}. ${widget.subtitle}',
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [BrokaColors.neonGreen.withOpacity(0.28), BrokaColors.bgCard.withOpacity(0.96),
                  BrokaColors.neonCyan.withOpacity(0.16)],
            ),
            border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.75), width: 1.4),
            boxShadow: [BoxShadow(color: BrokaColors.neonGreen.withOpacity(0.28), blurRadius: 20, spreadRadius: 1)],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(children: [
              Material(
                color: Colors.transparent,
                child: InkWell(onTap: _open, child: body),
              ),
              // The one-time shine: a soft band crossing left to right.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _shine,
                    builder: (_, __) {
                      final t = BrokaMotion.enter.transform(_shine.value);
                      if (t >= 1) return const SizedBox.shrink();
                      return FractionalTranslation(
                        translation: Offset(-1 + 2.2 * t, 0),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [
                              Colors.white.withOpacity(0),
                              Colors.white.withOpacity(0.16),
                              Colors.white.withOpacity(0),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _shield(double size) => Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: BrokaColors.neonGreen.withOpacity(0.2),
          boxShadow: [BoxShadow(color: BrokaColors.neonGreen.withOpacity(0.45), blurRadius: 14)],
        ),
        child: Icon(Icons.shield_rounded, color: BrokaColors.neonGreen, size: size * 0.56),
      );

  Widget _zenoPill() => Material(
        color: BrokaColors.neonPurple,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: _zeno,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.auto_awesome_rounded, size: 14, color: Colors.white),
              SizedBox(width: 5),
              Text('Ask Zeno', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
            ]),
          ),
        ),
      );

  Widget _compact() => Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(children: [
          _shield(30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(widget.title, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 13.5, fontWeight: FontWeight.w900)),
              const Text('Money held until you have it · Zeno guides you',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
            ]),
          ),
          const SizedBox(width: 6),
          _zenoPill(),
        ]),
      );

  Widget _full() => Padding(
        padding: const EdgeInsets.all(15),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _shield(42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(widget.title, style: const TextStyle(
                        color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: BrokaColors.neonGreen, borderRadius: BorderRadius.circular(6)),
                    child: const Text('SAFEST', style: TextStyle(
                        color: BrokaColors.bg, fontSize: 9.5, fontWeight: FontWeight.w900, letterSpacing: 0.8)),
                  ),
                ]),
                const SizedBox(height: 3),
                Text(widget.subtitle, style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            const Expanded(
              child: Text('See escrow services  ›', style: TextStyle(
                  color: BrokaColors.neonGreen, fontSize: 13, fontWeight: FontWeight.w800)),
            ),
            _zenoPill(),
          ]),
        ]),
      );
}
