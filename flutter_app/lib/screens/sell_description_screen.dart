// BROKA - Sell Wizard Step 4: Description (required)
//
// Required since 2026-09-25, here and on the server (listings/validation.py
// MIN_DESCRIPTION_LEN): a listing with no words was a listing buyers had to
// message just to learn its condition, and the description is half of
// what a "not as described" dispute is judged against. Twenty characters -
// one real sentence - is the floor; the prompts below help sellers write
// more than that.
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_flow.dart';

class SellDescriptionScreen extends StatefulWidget {
  final SellWizardData data;
  const SellDescriptionScreen({super.key, required this.data});
  @override
  State<SellDescriptionScreen> createState() => _SellDescriptionScreenState();
}

class _SellDescriptionScreenState extends State<SellDescriptionScreen> {
  late final TextEditingController _descCtrl;
  Timer? _debounce;
  String? _error;

  SellWizardData get _data => widget.data;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(text: _data.description);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _descCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => _data.persist());
  }

  /// Starters that fit the item; tapping one adds it as a new line.
  List<String> get _prompts {
    switch (_data.category) {
      case 'Land':
        return ['Title deed: ', 'Distance from the main road: ', 'Water and power: ', 'Neighbourhood: '];
      case 'Agriculture':
      case 'Food & Beverages':
        return ['Harvested / made: ', 'Quality: ', 'Minimum order: ', 'Packaging: '];
      case 'Automobiles':
        return ['Mileage and service history: ', 'Known issues: ', 'Logbook: ', 'Why selling: '];
      case 'Property':
        return ['Rooms: ', 'Amenities: ', 'Nearby: ', 'Available from: '];
      case 'Services':
        return ['What I do: ', 'Experience: ', 'Areas I cover: ', 'Availability: '];
    }
    if (_data.subcategoryName?.startsWith('Mtumba') == true) {
      return ['Grade: ', 'What\'s in the bale: ', 'Sizes: ', 'Minimum order: '];
    }
    return ['Condition: ', "What's included: ", 'Why I\'m selling: ', 'Age / how long used: '];
  }

  void _insert(String prompt) {
    final text = _descCtrl.text;
    final prefix = text.isEmpty || text.endsWith('\n') ? '' : '\n';
    _descCtrl.text = '$text$prefix$prompt';
    _descCtrl.selection = TextSelection.collapsed(offset: _descCtrl.text.length);
    _onChanged(_descCtrl.text);
  }

  void _onChanged(String v) {
    setState(() {
      _data.description = v.trim();
      if (_error != null && _data.description.length >= SellWizardData.minDescriptionLength) {
        _error = null;
      }
    });
    _scheduleSave();
  }

  void _next() {
    _data.description = _descCtrl.text.trim();
    if (_data.description.length < SellWizardData.minDescriptionLength) {
      setState(() => _error = 'Describe the item in at least '
          '${SellWizardData.minDescriptionLength} characters - its condition, what\'s '
          'included and why you\'re selling.');
      return;
    }
    setState(() => _error = null);
    SellFlow.next(context, _data, from: SellFlow.description);
  }

  @override
  Widget build(BuildContext context) {
    final length = _data.description.length;
    const min = SellWizardData.minDescriptionLength;
    final enough = length >= min;
    return SellStepScaffold(
      step: SellFlow.description, totalSteps: SellFlow.total,
      title: SellFlow.title(SellFlow.description),
      subtitle: 'Say what the photos can\'t. Honest detail gets serious buyers - and avoids disputes.',
      data: _data,
      error: _error,
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: sellStepLabel('DESCRIPTION  (REQUIRED)')),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              enough ? '✓ Looks good' : '${min - length} more characters',
              key: ValueKey(enough),
              style: TextStyle(
                color: enough ? BrokaColors.success : BrokaColors.textMid,
                fontSize: 11.5, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: (length / min).clamp(0.0, 1.0)),
            duration: const Duration(milliseconds: 250),
            builder: (_, v, __) => LinearProgressIndicator(
              value: v,
              minHeight: 3,
              backgroundColor: BrokaColors.border,
              valueColor: AlwaysStoppedAnimation(enough ? BrokaColors.success : BrokaColors.gold),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('sell-description-field'),
          controller: _descCtrl,
          maxLines: 9,
          minLines: 6,
          maxLength: SellWizardData.maxDescriptionLength,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(color: BrokaColors.textHigh, height: 1.45),
          decoration: const InputDecoration(
              hintText: 'Condition, features, what\'s included, why you\'re selling…'),
          // Into the draft as typed - see SellDetailsScreen's name field.
          onChanged: _onChanged,
        ),
        const SizedBox(height: 6),
        sellStepLabel('TAP TO ADD'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in _prompts)
            ActionChip(
              label: Text(p.replaceAll(': ', '')),
              avatar: const Icon(Icons.add_rounded, size: 16, color: BrokaColors.gold),
              onPressed: () => _insert(p),
              backgroundColor: BrokaColors.bgCard,
              side: const BorderSide(color: BrokaColors.border),
              labelStyle: const TextStyle(color: BrokaColors.textHigh, fontSize: 12),
            ),
        ]),
      ]),
    );
  }
}
