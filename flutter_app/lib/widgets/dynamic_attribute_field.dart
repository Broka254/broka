// lib/widgets/dynamic_attribute_field.dart
//
// Renders ONE CategoryFilterField as a seller-form input that captures a
// single value (Make: "Toyota", Year: "2018") — Phase 2 of
// broka_mockup_actualization_spec.md §4: "Do not create a separate
// Flutter form for every category. Render fields from backend category
// metadata."
//
// Deliberately NOT a reuse of FilterBottomSheet._buildFieldInput, even
// though both switch on the same CategoryFilterField.fieldType: that
// widget renders "number_range" as a RangeSlider because it's answering
// "which listings match?" (a range to filter by). Here the seller is
// answering "what is this item?" — a single fact, not a range — so
// "number_range" renders as one numeric field instead. Same field
// definitions (same table, same /categories/{id}/filters endpoint, per
// spec §19), different widget for a genuinely different question.
//
// A "text" field that comes with options (2026-10-08) is a brand or a make
// with suggestions (backend seed.py BRAND_SUGGESTIONS): the brands buyers
// filter that type of item by. It renders as one tap per brand plus "Other"
// for a brand that isn't listed - not the bare box it was, where "samsung
// galaxy a54", "Samsung phone" and "SAMSUNG" were three different brands to
// the subcategory screens' brand filter. The server files a typed brand
// under the same spellings, so "Other" is safe too.
import 'package:flutter/material.dart';
import '../main.dart';
import '../features/categories/domain/models/category.dart';
import 'sell_step_scaffold.dart' show sellStepLabel;

class DynamicAttributeField extends StatelessWidget {
  final CategoryFilterField field;
  final String? value;
  final ValueChanged<String> onChanged;

  /// A line under the label saying why the field matters ("Buyers browse
  /// Phones by brand"), for the field a subcategory's buyers filter by.
  final String? hint;

  const DynamicAttributeField({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  /// Whether [field] is a brand (or make) with suggestions to pick from.
  static bool suggests(CategoryFilterField field) =>
      field.fieldType == 'text' && (field.options ?? const []).isNotEmpty;

  String get _label {
    final s = field.fieldName.replaceAll('_', ' ');
    return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    if (suggests(field)) {
      return _SuggestionField(field: field, label: _label, hint: hint, value: value, onChanged: onChanged);
    }
    switch (field.fieldType) {
      case 'select':
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sellStepLabel(_label.toUpperCase()),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: (field.options ?? []).map((opt) {
                  final selected = value == opt;
                  return GestureDetector(
                    onTap: () => onChanged(opt),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? BrokaColors.gold.withOpacity(0.15) : BrokaColors.bgCard,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected ? BrokaColors.gold : BrokaColors.border,
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: Text(opt, style: TextStyle(
                        fontSize: 13,
                        color: selected ? BrokaColors.gold : BrokaColors.textMid,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                      )),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );

      case 'number_range':
        // Seller-form context: one number describing the item (Year,
        // Mileage, Acreage...), not a min/max range - see file header.
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sellStepLabel(_label.toUpperCase()),
              const SizedBox(height: 8),
              TextFormField(
                initialValue: value,
                // Decimals allowed: an engine is 1.5 litres and a plot 0.5
                // acres, and "e.g. 2018" was the hint on every number,
                // mileage and acreage included.
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: InputDecoration(
                    hintText: field.fieldName == 'year' ? 'e.g. 2018' : 'Enter a number'),
                onChanged: onChanged,
              ),
            ],
          ),
        );

      default: // "text"
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sellStepLabel(_label.toUpperCase()),
              const SizedBox(height: 8),
              TextFormField(
                initialValue: value,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: InputDecoration(hintText: 'Enter $_label'.toLowerCase()),
                onChanged: onChanged,
              ),
            ],
          ),
        );
    }
  }
}

/// One tap per suggested brand, the first few showing and the rest a tap
/// away, and "Other" opening a box for one that isn't listed. Tapping the
/// chosen brand again clears it: the field stays optional.
class _SuggestionField extends StatefulWidget {
  const _SuggestionField({
    required this.field,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final CategoryFilterField field;
  final String label;
  final String? hint;
  final String? value;
  final ValueChanged<String> onChanged;

  @override
  State<_SuggestionField> createState() => _SuggestionFieldState();
}

class _SuggestionFieldState extends State<_SuggestionField> {
  /// How many brands show before "More": two rows on most phones.
  static const _shown = 8;

  late bool _typing;
  late bool _expanded;
  late final TextEditingController _other;

  List<String> get _options => widget.field.options!;

  /// [widget.value] as one of the options, in any case - a draft saved with
  /// "samsung" shows Samsung chosen.
  String? get _picked {
    final v = widget.value?.trim().toLowerCase();
    if (v == null || v.isEmpty) return null;
    for (final o in _options) {
      if (o.toLowerCase() == v) return o;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final v = widget.value?.trim() ?? '';
    // A brand that isn't one of the options was typed: reopen on the box.
    _typing = v.isNotEmpty && _picked == null;
    _other = TextEditingController(text: _typing ? v : '');
    final at = _picked == null ? -1 : _options.indexOf(_picked!);
    _expanded = at >= _shown;
  }

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  void _pick(String option) {
    setState(() => _typing = false);
    widget.onChanged(_picked == option ? '' : option);
  }

  void _openOther() {
    setState(() => _typing = true);
    widget.onChanged(_other.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final picked = _typing ? null : _picked;
    final visible = _expanded || _options.length <= _shown + 1
        ? _options
        : _options.take(_shown).toList();
    final hidden = _options.length - visible.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sellStepLabel(widget.label.toUpperCase()),
          if (widget.hint != null) ...[
            const SizedBox(height: 4),
            Text(widget.hint!,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.35)),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in visible)
                _chip(option, selected: picked == option, onTap: () => _pick(option),
                    key: Key('attr-${widget.field.fieldName}-$option')),
              if (hidden > 0)
                _chip('+$hidden more', selected: false, quiet: true,
                    onTap: () => setState(() => _expanded = true),
                    key: Key('attr-${widget.field.fieldName}-more')),
              _chip('Other', selected: _typing, onTap: _openOther,
                  key: Key('attr-${widget.field.fieldName}-other')),
            ],
          ),
          if (_typing) ...[
            const SizedBox(height: 10),
            TextFormField(
              key: Key('attr-${widget.field.fieldName}-typed'),
              controller: _other,
              autofocus: widget.value == null || widget.value!.isEmpty,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: InputDecoration(hintText: 'Type the ${widget.label.toLowerCase()}'),
              onChanged: widget.onChanged,
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String text,
          {required bool selected, required VoidCallback onTap, bool quiet = false, Key? key}) =>
      GestureDetector(
        key: key,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? BrokaColors.gold.withOpacity(0.15) : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? BrokaColors.gold : (quiet ? BrokaColors.gold.withOpacity(0.4) : BrokaColors.border),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(text,
              style: TextStyle(
                fontSize: 13,
                color: selected || quiet ? BrokaColors.gold : BrokaColors.textMid,
                fontWeight: selected ? FontWeight.w700 : (quiet ? FontWeight.w600 : FontWeight.normal),
              )),
        ),
      );
}
