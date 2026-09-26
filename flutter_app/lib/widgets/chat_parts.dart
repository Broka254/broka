// BROKA - the pieces every chat screen is built from.
//
// Zeno's screen, the Zeno negotiation room and the one-on-one chat each drew
// their own composer, send button and "typing" state, and each drifted: an
// opaque blue bar under one, a gold-to-blue send button on another, "Zeno is
// composing..." in italic gold on the third. These are the Zeno screen's
// versions (Home's search pill, the brand gradient), shared, so the three
// read as one app.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;
import 'zeno_avatar.dart';

/// Zeno's colours - the brand gradient Home's Zeno CTA and the splash use.
const List<Color> kChatGradient = [BrokaColors.neonPurple, BrokaColors.neonBlue];

/// Home's search pill as a chat composer: the same fill, outline and focus
/// glow, so typing a message looks like typing anywhere else in BROKA.
class ChatComposerPill extends StatelessWidget {
  const ChatComposerPill({super.key, required this.focused, required this.child});

  final bool focused;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 160),
    constraints: const BoxConstraints(minHeight: 50),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard.withOpacity(0.92),
      borderRadius: BorderRadius.circular(26),
      border: Border.all(
        color: BrokaColors.neonBlue.withOpacity(focused ? 0.85 : 0.45),
        width: focused ? 1.6 : 1.2,
      ),
      boxShadow: focused
          ? [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.18), blurRadius: 14)]
          : null,
    ),
    child: child,
  );
}

/// An icon inside the composer pill - attach a photo, record, make an offer.
class ChatComposerAction extends StatelessWidget {
  const ChatComposerAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.leading = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Lit (the voice card is open, say).
  final bool active;

  /// Which end of the pill it sits at, for its padding.
  final bool leading;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkResponse(
      onTap: onTap,
      radius: 22,
      child: Padding(
        padding: leading
            ? const EdgeInsets.fromLTRB(14, 13, 6, 13)
            : const EdgeInsets.fromLTRB(6, 13, 14, 13),
        child: Icon(icon,
            size: 22, color: active ? BrokaColors.neonBlue : BrokaColors.textMid),
      ),
    ),
  );
}

/// The round send button. It scales in only once there is something to
/// send - an always-on send button beside an empty field is dead weight -
/// and spins while a message is on its way. Hidden, it takes no room, so
/// the composer spans the whole row.
class ChatSendButton extends StatelessWidget {
  const ChatSendButton({
    super.key,
    required this.visible,
    required this.onTap,
    this.busy = false,
  });

  final bool visible;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final shown = visible || busy;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: shown ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      builder: (_, room, child) => ClipRect(
        child: Align(alignment: Alignment.centerRight, widthFactor: room, child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: _button(shown),
      ),
    );
  }

  Widget _button(bool shown) {
    return AnimatedScale(
      scale: shown ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutBack,
      child: AnimatedOpacity(
        opacity: shown ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 140),
        child: Semantics(
          button: true,
          label: 'Send',
          child: GestureDetector(
            onTap: (busy || !visible) ? null : onTap,
            child: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: kChatGradient,
                ),
                boxShadow: [
                  BoxShadow(
                      color: BrokaColors.neonBlue.withOpacity(0.35),
                      blurRadius: 14,
                      spreadRadius: 1),
                ],
              ),
              child: busy
                  ? const Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white)))
                  : const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

/// Three dots rising and falling in turn while Zeno thinks.
///
/// The old dots were three one-shot fades that finished after 600ms and
/// then sat still, so a slow reply looked like a frozen one.
class ChatTypingDots extends StatefulWidget {
  const ChatTypingDots({super.key});

  @override
  State<ChatTypingDots> createState() => _ChatTypingDotsState();
}

class _ChatTypingDotsState extends State<ChatTypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < 3; i++) ...[
        if (i > 0) const SizedBox(width: 5),
        Opacity(
          opacity: 0.35 +
              0.65 * (0.5 + 0.5 * math.sin(2 * math.pi * (_c.value - i * 0.18))),
          child: Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: kChatGradient),
            ),
          ),
        ),
      ],
    ]),
  );
}

/// Zeno's avatar and a bubble of typing dots: Zeno is working on a reply.
class ZenoTypingBubble extends StatelessWidget {
  const ZenoTypingBubble({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Zeno is typing',
    child: Row(children: [
      const ZenoAvatar(size: 28),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.92),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.30)),
        ),
        child: const ChatTypingDots(),
      ),
    ]),
  );
}

/// The frame of one of Zeno's messages: a dark card with a violet edge,
/// its corner tucked towards Zeno's avatar.
BoxDecoration zenoBubbleDecoration() => BoxDecoration(
  color: BrokaColors.bgCard.withOpacity(0.92),
  borderRadius: const BorderRadius.only(
      topLeft: Radius.circular(4),
      topRight: Radius.circular(16),
      bottomLeft: Radius.circular(16),
      bottomRight: Radius.circular(16)),
  border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.30)),
);

/// The frame of the user's own message: the brand gradient.
BoxDecoration myBubbleDecoration({bool tailRight = true}) => BoxDecoration(
  gradient: const LinearGradient(
      begin: Alignment.topLeft, end: Alignment.bottomRight, colors: kChatGradient),
  borderRadius: BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: Radius.circular(tailRight ? 4 : 16),
      bottomLeft: const Radius.circular(16),
      bottomRight: const Radius.circular(16)),
  boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.18), blurRadius: 10)],
);

/// The frame of the other person's message: a card like Home's.
BoxDecoration theirBubbleDecoration() => BoxDecoration(
  color: BrokaColors.bgCard.withOpacity(0.92),
  borderRadius: const BorderRadius.only(
      topLeft: Radius.circular(4),
      topRight: Radius.circular(16),
      bottomLeft: Radius.circular(16),
      bottomRight: Radius.circular(16)),
  border: Border.all(color: BrokaColors.border),
);
