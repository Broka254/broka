// The search box inside a screen: the Category Zones ("Electronics Zone"),
// Traders and Stores.
//
// Each of those built its own copy of Home's header pill - 42-44px tall, 13px
// typed text, an 18px icon. On a phone that is small enough that people
// could not read back what they had typed, which is the one thing a search
// box has to show. This is taller, with 16px text, a stronger outline while
// it has focus, and a clear button with a real tap target.
import 'package:flutter/material.dart';

import '../main.dart';

class BrokaSearchField extends StatefulWidget {
  const BrokaSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.onCleared,
    this.fieldKey,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// After the clear button has emptied the field.
  final VoidCallback? onCleared;

  /// Key for the TextField itself, for tests.
  final Key? fieldKey;

  /// Small-Android breakpoint shared with Home and the Zones.
  static bool narrow(BuildContext context) => MediaQuery.sizeOf(context).width < 360;

  /// Height of the field, so a screen can reason about its layout.
  static double heightFor(BuildContext context) => narrow(context) ? 50.0 : 54.0;

  @override
  State<BrokaSearchField> createState() => _BrokaSearchFieldState();
}

class _BrokaSearchFieldState extends State<BrokaSearchField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_rebuild);
    widget.controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(covariant BrokaSearchField old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final narrow = BrokaSearchField.narrow(context);
    final height = BrokaSearchField.heightFor(context);
    final focused = _focus.hasFocus;
    return Container(
      height: height,
      padding: const EdgeInsets.only(left: 16, right: 4),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.92),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(
          color: BrokaColors.neonBlue.withOpacity(focused ? 0.85 : 0.45),
          width: focused ? 1.6 : 1.2,
        ),
        boxShadow: focused
            ? [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.18), blurRadius: 14)]
            : null,
      ),
      child: Row(children: [
        Icon(Icons.search_rounded,
            size: 22, color: focused ? BrokaColors.neonBlue : BrokaColors.textMid),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            key: widget.fieldKey,
            controller: widget.controller,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            cursorColor: BrokaColors.neonBlue,
            style: TextStyle(
                color: BrokaColors.textHigh,
                fontSize: narrow ? 15 : 16,
                fontWeight: FontWeight.w500),
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              hintText: widget.hintText,
              hintMaxLines: 1,
              hintStyle: TextStyle(color: BrokaColors.textMid, fontSize: narrow ? 14.5 : 15.5),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        if (widget.controller.text.isNotEmpty)
          IconButton(
            tooltip: 'Clear',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              widget.controller.clear();
              widget.onCleared?.call();
            },
            icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 20),
          )
        else
          const SizedBox(width: 12),
      ]),
    );
  }
}
