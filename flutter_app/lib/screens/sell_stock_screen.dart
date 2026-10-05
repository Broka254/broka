// BROKA - Sell Wizard Step 6: Stock & delivery
//
// How many the seller has, and whether they can arrange delivery if a
// buyer needs it (2026-09-25). Both go on the listing (Listing.quantity,
// delivery_available, delivery_note) and to Zeno, which is how a buyer's
// "do you have 20 bags?" or "can you bring it to Nakuru?" gets the seller's
// own answer instead of a round trip. The unit comes from the Price step:
// "100 bags", not "100".
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../services/sell_wizard_data.dart';
import '../utils/handover.dart';
import '../utils/price_unit.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_flow.dart';

class SellStockScreen extends StatefulWidget {
  final SellWizardData data;
  const SellStockScreen({super.key, required this.data});
  @override
  State<SellStockScreen> createState() => _SellStockScreenState();
}

class _SellStockScreenState extends State<SellStockScreen> {
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _noteCtrl;
  Timer? _debounce;
  String? _error;

  SellWizardData get _data => widget.data;
  int get _qty => int.tryParse(_qtyCtrl.text) ?? 0;
  // Land and buildings stay where they are: no delivery question.
  bool get _deliverable => isDeliverableCategory(_data.category);

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(text: _data.quantity.isEmpty ? '1' : _data.quantity);
    _noteCtrl = TextEditingController(text: _data.deliveryNote);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _qtyCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => _data.persist());
  }

  void _setQty(int value) {
    final clamped = value.clamp(1, SellWizardData.maxQuantity);
    _qtyCtrl.text = '$clamped';
    _qtyCtrl.selection = TextSelection.collapsed(offset: _qtyCtrl.text.length);
    setState(() => _data.quantity = '$clamped');
    HapticFeedback.selectionClick();
    _scheduleSave();
  }

  void _setDelivery(bool value) {
    setState(() {
      _data.deliveryAvailable = value;
      _error = null;
    });
    _scheduleSave();
  }

  void _next() {
    if (!_data.isAuction && (_qty < 1 || _qty > SellWizardData.maxQuantity)) {
      setState(() => _error = 'Enter how many you have - at least 1.');
      return;
    }
    if (_deliverable && _data.deliveryAvailable == null) {
      setState(() => _error = 'Say whether you can arrange delivery.');
      return;
    }
    _data.quantity = _data.isAuction ? '1' : '$_qty';
    if (!_deliverable) {
      // Not asked, so nothing is sent: an answer left over from another
      // category picked earlier in this draft would be dropped by the server
      // anyway (handover.dart).
      _data.deliveryAvailable = null;
    }
    _data.deliveryNote = _data.deliveryAvailable == true ? _noteCtrl.text.trim() : '';
    setState(() => _error = null);
    SellFlow.next(context, _data, from: SellFlow.stock);
  }

  @override
  Widget build(BuildContext context) {
    final unit = _data.priceUnit;
    final unitWord = unit == null ? 'items' : PriceUnits.plural(unit);
    return SellStepScaffold(
      step: SellFlow.stock, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.stock),
      subtitle: 'How many you have, and how the buyer gets it.',
      data: _data,
      error: _error,
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!_data.isAuction) ...[
          sellStepLabel('HOW MANY ${unitWord.toUpperCase()} DO YOU HAVE?'),
          const SizedBox(height: 10),
          SellCard(
            highlight: true,
            child: Row(children: [
              _StepperButton(icon: Icons.remove_rounded, onTap: _qty > 1 ? () => _setQty(_qty - 1) : null),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const Key('sell-quantity-field'),
                  controller: _qtyCtrl,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(7)],
                  style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900),
                  decoration: const InputDecoration(
                    border: InputBorder.none, enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none, filled: false, isDense: true),
                  onChanged: (v) {
                    setState(() => _data.quantity = v);
                    _scheduleSave();
                  },
                ),
              ),
              const SizedBox(width: 12),
              _StepperButton(icon: Icons.add_rounded, onTap: () => _setQty(_qty + 1)),
            ]),
          ),
          const SizedBox(height: 8),
          Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                _qty >= 1 ? '${PriceUnits.quantity(_qty, unit)} available' : ' ',
                key: ValueKey(_qty),
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (unit == null && _qty > 1) ...[
            const SizedBox(height: 6),
            const Text(
              'Selling several? If your price is for one of them, set "The price is for" on '
              'the Price step - so buyers see "KES 3,500 / bag", not one price for the lot.',
              style: TextStyle(color: BrokaColors.warning, fontSize: 11.5, height: 1.4),
            ),
          ],
          const SizedBox(height: 24),
        ],

        if (!_deliverable) ...[
          sellStepLabel('HOW THE BUYER GETS IT'),
          const SizedBox(height: 10),
          const SellCard(
            key: Key('sell-delivery-in-place'),
            child: Row(children: [
              Text('📍', style: TextStyle(fontSize: 24)),
              SizedBox(width: 12),
              Expanded(child: Text(
                'Land and property aren\'t delivered. Buyers view it where it is, and '
                'ownership passes by a title transfer - BROKA asks the buyer about the '
                'documents before your money is released.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45),
              )),
            ]),
          ),
        ] else ...[
        sellStepLabel('CAN YOU ARRANGE DELIVERY IF A BUYER NEEDS IT?'),
        const SizedBox(height: 10),
        SellChoiceCard(
          key: const Key('sell-delivery-yes'),
          emoji: '🚚',
          title: 'Yes, I can arrange delivery',
          subtitle: 'You and the buyer agree the cost and the date in the chat.',
          selected: _data.deliveryAvailable == true,
          accent: BrokaColors.neonGreen,
          onTap: () => _setDelivery(true),
        ),
        const SizedBox(height: 10),
        SellChoiceCard(
          key: const Key('sell-delivery-no'),
          emoji: '📍',
          title: 'No, the buyer picks it up',
          subtitle: 'Buyers see the area it\'s in and collect it there.',
          selected: _data.deliveryAvailable == false,
          accent: BrokaColors.neonBlue,
          onTap: () => _setDelivery(false),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: _data.deliveryAvailable == true
              ? Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    sellStepLabel('WHERE CAN YOU DELIVER?  (OPTIONAL)'),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('sell-delivery-note'),
                      controller: _noteCtrl,
                      maxLength: SellWizardData.maxDeliveryNoteLength,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(color: BrokaColors.textHigh),
                      decoration: const InputDecoration(
                          hintText: 'e.g. Within Nairobi, or countrywide by courier'),
                      onChanged: (v) {
                        _data.deliveryNote = v.trim();
                        _scheduleSave();
                      },
                    ),
                  ]),
                )
              : const SizedBox(width: double.infinity),
        ),
        ],
      ]),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: onTap == null ? 0.35 : 1,
          child: Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              boxShadow: onTap == null ? null : const [BrokaColors.glowGold],
            ),
            child: Icon(icon, color: Colors.white),
          ),
        ),
      );
}
