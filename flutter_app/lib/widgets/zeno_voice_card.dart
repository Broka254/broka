// lib/widgets/zeno_voice_card.dart
//
// The floating Zeno voice panel, and the overlay that mounts it over an
// existing conversation.
//
// This file is UI only. It receives a state and a transcript and it calls
// back; it does not know what Zeno is, what a negotiation is, or that
// Deepgram exists. That is what lets the same card sit over ZenoScreen and
// NegotiateScreen today and over direct chat later without a second copy.
//
// Two things it deliberately is NOT:
//  * a screen. It never navigates. The conversation underneath stays mounted,
//    at its scroll position, with its history intact - closing the card puts
//    the user back exactly where they were.
//  * a phone call. No phone, video, pause or end-call affordances anywhere:
//    BROKA has real buyer/seller calling elsewhere in the app and confusing
//    the two would be a genuinely bad outcome. The only control that ends a
//    voice session is the X.
import 'package:flutter/material.dart';

import '../main.dart';
import '../services/zeno_voice_controller.dart';
import 'voice_waveform.dart';
import 'zeno_avatar.dart';

/// Mounts [ZenoVoiceCard] over [child] when the controller is open.
///
/// The screens use this rather than building their own Stack, so "the card
/// sits at the top, the conversation dims but stays visible, and nothing
/// navigates" is implemented once.
class ZenoVoiceOverlay extends StatefulWidget {
  const ZenoVoiceOverlay({
    super.key,
    required this.controller,
    required this.child,
  });

  final ZenoVoiceController controller;
  final Widget child;

  @override
  State<ZenoVoiceOverlay> createState() => _ZenoVoiceOverlayState();
}

class _ZenoVoiceOverlayState extends State<ZenoVoiceOverlay> {
  /// Stateful for exactly one reason: so an open microphone cannot outlive the
  /// tree it was opened from. The hosting screen disposes the controller in
  /// its own dispose, but a screen popped mid-session, or any rebuild that
  /// unmounts this overlay, would otherwise leave a live Deepgram socket and a
  /// running recorder behind.
  @override
  void dispose() {
    widget.controller.stopForDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Stack(children: [
      widget.child,
      // AnimatedBuilder, not a rebuild of `child`: an interim transcript
      // arrives several times a second and the conversation underneath must
      // not relayout for any of them.
      AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final open = controller.isOpen;
          return IgnorePointer(
            // The dim is decoration. Taps still reach the conversation, so a
            // stray tap outside the card cannot silently end a voice session
            // or send anything (brief §33).
            ignoring: true,
            child: AnimatedOpacity(
              opacity: open ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: const ColoredBox(
                // ~28% - enough to push the conversation back, not enough to
                // stop the user reading the message they are replying to.
                color: Color(0x47000000),
                child: SizedBox.expand(),
              ),
            ),
          );
        },
      ),
      AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          if (!controller.isOpen) return const SizedBox.shrink();
          return Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: ZenoVoiceCard(controller: controller),
          );
        },
      ),
    ]);
  }
}

class ZenoVoiceCard extends StatefulWidget {
  const ZenoVoiceCard({super.key, required this.controller});

  final ZenoVoiceController controller;

  @override
  State<ZenoVoiceCard> createState() => _ZenoVoiceCardState();
}

