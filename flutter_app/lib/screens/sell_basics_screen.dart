// BROKA - Sell Wizard Step 2: Basics (name, category, subcategory,
// dynamic attributes, condition, listing type)
//
// Phase 2 of broka_mockup_actualization_spec.md (§4: "critical redesign"
// - the hard-coded 5-item category list is gone). Category and
// subcategory are now backend-driven (categoriesRepository, the exact
// same repository CategoryZoneScreen already uses - spec §21: reuse,
// don't duplicate), and the fields below the subcategory picker are
// rendered from whatever /categories/{subcategoryId}/filters returns via
// DynamicAttributeField, not a hard-coded per-category form.
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../core/utils/result.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import '../widgets/dynamic_attribute_field.dart';
import '../features/categories/data/repositories/categories_repository.dart';
import '../features/categories/domain/models/category.dart';
import 'sell_description_screen.dart';

class SellBasicsScreen extends StatefulWidget {
  final SellWizardData data;
  const SellBasicsScreen({super.key, required this.data});
  @override
  State<SellBasicsScreen> createState() => _SellBasicsScreenState();
}

class _SellBasicsScreenState extends State<SellBasicsScreen> {
  static const _conditions = ['new', 'used', 'refurbished'];

  late final TextEditingController _nameCtrl;
  Timer? _debounce;
  String? _error;

  List<Category> _categories = [];
  bool _loadingCategories = true;

  List<Category> _subcategories = [];
  bool _loadingSubcategories = false;

