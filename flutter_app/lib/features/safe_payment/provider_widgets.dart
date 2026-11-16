// Small pieces the escrow comparison screens share: the required notice, a
// provider's logo, how current its information is, and the link rules.
//
// WORDING RULES, here because every screen uses these: no "approved",
// "safe", "guaranteed" or "recommended" for a provider BROKA has not
// finished reviewing; "Not documented" for a fact the server did not give,
// never a placeholder that looks like one; an amount that is an estimate is
// called one, and the provider's own checkout is named as the authority.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../main.dart';
import 'provider_directory.dart';

const String kNotDocumented = 'Not documented. Check the provider\'s own website.';

/// The notice BROKA must show wherever it shows a provider.
class DisclosureBox extends StatelessWidget {
  const DisclosureBox({super.key, required this.notice, this.points = const [], this.compact = false});

  final String notice;
  final List<String> points;

  /// Just the notice, without the explanatory points: for a card's footer.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('disclosure-box'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.info_outline_rounded, size: 16, color: BrokaColors.neonBlue),
          SizedBox(width: 6),
          Text('Independent services', style: TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 6),
        Text(notice, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.45)),
        if (!compact && points.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final p in points)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('•  ', style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                Expanded(child: Text(p, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4))),
              ]),
            ),
        ],
      ]),
    );
  }
}

/// A provider's initial in a coloured circle. No provider logo ships with the
/// app (they are the providers' trademarks, and one could not be fetched or
/// cleared to use); the monogram is the same for a given provider every time.
class ProviderLogo extends StatelessWidget {
  const ProviderLogo({super.key, required this.name, this.size = 40});

  final String name;
  final double size;

  static const _colors = [BrokaColors.neonBlue, BrokaColors.neonPurple, BrokaColors.neonCyan, BrokaColors.neonGreen, BrokaColors.neonPink];

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final color = _colors[name.codeUnits.fold<int>(0, (a, b) => a + b) % _colors.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(0.18), border: Border.all(color: color.withOpacity(0.7))),
      child: Text(letter, style: TextStyle(color: color, fontSize: size * 0.45, fontWeight: FontWeight.w900)),
    );
  }
}

/// "Pricing verified 10 Nov 2026" / "Outdated: last verified ..." / "Not yet
/// verified by BROKA", coloured by how much to trust it. Never green unless
/// the server said "current".
class FreshnessChip extends StatelessWidget {
  const FreshnessChip({super.key, required this.freshness, this.prefix = ''});

  final Freshness freshness;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final color = freshness.isCurrent
        ? BrokaColors.success
        : freshness.state == 'expired'
            ? BrokaColors.danger
            : BrokaColors.warning;
    final icon = freshness.isCurrent ? Icons.verified_outlined : Icons.warning_amber_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text('$prefix${freshness.label}',
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

/// A warning line: out of date, unverified, or the provider's own caveat.
class WarningLine extends StatelessWidget {
  const WarningLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.warning_amber_rounded, size: 14, color: BrokaColors.warning),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4))),
        ]),
      );
}

/// Opens [url] in the BROWSER - never inside the app - and only if it is an
/// https address on [provider]'s own domain. The server already refused to send
/// any other (EscrowListing.tryParse); this is the second lock on the way out, so
/// a tampered or stale response cannot send someone to a look-alike site.
Future<bool> openProviderSite(
  BuildContext context,
  EscrowListing provider,
  String url, {
  Future<bool> Function(Uri uri)? openUrl,
}) async {
  if (!isOfficialUrl(url, provider.domain)) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('That address is not ${provider.name}\'s own website, so it was not opened.')),
    );
    return false;
  }
  final uri = Uri.parse(url);
  final opened = await (openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Open ${uri.host} in your browser.')));
  }
  return opened;
}

/// A "label  value" row: [value] null is shown as Not documented.
class FactRow extends StatelessWidget {
  const FactRow(this.label, this.value, {super.key});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final known = value != null && value!.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: const TextStyle(color: BrokaColors.neonGreen, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
        const SizedBox(height: 2),
        Text(known ? value! : kNotDocumented,
            style: TextStyle(color: known ? BrokaColors.textHigh : BrokaColors.textMid, fontSize: 13, height: 1.4,
                fontStyle: known ? FontStyle.normal : FontStyle.italic)),
      ]),
    );
  }
}
