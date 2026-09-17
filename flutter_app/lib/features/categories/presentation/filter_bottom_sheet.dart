// lib/features/categories/presentation/filter_bottom_sheet.dart
// Universal (price, condition) + category-specific filter controls
// (Design Journal Volume 6, Ch.24). Renders one input per
// CategoryFilterField: TextField for "text", RangeSlider for
// "number_range", ChoiceChips for "select". Pops a Map<String, dynamic>
// back to the caller on Apply.
//
// Phase 3 (broka_mockup_actualization_spec.md §7) closed the gap that
// used to be documented here: price, sort, and every category-specific
// field selection now actually narrow GET /listings server-side (see
// ListingService.list_listings and CategoryZoneScreen._categoryAttributes,
// which does the RangeValues -> {min,max} conversion this sheet's
// "number_range" values need before they're JSON-safe). This widget's own
// code didn't need to change for that — it already just collected values
// into a flat map; the caller now actually uses all of them, not just
// condition.
//
// FIX (redesign-guide audit): "number_range" fields used to render against
// a flat, shared 0-100 scale regardless of what the field actually was -
// nonsensical for e.g. Year (a 1980-2026 range squeezed into 0-100 has no
// usable resolution) or Mileage (needs to reach ~500,000 km). The category
// filter schema (categories/seed.py) still has no per-field min/max of its
// own, so _numberRangeBounds below is a small hand-picked lookup by field
// name, covering every number_range field name that actually appears in
// seed.py today - not a general schema change, just real bounds for the
// real fields in use. Falls back to the old 0-100 for any field name not
// in the map, so nothing breaks if seed.py grows a new one later.
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../domain/models/category.dart';

/// (min, max) per number_range field name - see the FIX note above.
final Map<String, RangeValues> _numberRangeBounds = {
  'year':                RangeValues(1980, (DateTime.now().year + 1).toDouble()),
  'mileage':             const RangeValues(0, 500000),      // km
  'bedrooms':            const RangeValues(0, 10),
  'bathrooms':           const RangeValues(0, 10),
  'acreage':             const RangeValues(0, 100),         // acres
  'screen_size':         const RangeValues(0, 100),         // inches (phones through TVs)
  'seating_capacity':    const RangeValues(1, 30),           // covers matatus/buses, not just cars
  'square_footage':      const RangeValues(0, 10000),
  'battery_health':      const RangeValues(0, 100),          // percentage
  'power_rating_watts':  const RangeValues(0, 5000),
  'size':                const RangeValues(15, 50),          // shoe sizes
  'hours_used':          const RangeValues(0, 20000),
  'size_ml':             const RangeValues(0, 5000),
  'experience_years':    const RangeValues(0, 50),
};

class FilterBottomSheet extends StatefulWidget {
  final String categoryId;
  final List<CategoryFilterField> fields;
  final Map<String, dynamic> initial;

  const FilterBottomSheet({
    super.key,
    required this.categoryId,
    required this.fields,
    this.initial = const {},
  });

  @override
  State<FilterBottomSheet> createState() => _FilterBottomSheetState();
}

class _FilterBottomSheetState extends State<FilterBottomSheet> {
  static const _conditions = ['new', 'used', 'refurbished'];
  late Map<String, dynamic> _values;
  late RangeValues _priceRange;

  @override
  void initState() {
    super.initState();
    _values = Map<String, dynamic>.from(widget.initial);
    final min = (_values['minPrice'] as num?)?.toDouble() ?? 0;
    final max = (_values['maxPrice'] as num?)?.toDouble() ?? 5000000;
    _priceRange = RangeValues(min, max);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration:
                    BoxDecoration(color: BrokaColors.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Filters',
                style:
                    TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.bold)),
            Expanded(
              child: ListView(
                controller: scrollController,
                children: [
                  const SizedBox(height: 16),
                  _sectionLabel('Price range (KES)'),
                  RangeSlider(
                    values: _priceRange,
                    min: 0,
                    max: 5000000,
                    divisions: 50,
                    activeColor: BrokaColors.gold,
                    inactiveColor: BrokaColors.border,
                    labels: RangeLabels(
                      _priceRange.start.toStringAsFixed(0),
                      _priceRange.end.toStringAsFixed(0),
                    ),
                    onChanged: (v) => setState(() => _priceRange = v),
                  ),
                  const SizedBox(height: 12),
                  _sectionLabel('Condition'),
                  Wrap(
                    spacing: 8,
                    children: _conditions
                        .map((c) => _choiceChip(
                              c[0].toUpperCase() + c.substring(1),
                              _values['condition'] == c,
                              () => setState(
                                  () => _values['condition'] = _values['condition'] == c ? null : c),
                            ))
                        .toList(),
                  ),
                  ...widget.fields.map(_buildFieldInput),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: GoldButton(
                label: 'Apply Filters',
                onTap: () {
                  _values['minPrice'] = _priceRange.start;
                  _values['maxPrice'] = _priceRange.end;
                  Navigator.pop(context, _values);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style:
                const TextStyle(color: BrokaColors.textMid, fontSize: 13, fontWeight: FontWeight.w600)),
      );

  Widget _choiceChip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        backgroundColor: BrokaColors.bgCard,
        selectedColor: BrokaColors.gold,
        labelStyle: TextStyle(color: selected ? Colors.white : BrokaColors.textMid),
        side: BorderSide(color: selected ? BrokaColors.gold : BrokaColors.border),
      );

  Widget _buildFieldInput(CategoryFilterField field) {
    switch (field.fieldType) {
      case 'select':
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel(_titleCase(field.fieldName)),
              Wrap(
                spacing: 8,
                children: (field.options ?? [])
                    .map((opt) => _choiceChip(
                          opt,
                          _values[field.fieldName] == opt,
                          () => setState(() =>
                              _values[field.fieldName] = _values[field.fieldName] == opt ? null : opt),
                        ))
                    .toList(),
              ),
            ],
          ),
        );
      case 'number_range':
        final bounds = _numberRangeBounds[field.fieldName] ?? const RangeValues(0, 100);
        final current = (_values[field.fieldName] as RangeValues?) ?? bounds;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel(_titleCase(field.fieldName)),
              RangeSlider(
                values: current,
                min: bounds.start,
                max: bounds.end,
                activeColor: BrokaColors.gold,
                inactiveColor: BrokaColors.border,
                labels: RangeLabels(
                  current.start.toStringAsFixed(0),
                  current.end.toStringAsFixed(0),
                ),
                onChanged: (v) => setState(() => _values[field.fieldName] = v),
              ),
            ],
          ),
        );
      default: // "text"
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: InputDecoration(
              labelText: _titleCase(field.fieldName),
              labelStyle: const TextStyle(color: BrokaColors.textMid),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: BrokaColors.border)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: BrokaColors.gold)),
            ),
            onChanged: (v) => _values[field.fieldName] = v,
          ),
        );
    }
  }

  String _titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('_', ' ');
}
