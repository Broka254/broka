// BROKA - Sell Wizard Step 3: Description
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_price_screen.dart';

class SellDescriptionScreen extends StatefulWidget {
  final SellWizardData data;
  const SellDescriptionScreen({super.key, required this.data});
  @override
  State<SellDescriptionScreen> createState() => _SellDescriptionScreenState();
}

class _SellDescriptionScreenState extends State<SellDescriptionScreen> {
  late final TextEditingController _descCtrl;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(text: widget.data.description);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _descCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => widget.data.persist());
  }

  void _next() {
    widget.data.description = _descCtrl.text.trim();
    unawaited(widget.data.persist());
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SellPriceScreen(data: widget.data),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SellStepScaffold(
      step: 3, totalSteps: 7, title: 'Description',
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sellStepLabel('DESCRIPTION  (optional)'),
        const SizedBox(height: 8),
        const Text(
          'Add condition, features, or the reason for selling - listings '
          'with a description tend to get more serious buyers.',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _descCtrl,
          maxLines: 8,
          minLines: 5,
          style: const TextStyle(color: BrokaColors.textHigh),
          decoration: const InputDecoration(
              hintText: 'Condition, features, reason for selling...'),
          onChanged: (_) => _scheduleSave(),
        ),
      ]),
    );
  }
}
