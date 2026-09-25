// BROKA - Sell Wizard Step 7: Location
//
// County and area are picked from Kenya's 47 counties and their
// constituencies (KenyaLocations, the list store setup uses), with typing
// kept for an area the list doesn't have. Both used to be free text: a
// listing in "Nairobii" or "Nbi" was never found by the location filter,
// and the server now places a listing on the map at its county (see
// backend/api/domains/listings/location.py), which needs a county it knows.
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../features/stores/domain/kenya_locations.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/list_picker.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_flow.dart';

class SellLocationScreen extends StatefulWidget {
  final SellWizardData data;
  const SellLocationScreen({super.key, required this.data});
  @override
  State<SellLocationScreen> createState() => _SellLocationScreenState();
}

class _SellLocationScreenState extends State<SellLocationScreen> {
  static const _areaNotListed = "My area isn't listed";
  static const _maxAreaLength = 80; // the server's limit for place names

  // Country is fixed to Kenya for now (not yet user-editable - see
  // SellWizardData's comment), so it has no state: nothing to pick,
  // nothing to persist from this screen.
  String? _county;
  late final TextEditingController _areaCtrl;
  // True when the seller is typing an area the list doesn't have.
  late bool _typingArea;
  Timer? _debounce;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A draft typed before the pickers existed keeps its county only if
    // it is one; otherwise the seller picks it.
    _county = KenyaLocations.canonicalCounty(widget.data.county);
    final area = widget.data.subcounty.trim();
    final listed = KenyaLocations.canonicalSubcounty(_county, area);
    _typingArea = area.isNotEmpty && listed == null;
    _areaCtrl = TextEditingController(text: listed ?? area);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _areaCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => widget.data.persist());
  }

  void _store() {
    widget.data.county = _county ?? '';
    widget.data.subcounty = _areaCtrl.text.trim();
    _scheduleSave();
  }

  Future<void> _pickCounty() async {
    final picked = await pickFromList(context,
        title: 'Where is the item?', options: KenyaLocations.counties, selected: _county);
    if (picked == null || !mounted) return;
    setState(() {
      if (picked != _county) {
        _areaCtrl.clear();
        _typingArea = false;
      }
      _county = picked;
      _error = null;
    });
    _store();
  }

  Future<void> _pickArea() async {
    final picked = await pickFromList(context,
        title: 'Choose the area',
        options: [...KenyaLocations.subcountiesOf(_county), _areaNotListed],
        selected: _typingArea ? null : _areaCtrl.text);
    if (picked == null || !mounted) return;
    setState(() {
      _typingArea = picked == _areaNotListed;
      _areaCtrl.text = _typingArea ? '' : picked;
      _error = null;
    });
    _store();
  }

  void _next() {
    if (_county == null) {
      setState(() => _error = 'Choose the county the item is in.');
      return;
    }
    if (_areaCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Choose or type the area within $_county.');
      return;
    }
    _store();
    setState(() => _error = null);
    SellFlow.next(context, widget.data, from: SellFlow.location);
  }

  @override
  Widget build(BuildContext context) {
    return SellStepScaffold(
      step: SellFlow.location, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.location),
      subtitle: 'Where the item is. Buyers see the area, never your address.',
      data: widget.data,
      error: _error,
      nextLabel: 'NEXT',
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sellStepLabel('COUNTRY'),
        const SizedBox(height: 8),
        // Kenya only for now - see SellWizardData. Shown as a disabled
        // field (not just plain text) so it still reads as "part of this
        // form", consistent with the country field growing an editable
        // dropdown here later without changing the surrounding layout.
        const TextField(
          enabled: false,
          decoration: InputDecoration(hintText: 'Kenya'),
        ),
        const SizedBox(height: 20),

        sellStepLabel('COUNTY'),
        const SizedBox(height: 8),
        PickerField(
          key: const Key('sell-county-picker'),
          label: 'County',
          value: _county,
          icon: Icons.map_outlined,
          onTap: _pickCounty,
        ),
        const SizedBox(height: 20),

        sellStepLabel('AREA / SUBCOUNTY'),
        const SizedBox(height: 8),
        if (_typingArea)
          TextFormField(
            key: const Key('sell-area-field'),
            controller: _areaCtrl,
            autofocus: true,
            maxLength: _maxAreaLength,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: InputDecoration(
              hintText: 'e.g. Kilimani',
              suffixIcon: IconButton(
                tooltip: 'Choose from the list',
                icon: const Icon(Icons.list_rounded, color: BrokaColors.textMid),
                onPressed: _pickArea,
              ),
            ),
            onChanged: (_) => _store(),
          )
        else
          PickerField(
            key: const Key('sell-area-picker'),
            label: 'Area / subcounty',
            value: _areaCtrl.text.isEmpty ? null : _areaCtrl.text,
            icon: Icons.place_outlined,
            enabled: _county != null,
            onTap: _pickArea,
          ),
        const SizedBox(height: 8),
        const Text(
          'Buyers see the area and county. Your exact address is never shown - '
          'agree where to meet once you have a deal.',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
        ),
      ]),
    );
  }
}