class _ZenoVoiceCardState extends State<ZenoVoiceCard>
    with SingleTickerProviderStateMixin {
  // Entrance: fade + a short slide down from the top edge, ~220ms. No bounce,
  // no scale, no elastic (brief §32).
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) widget.controller.markEdited();
    });
  }

  @override
  void dispose() {
    _enter.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final narrow = MediaQuery.sizeOf(context).width < 360;

    return FadeTransition(
      opacity: CurvedAnimation(parent: _enter, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.08),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic)),
        child: AnimatedBuilder(
          animation: c,
          builder: (context, _) => _card(context, c, narrow),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, ZenoVoiceController c, bool narrow) {
    final accent = _accentFor(c.state);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.fromLTRB(
            narrow ? 12 : 14, 10, narrow ? 12 : 14, narrow ? 10 : 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          // Deep navy glass over the brand gradient's own hues. No BackdropFilter
          // anywhere: a blur this size over a scrolling conversation is the
          // one effect here that would actually cost frames on a low-end
          // Android.
          gradient: const LinearGradient(
            colors: [Color(0xF21A1040), Color(0xF20B1430)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: accent.withOpacity(0.55), width: 1.2),
          boxShadow: [
            BoxShadow(
                color: accent.withOpacity(0.18), blurRadius: 22, spreadRadius: 1),
            const BoxShadow(
                color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6)),
          ],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _topRow(c, accent, narrow),
          const SizedBox(height: 8),
          _statusLine(c, accent, narrow),
          const SizedBox(height: 8),
          _transcriptRow(c, accent, narrow),
          if (c.languageUnsupported && c.state != VoiceSessionState.error) ...[
            const SizedBox(height: 7),
            _unsupportedLanguageNote(narrow),
          ],
        ]),
      ),
    );
  }

  Widget _topRow(ZenoVoiceController c, Color accent, bool narrow) => Row(
        children: [
          const ZenoAvatar(size: 28, glow: true),
          const SizedBox(width: 9),
          Text('Zeno',
              style: TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: narrow ? 13 : 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2)),
          const SizedBox(width: 10),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: VoiceWaveform(
                mode: _waveformMode(c.state),
                level: c.level,
                color: accent,
                barCount: narrow ? 10 : 13,
                height: 24,
              ),
            ),
          ),
          // The only control that ends the session. Deliberately not an
          // "end call" button.
          GestureDetector(
            onTap: () => widget.controller.close(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: BrokaColors.bgCard.withOpacity(0.8),
                shape: BoxShape.circle,
                border: Border.all(color: BrokaColors.border),
              ),
              child: const Icon(Icons.close_rounded,
                  size: 16, color: BrokaColors.textMid),
            ),
          ),
        ],
      );

  Widget _statusLine(ZenoVoiceController c, Color accent, bool narrow) {
    final error = c.state == VoiceSessionState.error;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Text(
        error ? (c.errorMessage ?? 'Voice is unavailable') : _statusFor(c),
        key: ValueKey(error ? 'err:${c.errorMessage}' : _statusFor(c)),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: error ? BrokaColors.warning : accent,
          fontSize: narrow ? 12.5 : 13.5,
          height: 1.25,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// Interim text while speaking; an editable field once there is final text.
  ///
  /// Bounded to three lines (brief §12): the card must not grow down the
  /// screen as someone dictates a long request.
  Widget _transcriptRow(ZenoVoiceController c, Color accent, bool narrow) {
    final showInterim =
        c.interim.isNotEmpty && c.transcript.text.trim().isEmpty;
    return Container(
      padding: EdgeInsets.fromLTRB(narrow ? 10 : 12, 8, 6, 8),
      decoration: BoxDecoration(
        color: BrokaColors.bg.withOpacity(0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Icon(Icons.graphic_eq_rounded,
            size: 15, color: accent.withOpacity(0.75)),
        const SizedBox(width: 8),
        Expanded(
          child: showInterim
              ? Text(
                  c.interim,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: BrokaColors.textMid,
                    fontSize: narrow ? 12.5 : 13,
                    height: 1.3,
                    fontStyle: FontStyle.italic,
                  ),
                )
              : TextField(
                  controller: c.transcript,
                  focusNode: _focus,
                  maxLines: 3,
                  minLines: 1,
                  textInputAction: TextInputAction.send,
                  onChanged: (_) => c.markEdited(),
                  onSubmitted: (_) => c.submit(),
                  style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: narrow ? 12.5 : 13,
                    height: 1.3,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: _hintFor(c),
                    hintStyle: TextStyle(
                      color: BrokaColors.textMid,
                      fontSize: narrow ? 12 : 12.5,
                    ),
                  ),
                ),
        ),
        const SizedBox(width: 6),
        _sendButton(c),
      ]),
    );
  }

  Widget _sendButton(ZenoVoiceController c) {
    final enabled = c.hasSendableText &&
        c.state != VoiceSessionState.sendingToZeno &&
        c.state != VoiceSessionState.error;
    return GestureDetector(
      onTap: enabled ? () => c.submit() : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.35,
        duration: const Duration(milliseconds: 180),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
                colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
            boxShadow: enabled
                ? [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.35),
                    blurRadius: 12)]
                : null,
          ),
          child: c.state == VoiceSessionState.sendingToZeno
              ? const Padding(
                  padding: EdgeInsets.all(9),
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.arrow_forward_rounded,
                  size: 17, color: Colors.white),
        ),
      ),
    );
  }

  /// Said plainly rather than hidden: BROKA offers six languages and the
  /// transcriber handles one of them. A user getting poor Dholuo transcription
  /// should know it is the transcriber, not their speech - and should know
  /// before they speak that the box is where they fix it.
  Widget _unsupportedLanguageNote(bool narrow) => Row(children: [
        Icon(Icons.info_outline_rounded,
            size: 13, color: BrokaColors.textMid.withOpacity(0.9)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Voice transcribes English for now — it will catch the English '
            'parts. Edit anything it gets wrong before sending.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: BrokaColors.textMid,
                fontSize: narrow ? 10 : 10.5,
                height: 1.25),
          ),
        ),
      ]);

  // ── State -> presentation ──────────────────────────────────────────────────

  static String _statusFor(ZenoVoiceController c) {
    switch (c.state) {
      case VoiceSessionState.idle:
      case VoiceSessionState.connecting:
        return 'Connecting…';
      case VoiceSessionState.listening:
        return c.interim.isEmpty ? 'Listening…' : "I'm listening…";
      case VoiceSessionState.processing:
        return 'Got it…';
      case VoiceSessionState.readyToSend:
        return 'Ready to send';
      case VoiceSessionState.sendingToZeno:
        return 'Sending to Zeno…';
      case VoiceSessionState.speaking:
        return 'Zeno is speaking…';
      case VoiceSessionState.error:
        return "Couldn't hear that";
    }
  }

  static String _hintFor(ZenoVoiceController c) {
    switch (c.state) {
      case VoiceSessionState.speaking:
        return 'Zeno is replying…';
      case VoiceSessionState.error:
        return 'Type to Zeno instead';
      default:
        return 'Speak naturally…';
    }
  }

  static WaveformMode _waveformMode(VoiceSessionState state) {
    switch (state) {
      case VoiceSessionState.listening:
        return WaveformMode.speaking;
      case VoiceSessionState.processing:
      case VoiceSessionState.sendingToZeno:
      case VoiceSessionState.speaking:
      case VoiceSessionState.connecting:
        return WaveformMode.processing;
      case VoiceSessionState.idle:
      case VoiceSessionState.readyToSend:
      case VoiceSessionState.error:
        return WaveformMode.idle;
    }
  }

  static Color _accentFor(VoiceSessionState state) {
    switch (state) {
      case VoiceSessionState.speaking:
        return BrokaColors.neonPurple;
      case VoiceSessionState.error:
        return BrokaColors.warning;
      case VoiceSessionState.readyToSend:
        return BrokaColors.neonGreen;
      default:
        return BrokaColors.neonBlue;
    }
  }
}
