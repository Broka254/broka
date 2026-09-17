// BROKA - Sell Wizard Step 4: Price
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_location_screen.dart';

class SellPriceScreen extends StatefulWidget {
  final SellWizardData data;
  const SellPriceScreen({super.key, required this.data});
  @override
  State<SellPriceScreen> createState() => _SellPriceScreenState();
}

class _SellPriceScreenState extends State<SellPriceScreen> {
  late final TextEditingController _priceCtrl;
  late final TextEditingController _reserveCtrl;
  Timer? _debounce;
  String? _error;

  @override
  void initState() {
    super.initState();
    _priceCtrl = TextEditingController(text: widget.data.price);
    _reserveCtrl = TextEditingController(text: widget.data.reserve);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _priceCtrl.dispose();
    _reserveCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => widget.data.persist());
  }

  void _next() {
    final price = double.tryParse(_priceCtrl.text);
    if (price == null || price <= 0) {
      setState(() => _error = 'Enter a valid asking price.');
      return;
    }
    widget.data.price = _priceCtrl.text;
    widget.data.reserve = _reserveCtrl.text;
    setState(() => _error = null);
    unawaited(widget.data.persist());
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SellLocationScreen(data: widget.data),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isAuction = widget.data.type == 'auction';
    return SellStepScaffold(
      step: 4, totalSteps: 7, title: 'Price',
      error: _error,
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sellStepLabel('ASKING PRICE (KES)'),
        const SizedBox(height: 8),
        TextFormField(
          controller: _priceCtrl,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w800),
          decoration: const InputDecoration(hintText: 'e.g. 2500000'),
          onChanged: (_) => _scheduleSave(),
        ),

        if (isAuction) ...[
          const SizedBox(height: 20),
          sellStepLabel('RESERVE PRICE (KES)  optional'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _reserveCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(hintText: 'Minimum acceptable bid'),
            onChanged: (_) => _scheduleSave(),
          ),
        ],
      ]),
    );
  }
}
