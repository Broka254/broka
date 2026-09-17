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
import 'package:flutter/material.dart';
import '../main.dart';
import '../features/categories/domain/models/category.dart';
import 'sell_step_scaffold.dart' show sellStepLabel;

class DynamicAttributeField extends StatelessWidget {
  final CategoryFilterField field;
  final String? value;
  final ValueChanged<String> onChanged;

  const DynamicAttributeField({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
  });

  String get _label {
    final s = field.fieldName.replaceAll('_', ' ');
    return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  }

  @override
  Widget build(BuildContext context) {
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
                keyboardType: const TextInputType.numberWithOptions(decimal: false),
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: InputDecoration(hintText: 'e.g. 2018'),
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