  List<CategoryFilterField> _attributeFields = [];
  bool _loadingFields = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.data.name);
    _loadCategories();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => widget.data.persist());
  }

  Future<void> _loadCategories() async {
    final result = await categoriesRepository.getTopLevel();
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _categories = data;
        _loadingCategories = false;
      }),
      onFailure: (_, __) => setState(() => _loadingCategories = false),
    );
    // Resuming a draft that already had a category picked - repopulate the
    // subcategory (and attribute) rails too, since the option lists
    // themselves are never persisted in the draft, only the selected ids.
    if (widget.data.categoryId != null) {
      await _loadSubcategories(widget.data.categoryId!, resetSelection: false);
      if (widget.data.subcategoryId != null) {
        await _loadFields(widget.data.subcategoryId!);
      }
    }
  }

  Future<void> _loadSubcategories(String categoryId, {required bool resetSelection}) async {
    setState(() {
      _loadingSubcategories = true;
      if (resetSelection) {
        _subcategories = [];
        _attributeFields = [];
      }
    });
    final result = await categoriesRepository.getSubcategories(categoryId);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _subcategories = data;
        _loadingSubcategories = false;
      }),
      onFailure: (_, __) => setState(() => _loadingSubcategories = false),
    );
  }

  Future<void> _loadFields(String subcategoryId) async {
    setState(() => _loadingFields = true);
    final result = await categoriesRepository.getFilters(subcategoryId);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _attributeFields = data;
        _loadingFields = false;
      }),
      onFailure: (_, __) => setState(() => _loadingFields = false),
    );
  }

  void _selectCategory(Category cat) {
    setState(() {
      widget.data.categoryId = cat.id;
      widget.data.category = cat.name;
      // A new top-level pick invalidates whatever subcategory/attributes
      // were chosen for the previous one.
      widget.data.subcategoryId = null;
      widget.data.subcategoryName = null;
      widget.data.attributes = {};
    });
    unawaited(widget.data.persist());
    _loadSubcategories(cat.id, resetSelection: true);
  }

  void _selectSubcategory(Category sub) {
    setState(() {
      widget.data.subcategoryId = sub.id;
      widget.data.subcategoryName = sub.name;
      widget.data.attributes = {};
      _attributeFields = [];
    });
    unawaited(widget.data.persist());
    _loadFields(sub.id);
  }

  void _next() {
    final name = _nameCtrl.text.trim();
    if (name.length < 3) {
      setState(() => _error = 'Product name needs at least 3 characters.');
      return;
    }
    if (widget.data.categoryId == null) {
      setState(() => _error = 'Please select a category.');
      return;
    }
    // Only require a subcategory pick when there actually are subcategories
    // to choose from (e.g. "Other" has none - Phase 1 leaves it that way
    // on purpose rather than padding it out with fake rows).
    if (_subcategories.isNotEmpty && widget.data.subcategoryId == null) {
      setState(() => _error = 'Please select a subcategory.');
      return;
    }
    widget.data.name = name;
    setState(() => _error = null);
    unawaited(widget.data.persist());
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SellDescriptionScreen(data: widget.data),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SellStepScaffold(
      step: 2, totalSteps: 7, title: 'Basics',
      error: _error,
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sellStepLabel('PRODUCT NAME'),
        const SizedBox(height: 8),
        TextFormField(
          controller: _nameCtrl,
          style: const TextStyle(color: BrokaColors.textHigh),
          decoration: const InputDecoration(hintText: 'e.g. Toyota Land Cruiser 2018'),
          onChanged: (_) => _scheduleSave(),
        ),
        const SizedBox(height: 20),

        sellStepLabel('CATEGORY'),
        const SizedBox(height: 10),
        if (_loadingCategories)
          const Center(child: Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold),
          ))
        else if (_categories.isEmpty)
          // Categories load from the backend now (§4). The canonical
          // taxonomy is seeded automatically on backend startup
          // (api.domains.categories.seed via api/database.py init_db()),
          // so this should be rare - it means the GET /categories call
          // itself failed or the backend is unreachable, not a missing
          // migration step. Surfaced honestly with a real retry rather
          // than leaving the section blank with an unexplained "select a
          // category" error on Next - that combination is
          // indistinguishable from a bug.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Row(children: [
              const Expanded(
                child: Text(
                  'No categories available right now.',
                  style: TextStyle(color: BrokaColors.textLow, fontSize: 12.5),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _loadingCategories = true);
                  _loadCategories();
                },
                child: const Text('Retry', style: TextStyle(color: BrokaColors.gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ]),
          )
        else
          _chipWrap(_categories, widget.data.categoryId, _selectCategory),

        if (widget.data.categoryId != null) ...[
          const SizedBox(height: 20),
          sellStepLabel('SUBCATEGORY'),
          const SizedBox(height: 10),
          if (_loadingSubcategories)
            const Center(child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold),
            ))
          else if (_subcategories.isEmpty)
            const Text('No subcategories for this category - you can continue without one.',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12))
          else
            _chipWrap(_subcategories, widget.data.subcategoryId, _selectSubcategory),
        ],

        if (widget.data.subcategoryId != null) ...[
          const SizedBox(height: 20),
          if (_loadingFields)
            const Center(child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold),
            ))
          else if (_attributeFields.isNotEmpty) ...[
            sellStepLabel('${widget.data.subcategoryName ?? 'ITEM'} DETAILS'),
            const SizedBox(height: 4),
            const Text('Optional, but helps buyers find exactly what they want.',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
            const SizedBox(height: 12),
            ..._attributeFields.map((field) => DynamicAttributeField(
                  field: field,
                  value: widget.data.attributes[field.fieldName],
                  onChanged: (v) {
                    widget.data.attributes[field.fieldName] = v;
                    _scheduleSave();
                  },
                )),
          ],
        ],

        sellStepLabel('CONDITION'),
        const SizedBox(height: 10),
        Row(children: _conditions.map((c) {
          final selected = widget.data.condition == c;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() => widget.data.condition = c);
                _scheduleSave();
              },
              child: Container(
                margin: EdgeInsets.only(right: c == _conditions.last ? 0 : 8),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: selected ? BrokaColors.gold.withOpacity(0.15) : BrokaColors.bgCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selected ? BrokaColors.gold : BrokaColors.border),
                ),
                alignment: Alignment.center,
                child: Text(c[0].toUpperCase() + c.substring(1), style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                    color: selected ? BrokaColors.gold : BrokaColors.textMid)),
              ),
            ),
          );
        }).toList()),
        const SizedBox(height: 20),

        sellStepLabel('LISTING TYPE'),
        const SizedBox(height: 10),
        Row(children: [
          _typeBtn('direct', Icons.handshake_outlined, 'Direct Sale'),
          const SizedBox(width: 10),
          _typeBtn('auction', Icons.gavel_rounded, 'Auction'),
        ]),
      ]),
    );
  }

  Widget _chipWrap(List<Category> items, String? selectedId, ValueChanged<Category> onTap) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items.map((cat) {
        final selected = cat.id == selectedId;
        return GestureDetector(
          onTap: () => onTap(cat),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              gradient: selected
                  ? const LinearGradient(colors: [Color(0xFF2A1560), Color(0xFF150A35)])
                  : null,
              color: selected ? null : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? BrokaColors.gold : BrokaColors.border,
                  width: selected ? 1.5 : 1),
              boxShadow: selected ? [BrokaColors.glowGold] : null,
            ),
            child: Text(cat.name, style: TextStyle(
              fontSize: 13,
              color: selected ? BrokaColors.gold : BrokaColors.textMid,
              fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
            )),
          ),
        );
      }).toList(),
    );
  }

  Widget _typeBtn(String type, IconData icon, String label) {
    final active = widget.data.type == type;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => widget.data.type = type);
          _scheduleSave();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            gradient: active
                ? const LinearGradient(colors: [Color(0xFF2A1560), Color(0xFF150A35)])
                : null,
            color: active ? null : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? BrokaColors.gold : BrokaColors.border,
              width: active ? 1.5 : 1,
            ),
            boxShadow: active ? [BrokaColors.glowGold] : null,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22, color: active ? BrokaColors.gold : BrokaColors.textMid),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: active ? BrokaColors.gold : BrokaColors.textMid)),
          ]),
        ),
      ),
    );
  }
}
