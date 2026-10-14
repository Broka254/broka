// BROKA - Message receipt indicator
//
// WhatsApp-style delivery/read ticks, plus one state that only makes sense
// on BROKA.
//
// The four-state ladder (sending -> sent -> delivered -> read) exists
// because "it didn't send" and "they're ignoring me" feel identical to a
// user when there's nothing on screen to tell them apart, and that
// ambiguity is where chat anxiety comes from. Each step answers a
// different question: did it leave my phone, did it reach theirs, did they
// look at it.
//
// The fifth state, `relayed`, is BROKA's own and has no WhatsApp
// equivalent. When you write to Zeno rather than to the other party
// directly, Zeno decides whether anything in your message needs passing on
// and, if so, relays the CONCRETE FACT - not your words. Without a marker
// for that, people reasonably assume the seller read what they typed, and
// are then confused when the reply doesn't match what they said. `relayed`
// says plainly: Zeno passed this on in its own words. That distinction is
// load-bearing for the whole mediated-chat model, so it gets its own tick
// rather than being flattened into "sent".

import 'package:flutter/material.dart';
import '../main.dart';

enum MessageReceipt {
  /// Queued locally, not yet acknowledged by the server.
  sending,

  /// The server has it. It exists, durably, but the recipient's device
  /// hasn't confirmed picking it up.
  sent,

  /// The recipient's device has it. Their app fetched or streamed this
  /// message; they may not have looked.
  delivered,

  /// The recipient had this thread open, on screen, at or after the moment
  /// this message arrived.
  read,

  /// BROKA-specific: sent through Zeno, who relayed the substance to the
  /// other party in its own words rather than forwarding the text.
  relayed,

  /// Failed to leave the device (no connection, server rejected it).
  failed,
}

class MessageReceiptIcon extends StatelessWidget {
  final MessageReceipt receipt;

  /// Receipts are only ever shown on your OWN messages - showing a tick on
  /// someone else's bubble is meaningless, and on a marketplace it would
  /// also tell them when you read things, which isn't theirs to know.
  const MessageReceiptIcon({super.key, required this.receipt});

  // ── Legibility ────────────────────────────────────────────────────────────
  //
  // `sent` and `delivered` were drawn in BrokaColors.textLow (#2E3D5A) on
  // the near-black chat background (#03040A). Measured, that is 1.88:1 -
  // well under the 3:1 minimum for a UI component carrying meaning. The two
  // states a user checks most often were the two closest to invisible, so
  // the honest four-state ladder built underneath was being thrown away at
  // the last step.
  //
  // textMid (#8A9BBF) measures 7.33:1 on the same background. `read` keeps
  // the violet (4.84:1) and `failed` the red (5.44:1) - both already passed.
  static const _muted  = BrokaColors.textMid;
  static const _iconPx = 15.0;   // was 12: a tick is a glyph, not a dot

  @override
  Widget build(BuildContext context) {
    switch (receipt) {
      case MessageReceipt.sending:
        return const _Labelled(
          icon: Icons.schedule_rounded,
          color: _muted,
          size: 13,
          label: 'Sending',
          semantics: 'Sending',
        );

      case MessageReceipt.failed:
        // The one state that costs the user something if they miss it.
        // A bare 12px icon asked them to notice an absence of progress;
        // this states the problem and what to do about it.
        return const _Labelled(
          icon: Icons.error_outline_rounded,
          color: BrokaColors.danger,
          size: 15,
          // Short, so it fits beside the role label on a narrow phone. The
          // bubble itself is what is tapped to try again or delete it
          // (negotiation_screen's _onUnsentTap), and a snackbar says so
          // when a send fails.
          label: 'Not sent',
          semantics: 'Not sent',
          bold: true,
        );

      case MessageReceipt.sent:
        return const _Tick(
          icon: Icons.check_rounded, color: _muted, size: _iconPx,
          semantics: 'Sent',
        );

      case MessageReceipt.delivered:
        return const _DoubleTick(color: _muted, semantics: 'Delivered');

      case MessageReceipt.read:
        // BROKA's violet rather than WhatsApp's blue - same grammar, so it
        // reads instantly to anyone who has used a messenger, but it
        // belongs to this app's palette. Slightly heavier than the muted
        // ticks so "seen" is the state that catches the eye, which is the
        // one people scan a thread looking for.
        return const _DoubleTick(
            color: BrokaColors.gold, semantics: 'Seen', emphasised: true);

      case MessageReceipt.relayed:
        return const _Labelled(
          icon: Icons.auto_awesome_rounded,
          color: BrokaColors.neonBlue,
          size: 12,
          label: 'relayed',
          semantics: 'Relayed by Zeno in its own words',
        );
    }
  }
}

