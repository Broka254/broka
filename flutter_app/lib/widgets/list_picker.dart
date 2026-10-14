// A searchable list in a bottom sheet, and the form field that opens one.
//
// Written for store setup's county and area pickers, and shared with the
// sell wizard's Location step: a county typed by hand ("Nairobii",
// "Nbi") is a listing the location filter never finds.
import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;

/// A form field that opens a picker instead of the keyboard.
class PickerField extends StatelessWidget {
  const PickerField({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.enabled = true,
  });
  final String label;
  final String? value;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: Icon(icon, color: BrokaColors.textLow, size: 18),
            suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded, color: BrokaColors.textMid),
          ),
          isEmpty: value == null || value!.isEmpty,
          child: Text(value ?? '',
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
        ),
      ),
    );
  }
}

/// A searchable list in a bottom sheet. Returns the chosen option.
Future<String?> pickFromList(
  BuildContext context, {
  required String title,
  required List<String> options,
  String? selected,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    // Drawn by _SearchList itself: the violet-lit card the wizards use,
    // not a flat grey sheet that read as part of some other app.
    backgroundColor: Colors.transparent,
    builder: (_) => _SearchList(title: title, options: options, selected: selected),
  );
}

class _SearchList extends StatefulWidget {
  const _SearchList({required this.title, required this.options, this.selected});
  final String title;
  final List<String> options;
  final String? selected;

  @override
  State<_SearchList> createState() => _SearchListState();
}

class _SearchListState extends State<_SearchList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.options
        : widget.options.where((o) => o.toLowerCase().contains(q)).toList();
    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Color(0xFF16103A), BrokaColors.bgMid, BrokaColors.bg],
          stops: [0, 0.35, 1],
        ),
        border: Border(top: BorderSide(color: BrokaColors.gold.withOpacity(0.55), width: 1.2)),
        boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.25), blurRadius: 30)],
      ),
      child: SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(children: [
            const SizedBox(height: 10),
            Container(width: 42, height: 4, decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(children: [
                Expanded(child: Text(widget.title, style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w800))),
                Text('${shown.length}', style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w700)),
              ]),
            ),
            if (widget.options.length > 8)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Container(
                  decoration: BoxDecoration(
                    color: BrokaColors.bgCard.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.4)),
                    boxShadow: const [BrokaColors.glowBlue],
                  ),
                  child: TextField(
                    autofocus: false,
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(color: BrokaColors.textHigh),
                    decoration: const InputDecoration(
                      hintText: 'Search',
                      hintStyle: TextStyle(color: BrokaColors.textMid),
                      prefixIcon: Icon(Icons.search_rounded, color: BrokaColors.textMid),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No matches',
                      style: TextStyle(color: BrokaColors.textMid)))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final o = shown[i];
                        final isSelected = o == widget.selected;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => Navigator.pop(context, o),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                gradient: isSelected
                                    ? LinearGradient(colors: [
                                        BrokaColors.gold.withOpacity(0.3),
                                        BrokaColors.neonBlue.withOpacity(0.12),
                                      ])
                                    : null,
                                border: Border.all(color: isSelected
                                    ? BrokaColors.gold.withOpacity(0.7)
                                    : BrokaColors.border.withOpacity(0.5)),
                              ),
                              child: Row(children: [
                                Expanded(child: Text(o, style: TextStyle(
                                    color: isSelected ? Colors.white : BrokaColors.textHigh,
                                    fontSize: 14.5,
                                    fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500))),
                                if (isSelected)
                                  const Icon(Icons.check_circle_rounded, color: BrokaColors.gold, size: 20),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
      ),
    );
  }
}
