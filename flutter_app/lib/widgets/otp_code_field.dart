// BROKA — 6-digit OTP entry.
//
// Renders as six separate boxes, but there is only ONE real TextField behind
// them, stretched invisibly across the row.
//
// That single-field design is deliberate and is the fix for "sometimes it
// pastes, sometimes it doesn't". Six independent TextFields — the obvious way
// to build this — break every bulk-fill path there is: a paste lands entirely
// in whichever box had focus, the platform autofill service can only target
// one field so it fills one box and leaves five empty, and a programmatic
// fill has to fan out across six controllers and six focus nodes with the
// keyboard fighting back on each hop. With one controller, "123456" arriving
// from any source — a paste, the SMS Retriever, the iOS keyboard suggestion,
// or typing — is just a string assignment, and the boxes are pure rendering.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';

class OtpCodeField extends StatefulWidget {
  const OtpCodeField({
    super.key,
    required this.controller,
    this.length = 6,
    this.autofocus = true,
    this.enabled = true,
    this.onChanged,
    this.onCompleted,
  });

  final TextEditingController controller;
  final int length;
  final bool autofocus;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  /// Fired once the full code is present, from any input source.
  final ValueChanged<String>? onCompleted;

  @override
  State<OtpCodeField> createState() => _OtpCodeFieldState();
}

class _OtpCodeFieldState extends State<OtpCodeField> {
  late final FocusNode _focus;
  String _lastCompleted = '';

  @override
  void initState() {
    super.initState();
    _focus = FocusNode();
    widget.controller.addListener(_onTextChanged);
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  void _onTextChanged() {
    final value = widget.controller.text;
    setState(() {});
    widget.onChanged?.call(value);

    // Guard against firing twice for the same code. The listener runs for
    // selection changes too, not only text edits, so without this a
    // completed code would re-submit when the cursor moves.
    if (value.length == widget.length && value != _lastCompleted) {
      _lastCompleted = value;
      _focus.unfocus();
      widget.onCompleted?.call(value);
    } else if (value.length < widget.length) {
      _lastCompleted = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.controller.text;
    final hasFocus = _focus.hasFocus;

    return Stack(
      children: [
        // ── The boxes (display only) ─────────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(widget.length, (i) {
            final filled = i < code.length;
            // The caret box is the next empty slot while focused, and the
            // last slot once every digit is in.
            final isActive = hasFocus &&
                (i == code.length ||
                    (code.length == widget.length && i == widget.length - 1));
            return _OtpBox(
              char: filled ? code[i] : null,
              active: isActive,
            );
          }),
        ),

        // ── The real field, invisible, covering the whole row ────────────
        Positioned.fill(
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            enabled: widget.enabled,
            autofocus: widget.autofocus,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            enableInteractiveSelection: true,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(widget.length),
            ],
            // iOS only. The iOS keyboard surfaces an incoming code as a
            // QuickType suggestion above the keys, which is unobtrusive and
            // works well. On Android this same hint is what summons the
            // Autofill framework's "Autofill?" popup — the prompt we were
            // asked to get rid of. Android instead receives the code with no
            // interaction at all through the SMS Retriever
            // (services/sms_autofill_service.dart), so the hint is pure
            // downside there.
            autofillHints: Platform.isIOS ? const [AutofillHints.oneTimeCode] : null,
            showCursor: false,
            cursorColor: Colors.transparent,
            style: const TextStyle(
              color: Colors.transparent,
              fontSize: 22,
              letterSpacing: 40,
              height: 2.6,
            ),
            decoration: const InputDecoration(
              counterText: '',
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }
}

class _OtpBox extends StatelessWidget {
  const _OtpBox({required this.char, required this.active});

  final String? char;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 50,
      height: 58,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(active ? 0.7 : 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active
              ? BrokaColors.gold
              : BrokaColors.border.withOpacity(0.75),
          width: active ? 1.6 : 1,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: BrokaColors.gold.withOpacity(0.35),
                  blurRadius: 16,
                  spreadRadius: -3,
                ),
              ]
            : null,
      ),
      child: char != null
          ? Text(
              char!,
              style: const TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            )
          : active
              // A caret in the box awaiting input, matching the design.
              ? const _Caret()
              : Text(
                  '–',
                  style: TextStyle(
                    color: BrokaColors.textMid.withOpacity(0.55),
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
    );
  }
}

/// A blinking caret. Drawn here rather than using the TextField's own cursor,
/// because that field is transparent and spans all six boxes, so its cursor
/// would sit at an arbitrary horizontal offset rather than inside a box.
class _Caret extends StatefulWidget {
  const _Caret();

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      // A square wave reads as a caret; a sine fade reads as a pulsing glow.
      opacity: _blink.drive(
        TweenSequence<double>([
          TweenSequenceItem(tween: ConstantTween(1.0), weight: 50),
          TweenSequenceItem(tween: ConstantTween(0.0), weight: 50),
        ]),
      ),
      child: Container(
        width: 2,
        height: 26,
        decoration: BoxDecoration(
          color: BrokaColors.textHigh,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}
