// BROKA - the pieces every chat screen is built from.
//
// Zeno's screen, the Zeno negotiation room and the one-on-one chat each drew
// their own composer, send button and "typing" state, and each drifted: an
// opaque blue bar under one, a gold-to-blue send button on another, "Zeno is
// composing..." in italic gold on the third. These are the Zeno screen's
// versions (Home's search pill, the brand gradient), shared, so the three
// read as one app.
import 'package:flutter/material.dart';

import '../features/buy_agent/presentation/widgets/agent_hud.dart' show AgentThinkingWave;
import '../main.dart' show BrokaColors;

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

/// Zeno's avatar and its thinking waves: Zeno is working on a reply.
///
/// 2026-10-10: the Buying Agent's "Zeno is thinking", on every screen this
/// is used on (the negotiation room, the sell wizard's helpers), instead of
/// three dots - one way of showing Zeno at work, wherever Zeno is.
class ZenoTypingBubble extends StatelessWidget {
  const ZenoTypingBubble({super.key, this.label = 'Zeno is thinking'});

  final String label;

  @override
  Widget build(BuildContext context) =>
      AgentThinkingWave(label: label, avatar: true, padding: EdgeInsets.zero);
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

/// The two rooms of one conversation, under the header: the direct chat
/// with the person and Zeno's negotiation room. The only way between them
/// used to be a lone sparkle (or speech-bubble) icon among the call
/// buttons, and people did not find it - so both rooms show this labelled
/// switch, with the room they are in lit.
///
/// Compact by design (2026-10-27): it used to stretch the full width of
/// the screen at 40dp tall - a whole row of the chat given to two words,
/// and on the direct chat the Zeno orb floated over its right edge and
/// clipped "Zeno negotiates". Now it hugs its labels and floats centred:
/// same two labelled rooms, always on screen under the header, in about
/// two-thirds of the width and 34dp of height. The room you are in is the
/// gradient pill; the other stays readable (never icon-only), so nobody
/// has to guess what the sparkle means.
class ChatModeSwitch extends StatelessWidget {
  const ChatModeSwitch({
    super.key,
    required this.zenoActive,
    required this.onSwitch,
    this.unread = 0,
  });

  /// True on Zeno's room, false on the direct chat.
  final bool zenoActive;
  /// Opens the other room.
  final VoidCallback onSwitch;
  /// Unread messages waiting in the other room.
  final int unread;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
    child: Align(
      alignment: Alignment.center,
      child: Container(
        key: const Key('chat-mode-switch'),
        height: 34,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.88),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 10, offset: const Offset(0, 3)),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _segment(
            key: const Key('chat-mode-direct'),
            active: !zenoActive,
            icon: Icons.chat_bubble_outline_rounded,
            label: 'Direct',
            fullLabel: 'Direct chat',
            badge: zenoActive ? unread : 0,
          ),
          _segment(
            key: const Key('chat-mode-zeno'),
            active: zenoActive,
            icon: Icons.auto_awesome_rounded,
            label: 'Zeno',
            fullLabel: 'Zeno negotiates',
            badge: zenoActive ? 0 : unread,
          ),
        ]),
      ),
    ),
  );

  Widget _segment({
    required Key key,
    required bool active,
    required IconData icon,
    required String label,
    required String fullLabel,
    required int badge,
  }) => Semantics(
    button: !active,
    selected: active,
    label: active ? '$fullLabel, open' : 'Switch to $fullLabel',
    child: GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: active ? null : onSwitch,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          gradient: active ? const LinearGradient(colors: kChatGradient) : null,
          boxShadow: active
              ? [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.35), blurRadius: 10)]
              : null,
        ),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: active ? Colors.white : BrokaColors.textMid),
          const SizedBox(width: 5),
          Text(label,
              maxLines: 1,
              style: TextStyle(
                  color: active ? Colors.white : BrokaColors.textMid,
                  fontSize: 12, fontWeight: active ? FontWeight.w800 : FontWeight.w600)),
          // The full room name stays one tap of context away, and screen
          // readers always get it (see Semantics above).
          if (active) ...[
            const SizedBox(width: 5),
            Text(fullLabel == 'Direct chat' ? 'chat' : 'negotiates',
                maxLines: 1,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ],
          if (badge > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                  color: BrokaColors.danger, borderRadius: BorderRadius.circular(8)),
              child: Text('$badge', style: const TextStyle(
                  color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800)),
            ),
          ],
        ]),
      ),
    ),
  );
}
