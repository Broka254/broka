// BROKA - the pieces every chat screen is built from.
//
// Zeno's screen, the Zeno negotiation room and the one-on-one chat each drew
// their own composer, send button and "typing" state, and each drifted: an
// opaque blue bar under one, a gold-to-blue send button on another, "Zeno is
// composing..." in italic gold on the third. These are shared, so the three
// read as one app: the composer card (2026-11-09; it was Home's search
// pill), the brand gradient, Zeno's thinking waves.
import 'package:flutter/material.dart';

import '../features/buy_agent/presentation/widgets/agent_hud.dart' show AgentThinkingWave;
import '../main.dart' show BrokaColors;

/// Zeno's colours - the brand gradient Home's Zeno CTA and the splash use.
const List<Color> kChatGradient = [BrokaColors.neonPurple, BrokaColors.neonBlue];

/// The brand gradient as the chat wears it (2026-11-11): the same violet to
/// blue, a few shades deeper. At full neon every bubble, photo frame and
/// button of mine glowed, and the brightest things on screen were frames
/// rather than what was in them. White text on it reads at 5.8:1 or better
/// (on the neon it was 3.7:1).
const List<Color> kChatCalmGradient = [Color(0xFF5B3FC4), Color(0xFF2F5FC8)];

/// The chat composer (2026-11-09): a rounded card with the message on top
/// and a row of actions under it - the way DeepSeek's and ChatGPT's read.
/// It replaced a single pill that held its icons inside the text line:
/// they shrank the text, and a photo button, a microphone and a send
/// button competed for the same few millimetres beside it.
///
/// [leading] are labelled chips (Photos, Document, Make an offer), the
/// shortcuts a person looks for; [trailing] the round buttons - attach,
/// the microphone, and the send button that takes its place once there is
/// something to send. [top] sits above the text: a photo waiting to go.
class ChatComposerCard extends StatelessWidget {
  const ChatComposerCard({
    super.key,
    required this.focused,
    required this.field,
    this.top,
    this.leading = const [],
    this.trailing = const [],
  });

  final bool focused;
  final Widget field;
  final Widget? top;
  final List<Widget> leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 160),
    padding: const EdgeInsets.fromLTRB(14, 6, 8, 8),
    // A quiet edge until it is typed in (2026-11-11: a lit blue ring sat
    // round it all the time); the focus ring is still plain to see.
    decoration: BoxDecoration(
      color: BrokaColors.bgCard.withOpacity(0.94),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: focused ? BrokaColors.neonBlue.withOpacity(0.55) : BrokaColors.border,
        width: focused ? 1.3 : 1.0,
      ),
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.28), blurRadius: 16, offset: const Offset(0, 4)),
        if (focused)
          BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.08), blurRadius: 10),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (top != null) top!,
        Padding(padding: const EdgeInsets.only(right: 6), child: field),
        const SizedBox(height: 4),
        Row(children: [
          // Scrolls rather than overflows: two chips on a 320dp phone at a
          // large text size still fit beside the buttons, and a third one
          // would scroll instead of breaking the row.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (var i = 0; i < leading.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  leading[i],
                ],
              ]),
            ),
          ),
          for (final t in trailing) ...[const SizedBox(width: 6), t],
        ]),
      ],
    ),
  );
}

/// A labelled shortcut in the composer's action row: an icon and a word,
/// in the accent's tint (DeepSeek's "Think" and "Search" chips).
class ChatComposerChip extends StatelessWidget {
  const ChatComposerChip({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.color = BrokaColors.neonBlue,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final Color color;

  /// On (a mode that is in force).
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          // A tint, not a light: the word and its icon carry the colour.
          decoration: BoxDecoration(
            color: color.withOpacity(active ? 0.18 : 0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: color.withOpacity(active ? 0.6 : 0.28)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label,
                maxLines: 1,
                style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    ),
  );
}

/// A round outlined button in the composer's action row: attach, the
/// microphone - the "+" and the voice button of DeepSeek's composer.
class ChatComposerIconButton extends StatelessWidget {
  const ChatComposerIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  /// Lit (voice mode is open, say).
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? BrokaColors.neonBlue.withOpacity(0.18) : null,
            border: Border.all(
              color: active
                  ? BrokaColors.neonBlue.withOpacity(0.8)
                  : BrokaColors.textHigh.withOpacity(0.3),
              width: 1.2,
            ),
          ),
          child: Icon(icon,
              size: 20, color: active ? BrokaColors.neonBlue : BrokaColors.textHigh),
        ),
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
    this.size = 50,
  });

  final bool visible;
  final VoidCallback? onTap;
  final bool busy;

  /// Its diameter: 50 beside a bar, 38 in the composer card's action row.
  final double size;

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
        padding: EdgeInsets.only(left: size < 50 ? 4 : 8),
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
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: kChatCalmGradient,
                ),
                boxShadow: [
                  BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.18), blurRadius: 8),
                ],
              ),
              child: busy
                  ? const Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white)))
                  : Icon(Icons.arrow_upward_rounded, color: Colors.white, size: size < 50 ? 20 : 22),
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

/// The frame of the user's own message - text, voice note or photo: the
/// chat's gradient (kChatCalmGradient), with a soft shadow under it where a
/// blue glow used to bleed round every bubble and photo.
BoxDecoration myBubbleDecoration({bool tailRight = true}) => BoxDecoration(
  gradient: const LinearGradient(
      begin: Alignment.topLeft, end: Alignment.bottomRight, colors: kChatCalmGradient),
  borderRadius: BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: Radius.circular(tailRight ? 4 : 16),
      bottomLeft: const Radius.circular(16),
      bottomRight: const Radius.circular(16)),
  boxShadow: [
    BoxShadow(color: Colors.black.withOpacity(0.22), blurRadius: 8, offset: const Offset(0, 2)),
  ],
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
          gradient: active ? const LinearGradient(colors: kChatCalmGradient) : null,
          boxShadow: active
              ? [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.16), blurRadius: 6)]
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