/// Icon plus a short word. Used for the states that are transient or
/// actionable, where a glyph alone makes the user learn a vocabulary to
/// find out something urgent.
class _Labelled extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final String label;
  final String semantics;
  final bool bold;
  const _Labelled({
    required this.icon, required this.color, required this.size,
    required this.label, required this.semantics, this.bold = false,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        label: semantics,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: size, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 10,
                  height: 1.0,
                  color: color,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w600)),
        ]),
      );
}

class _Tick extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final String semantics;
  const _Tick({required this.icon, required this.color,
      this.size = 15, required this.semantics});

  @override
  Widget build(BuildContext context) =>
      Semantics(label: semantics, child: Icon(icon, size: size, color: color));
}

/// Two checks, overlapping enough to read as one glyph but not so much that
/// they read as one CHECK.
///
/// The previous version stacked 12px icons 5px apart, which hid most of the
/// second tick behind the first - at that size "delivered" and "sent" were
/// separable only by looking for a thickened edge. 15px icons 7px apart
/// keeps the compact single-glyph shape while leaving both ticks visible.
class _DoubleTick extends StatelessWidget {
  final Color color;
  final String semantics;
  final bool emphasised;
  const _DoubleTick({
    required this.color, required this.semantics, this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    // Size, not Icon.weight: `weight` only applies to variable icon fonts
    // (Material Symbols). With the default MaterialIcons font it is silently
    // ignored, so it would look like emphasis had been added while changing
    // nothing on screen.
    final size = emphasised ? MessageReceiptIcon._iconPx + 1 : MessageReceiptIcon._iconPx;
    return Semantics(
      label: semantics,
      child: SizedBox(
        width: size + 7,
        height: size,
        child: Stack(children: [
          Positioned(left: 0, top: 0,
              child: Icon(Icons.check_rounded, size: size, color: color)),
          Positioned(left: 7, top: 0,
              child: Icon(Icons.check_rounded, size: size, color: color)),
        ]),
      ),
    );
  }
}

/// How long a message may sit un-acknowledged before it reads "Not sent".
const staleSendAfter = Duration(seconds: 20);

/// Derives a receipt from the thread's two counterpart watermarks.
///
/// This is the whole reason the backend stores watermarks instead of a
/// status column per message: one timestamp comparison gives every message
/// in the thread its state, with no per-message writes and no extra query
/// as the thread grows.
MessageReceipt receiptFor({
  required DateTime? sentAt,
  required DateTime? counterpartDeliveredAt,
  required DateTime? counterpartReadAt,
  bool viaAi = false,
  bool pending = false,
  bool failed = false,
  DateTime? now,
}) {
  if (failed) return MessageReceipt.failed;

  if (pending || sentAt == null) {
    // A pending bubble that has sat there too long is not "sending", it is
    // not sent.
    //
    // negotiation_screen passes `failed:` once a send has actually failed;
    // this covers the rest - a request still hanging, or one that never
    // reported back - so a message that never left the device can't show a
    // clock icon indefinitely, the precise ambiguity this whole ladder
    // exists to remove: "still going" and "gone forever" rendered
    // identically.
    //
    // 20s is well past any normal round trip on a slow connection but short
    // enough that the user finds out while they still remember sending it.
    // Worst case on a very slow link it reads "Not sent" and then corrects
    // itself to a tick when the response lands - a recoverable wrong
    // answer, unlike a clock that never resolves.
    if (sentAt != null &&
        (now ?? DateTime.now()).difference(sentAt) > staleSendAfter) {
      return MessageReceipt.failed;
    }
    return MessageReceipt.sending;
  }

  // A message sent through Zeno was never delivered to the other party as
  // written, so delivery/read ticks would be a lie about it. Zeno relaying
  // the substance is the honest thing to report.
  if (viaAi) return MessageReceipt.relayed;

  if (counterpartReadAt != null && !counterpartReadAt.isBefore(sentAt)) {
    return MessageReceipt.read;
  }
  if (counterpartDeliveredAt != null && !counterpartDeliveredAt.isBefore(sentAt)) {
    return MessageReceipt.delivered;
  }
  return MessageReceipt.sent;
}
