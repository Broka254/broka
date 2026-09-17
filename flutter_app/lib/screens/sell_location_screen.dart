// BROKA - Sell Wizard Step 5: Location
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_showcase_screen.dart';

class SellLocationScreen extends StatefulWidget {
  final SellWizardData data;
  const SellLocationScreen({super.key, required this.data});
  @override
  State<SellLocationScreen> createState() => _SellLocationScreenState();
}

class _SellLocationScreenState extends State<SellLocationScreen> {
  // Country is fixed to Kenya for now (not yet user-editable - see
  // SellWizardData's comment), so it has no controller: nothing to type,
  // nothing to persist from this screen.
  late final TextEditingController _countyCtrl;
  late final TextEditingController _subcountyCtrl;
  Timer? _debounce;
  String? _error;

  @override
  void initState() {
    super.initState();
    _countyCtrl = TextEditingController(text: widget.data.county);
    _subcountyCtrl = TextEditingController(text: widget.data.subcounty);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _countyCtrl.dispose();
    _subcountyCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => widget.data.persist());
  }

  void _next() {
    final county = _countyCtrl.text.trim();
    final subcounty = _subcountyCtrl.text.trim();
    if (county.isEmpty || subcounty.isEmpty) {
      setState(() => _error = 'Please fill in both county and subcounty.');
      return;
    }
    widget.data.county = county;
    widget.data.subcounty = subcounty;
    setState(() => _error = null);
    unawaited(widget.data.persist());
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SellShowcaseScreen(data: widget.data),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SellStepScaffold(
      step: 5, totalSteps: 7, title: 'Location',
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
        TextFormField(
          controller: _countyCtrl,
          style: const TextStyle(color: BrokaColors.textHigh),
          decoration: const InputDecoration(hintText: 'e.g. Nairobi'),
          onChanged: (_) => _scheduleSave(),
        ),
        const SizedBox(height: 20),

        sellStepLabel('SUBCOUNTY'),
        const SizedBox(height: 8),
        TextFormField(
          controller: _subcountyCtrl,
          style: const TextStyle(color: BrokaColors.textHigh),
          decoration: const InputDecoration(hintText: 'e.g. Westlands'),
          onChanged: (_) => _scheduleSave(),
        ),
      ]),
    );
  }
}
