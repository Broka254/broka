// BROKA — one place that turns a KES amount into the string a user reads.
//
// Home collapsing-scroll pass (2026-09-18, §5 of the brief): prices used to
// be abbreviated - "KES 15K", "KES 1.5M", "KES 125K". Three separate copies
// of that logic had drifted apart (ProductCard._formatKes,
// BrokaListing.priceFormatted, HomeScreen._formatPrice), and every one of
// them lost information the buyer actually needs: "KES 15K" is any amount
// from 14,500 to 15,499, and on a marketplace the difference between
// KES 15,000 and KES 15,400 is the whole negotiation. Full digit-grouped
// integers now, everywhere, with the abbreviation removed rather than
// re-tuned. Card layouts absorb the extra width by scaling the price text
// down (see ProductCard's FittedBox) instead of shortening the number.
library;

import 'package:flutter/services.dart';

/// Groups [v] with commas and no decimals: 1500000 -> "1,500,000".
///
/// Fractional cents are rounded away deliberately - no listing in this app
/// is priced below one shilling, and "KES 1,300.00" is noise on a card.
String formatKesAmount(num v) {
  final rounded = v.round();
  final negative = rounded < 0;
  final digits = rounded.abs().toString();
  final buf = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return negative ? '-${buf.toString()}' : buf.toString();
}

/// The same number with the currency prefix: 15000 -> "KES 15,000".
String formatKes(num v) => 'KES ${formatKesAmount(v)}';

/// The highest price a listing may have: what BROKA can hold in escrow for
/// one deal. The server refuses more (MAX_PRICE_KES in
/// backend/api/domains/listings/validation.py); the sell wizard says so
/// before the seller gets that far.
const maxListingPriceKes = 20000000;

/// What a seller typed into an amount field, as a number: "2,500,000" ->
/// 2500000. Null for empty or unreadable text - and for "NaN" and
/// "Infinity", which double.tryParse accepts and JSON can't carry.
double? parseKesInput(String text) {
  final value = double.tryParse(text.replaceAll(RegExp(r'[,\s]'), ''));
  return value != null && value.isFinite ? value : null;
}

/// Whole shillings, grouped as they're typed: "2500000" shows as
/// "2,500,000". Digits only, so there's nothing to mistype - a price used
/// to accept "2,500,000" nowhere and "NaN" everywhere.
class KesInputFormatter extends TextInputFormatter {
  const KesInputFormatter({this.maxDigits = 9});

  final int maxDigits;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > maxDigits) return oldValue;
    digits = digits.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
    final text = digits.isEmpty ? '' : formatKesAmount(int.parse(digits));
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
