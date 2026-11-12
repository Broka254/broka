// A seller's phone number, as a buyer reads and dials it.
//
// Numbers are stored however the account was made - 0712..., 254712...,
// +254712... (backend api/core/sms.py normalises them only to send). Shown
// raw, the same number looked different from one profile to the next, and
// "254712345678" reads as a code, not a phone number.

String _digits(String raw) => raw.replaceAll(RegExp(r'[^0-9]'), '');

/// The nine digits after +254 for a Kenyan number, else null.
String? _kenyanLocal(String raw) {
  final d = _digits(raw);
  if (d.length == 12 && d.startsWith('254')) return d.substring(3);
  if (d.length == 10 && d.startsWith('0')) return d.substring(1);
  if (d.length == 9 && (d.startsWith('7') || d.startsWith('1'))) return d;
  return null;
}

/// "+254 712 345 678" for a Kenyan number however it was stored; anything
/// else as it came, trimmed.
String formatPhone(String raw) {
  final local = _kenyanLocal(raw);
  if (local == null) return raw.trim();
  return '+254 ${local.substring(0, 3)} ${local.substring(3, 6)} ${local.substring(6)}';
}

/// What the dialer is handed: "+254712345678", or the number's own digits
/// (with its "+") when it isn't a Kenyan one.
String dialablePhone(String raw) {
  final local = _kenyanLocal(raw);
  if (local != null) return '+254$local';
  final d = _digits(raw);
  return raw.trim().startsWith('+') ? '+$d' : d;
}
