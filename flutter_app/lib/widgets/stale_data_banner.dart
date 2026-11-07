// One line over content the app could not refresh: what is shown is the
// copy saved on this phone, how old it is, and a Retry. Shown only after a
// refresh FAILED - a saved copy shown while a refresh is still on its way is
// not out of date yet, and saying so on every open would be noise.
import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;

class StaleDataBanner extends StatelessWidget {
  const StaleDataBanner({
    super.key,
    required this.fetchedAt,
    required this.onRetry,
    this.what = 'info',
    this.margin = const EdgeInsets.fromLTRB(16, 4, 16, 8),
    this.now,
  });

  /// When the copy shown was fetched. Null: age unknown.
  final DateTime? fetchedAt;
  final VoidCallback onRetry;

  /// What is shown, for the sentence: "listings", "dashboard figures".
  final String what;
  final EdgeInsets margin;

  /// For tests.
  final DateTime? now;

  static String age(DateTime fetchedAt, DateTime now) {
    final d = now.difference(fetchedAt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return d.inHours == 1 ? '1 hour ago' : '${d.inHours} hours ago';
    return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final at = fetchedAt;
    final when = at == null ? '' : ' from ${age(at, now ?? DateTime.now())}';
    return Container(
      key: const Key('stale-data-banner'),
      margin: margin,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: BrokaColors.warning.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.warning.withOpacity(0.35)),
      ),
      child: Row(children: [
        const Icon(Icons.cloud_off_rounded, size: 16, color: BrokaColors.warning),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            "Couldn't refresh. Showing saved $what$when.",
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.25),
          ),
        ),
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: BrokaColors.warning,
          ),
          child: const Text('Retry', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}
