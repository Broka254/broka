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
    backgroundColor: BrokaColors.bgMid,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
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
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(
                color: BrokaColors.border, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Row(children: [
                Expanded(child: Text(widget.title, style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800))),
              ]),
            ),
            if (widget.options.length > 8)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: TextField(
                  autofocus: false,
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(color: BrokaColors.textHigh),
                  decoration: const InputDecoration(
                    hintText: 'Search',
                    prefixIcon: Icon(Icons.search_rounded, color: BrokaColors.textLow),
                  ),
                ),
              ),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No matches',
                      style: TextStyle(color: BrokaColors.textLow)))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final o = shown[i];
                        final isSelected = o == widget.selected;
                        return ListTile(
                          title: Text(o, style: TextStyle(
                              color: isSelected ? BrokaColors.gold : BrokaColors.textHigh,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                          trailing: isSelected
                              ? const Icon(Icons.check_rounded, color: BrokaColors.gold)
                              : null,
                          onTap: () => Navigator.pop(context, o),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}
