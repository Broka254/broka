// BROKA - Sell Wizard Step 3: Details (name, the category's own details,
// condition, listing type)
//
// What used to be "Basics" minus the category pick, which is its own step
// now (sell_category_screen.dart). The fields under the name are rendered
// from whatever /categories/{subcategoryId}/filters returns
// (DynamicAttributeField), except a Land listing's size: that is required
// - the server refuses land without one - so it gets its own control at
// the top rather than looking like one more optional box. The type's brand
// (or make) comes first among them, as one tap per brand (2026-10-08): it is
// what the type's own screen filters by.
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../core/utils/result.dart';
import '../features/categories/data/repositories/categories_repository.dart';
import '../features/categories/domain/models/category.dart';
import '../services/sell_wizard_data.dart';
import '../utils/land_size.dart';
import '../widgets/dynamic_attribute_field.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_flow.dart';

class SellDetailsScreen extends StatefulWidget {
  final SellWizardData data;

  /// For tests: the subcategory's fields instead of fetching them.
  final Future<Result<List<CategoryFilterField>>> Function(String subcategoryId)? loadFields;

  const SellDetailsScreen({super.key, required this.data, this.loadFields});
  @override
  State<SellDetailsScreen> createState() => _SellDetailsScreenState();
}

class _SellDetailsScreenState extends State<SellDetailsScreen> {
  static const _conditions = ['new', 'used', 'refurbished'];

  // Categories where "new or used" isn't a question the item answers.
  static const _noCondition = {'land', 'property', 'services', 'food & beverages'};

  late final TextEditingController _nameCtrl;
  late final TextEditingController _landSizeCtrl;
  Timer? _debounce;
  String? _error;

  List<CategoryFilterField> _fields = [];
  bool _loadingFields = false;

