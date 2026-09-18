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