  SellWizardData get _data => widget.data;
  bool get _asksCondition => !_noCondition.contains(_data.category.toLowerCase());

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: _data.name);
    _landSizeCtrl = TextEditingController(text: _data.attributes[LandSize.sizeKey] ?? '');
    final sub = _data.subcategoryId ?? _data.categoryId;
    if (sub != null) _loadFields(sub);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _nameCtrl.dispose();
    _landSizeCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => _data.persist());
  }

  Future<void> _loadFields(String id) async {
    setState(() => _loadingFields = true);
    final result = await (widget.loadFields ?? categoriesRepository.getFilters)(id);
    if (!mounted) return;
    result.fold(
      onSuccess: (fields) => setState(() {
        final shown = fields.where((f) => !LandSize.fieldNames.contains(f.fieldName)).toList();
        // The brand (or make) leads: it is what buyers filter this type of
        // item by first (SubcategoryScreen), so it is the one detail worth
        // the seller's attention before the rest.
        _fields = [
          ...shown.where(DynamicAttributeField.suggests),
          ...shown.where((f) => !DynamicAttributeField.suggests(f)),
        ];
        _loadingFields = false;
      }),
      onFailure: (_, __) => setState(() => _loadingFields = false),
    );
  }

  String get _nameHint {
    switch (_data.category) {
      case 'Automobiles':
        return 'e.g. Toyota Probox 2014, well maintained';
      case 'Land':
        return 'e.g. ⅛ acre plot in Kitengela, ready title';
      case 'Agriculture':
        return 'e.g. Dry maize, 90kg bags';
      case 'Fashion':
        return _data.subcategoryName?.startsWith('Mtumba') == true
            ? 'e.g. Grade 1 ladies tops bale, 45kg'
            : 'e.g. Leather jacket, size M';
      case 'Property':
        return 'e.g. 2 bedroom apartment in Kilimani';
      case 'Electronics':
        return 'e.g. Samsung Galaxy A54, 128GB';
      case 'Services':
        return 'e.g. House cleaning, Nairobi';
    }
    return 'What are you selling?';
  }

  void _next() {
    final name = _nameCtrl.text.trim();
    if (name.length < 3) {
      setState(() => _error = 'Give the item a name of at least 3 characters.');
      return;
    }
    if (_data.isLand) {
      final problem = LandSize.problem(_data.attributes);
      if (problem != null) {
        setState(() => _error = problem);
        return;
      }
    }
    if (!_asksCondition) _data.condition = null;
    _data.name = name;
    setState(() => _error = null);
    SellFlow.next(context, _data, from: SellFlow.details);
  }

  @override
  Widget build(BuildContext context) {
    return SellStepScaffold(
      step: SellFlow.details, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.details),
      subtitle: _data.subcategoryName == null
          ? _data.category
          : '${_data.category}  ›  ${_data.subcategoryName}',
      data: _data,
      error: _error,
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sellStepLabel('NAME'),
        SellGap.label,
        TextFormField(
          key: const Key('sell-name-field'),
          controller: _nameCtrl,
          maxLength: SellWizardData.maxNameLength,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(color: BrokaColors.textHigh),
          decoration: InputDecoration(hintText: _nameHint),
          // Into the draft as typed, not only on Next: the debounced save
          // used to write a draft that didn't have the name in it yet.
          onChanged: (v) {
            _data.name = v.trim();
            _scheduleSave();
          },
        ),
        SellGap.item,

        if (_data.isLand) ...[
          _landSize(),
          SellGap.section,
        ],

        if (_loadingFields)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold)),
          )
        else if (_fields.isNotEmpty) ...[
          sellStepLabel('${(_data.subcategoryName ?? _data.category).toUpperCase()} DETAILS'),
          const SizedBox(height: 6),
          const Text('Optional, but they help buyers find exactly what they want.',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
          SellGap.label,
          ..._fields.map((field) => DynamicAttributeField(
                field: field,
                value: _data.attributes[field.fieldName],
                hint: DynamicAttributeField.suggests(field)
                    ? 'Buyers browse ${_data.subcategoryName ?? _data.category} by '
                        '${field.fieldName.replaceAll('_', ' ')}. Pick one, or tap Other to type it.'
                    : null,
                onChanged: (v) {
                  setState(() {
                    if (v.trim().isEmpty) {
                      _data.attributes.remove(field.fieldName);
                    } else {
                      _data.attributes[field.fieldName] = v;
                    }
                  });
                  _scheduleSave();
                },
              )),
        ],

        if (_asksCondition) ...[
          SellGap.item,
          sellStepLabel('CONDITION'),
          SellGap.label,
          Row(children: _conditions.map((c) {
            final selected = _data.condition == c;
            return Expanded(
              child: GestureDetector(
                onTap: () {
                  setState(() => _data.condition = c);
                  _scheduleSave();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: EdgeInsets.only(right: c == _conditions.last ? 0 : 8),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: selected ? BrokaColors.gold.withOpacity(0.18) : BrokaColors.bgCard.withOpacity(0.72),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: selected ? BrokaColors.gold : BrokaColors.border),
                    boxShadow: selected ? const [BrokaColors.glowGold] : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(c[0].toUpperCase() + c.substring(1), style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                      color: selected ? Colors.white : BrokaColors.textMid)),
                ),
              ),
            );
          }).toList()),
          SellGap.section,
        ],

        sellStepLabel('HOW DO YOU WANT TO SELL?'),
        SellGap.label,
        Row(children: [
          _typeBtn('direct', Icons.handshake_outlined, 'Direct sale', 'Buyers deal with you'),
          const SizedBox(width: 10),
          _typeBtn('auction', Icons.gavel_rounded, 'Auction', 'Highest bid wins'),
        ]),
      ]),
    );
  }

  Widget _landSize() {
    final unit = LandSize.canonicalUnit(_data.attributes[LandSize.unitKey]);
    final preview = LandSize.describe(_data.attributes);
    return SellCard(
      highlight: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('📐', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Expanded(child: sellStepLabel('LAND SIZE  (REQUIRED)')),
          if (preview != null)
            Flexible(
              child: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: BrokaColors.gold, fontSize: 12.5,
                      fontWeight: FontWeight.w800)),
            ),
        ]),
        const SizedBox(height: 10),
        TextField(
          key: const Key('sell-land-size'),
          controller: _landSizeCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w800),
          decoration: const InputDecoration(hintText: 'e.g. 0.5, 1, 2.5'),
          onChanged: (v) {
            setState(() {
              if (v.trim().isEmpty) {
                _data.attributes.remove(LandSize.sizeKey);
              } else {
                _data.attributes[LandSize.sizeKey] = v.trim();
              }
            });
            _scheduleSave();
          },
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final u in LandSize.units)
            ChoiceChip(
              key: Key('sell-land-unit-${u.key}'),
              label: Text(u.label),
              selected: unit == u.key,
              onSelected: (_) {
                setState(() => _data.attributes[LandSize.unitKey] = u.key);
                _scheduleSave();
              },
              selectedColor: BrokaColors.gold,
              backgroundColor: BrokaColors.bgCard,
              side: BorderSide(color: unit == u.key ? BrokaColors.gold : BrokaColors.border),
              labelStyle: TextStyle(
                  color: unit == u.key ? Colors.white : BrokaColors.textMid,
                  fontWeight: FontWeight.w700, fontSize: 12.5),
              showCheckmark: false,
            ),
        ]),
        const SizedBox(height: 8),
        const Text('A standard 50×100 ft plot is about ⅛ of an acre. Buyers filter land by size, '
            'so give the real figure.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11, height: 1.4)),
      ]),
    );
  }

  Widget _typeBtn(String type, IconData icon, String label, String hint) {
    final active = _data.type == type;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _data.type = type);
          _scheduleSave();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            gradient: active
                ? const LinearGradient(colors: [Color(0xFF2A1560), Color(0xFF150A35)])
                : null,
            color: active ? null : BrokaColors.bgCard.withOpacity(0.72),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? BrokaColors.gold : BrokaColors.border,
              width: active ? 1.5 : 1,
            ),
            boxShadow: active ? const [BrokaColors.glowGold] : null,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 24, color: active ? BrokaColors.gold : BrokaColors.textMid),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w800,
                color: active ? Colors.white : BrokaColors.textMid)),
            const SizedBox(height: 2),
            Text(hint, style: const TextStyle(fontSize: 10.5, color: BrokaColors.textMid)),
          ]),
        ),
      ),
    );
  }
}
