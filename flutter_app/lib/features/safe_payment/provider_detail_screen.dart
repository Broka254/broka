// One escrow provider in full, in eleven sections.
//
// Every fact is the server's, quoted or paraphrased from what the provider
// publishes and attributed to it ("Its terms say ..."). A fact the server did
// not give is "Not documented. Check the provider's own website." - never a
// blank that reads as "none" and never a guess. Nothing here is BROKA's own
// claim about a provider: BROKA is an independent referrer (section 11), it
// holds no money, and the provider's own checkout is the authority on fees.
//
// No ratings, reviews, success rates or user counts appear anywhere: BROKA has
// none that it could stand behind, and an invented one is how a fake escrow
// site looks established.

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../widgets/chat_ambient_background.dart';
import 'provider_directory.dart';
import 'provider_widgets.dart';

class ProviderDetailScreen extends StatelessWidget {
  const ProviderDetailScreen({
    super.key,
    required this.provider,
    required this.notice,
    required this.points,
    this.openUrl,
    this.onZeno,
  });

  final EscrowListing provider;
  final String notice;
  final List<String> points;
  final Future<bool> Function(Uri)? openUrl;
  final void Function(String prompt)? onZeno;

  static const _relationship = [
    'Broka is not a party to your transaction with the provider and has no control over its funds.',
    'Broka lists providers to help you compare them. A listing is information, not a recommendation '
        'and not a promise about how the provider will behave.',
    'Broka cannot recover money held by, or sent through, a provider, and cannot decide a dispute '
        'that the provider is handling.',
    "Details are taken from the provider's own public pages and checked by Broka on the date shown. "
        "Providers can change them at any time: the provider's own checkout is the authority on what "
        'you will pay.',
  ];

  String? _list(Object? v) => v is List && v.isNotEmpty ? v.whereType<String>().join(', ') : null;
  String? _bool(Object? v, String yes, String no) => v == true ? yes : (v == false ? no : null);

  @override
  Widget build(BuildContext context) {
    final p = provider;
    final identity = p.identity;
    final pricing = p.pricing;
    final c = p.conditions;
    final auto = p.protection['auto_release'];
    final notable = p.protection['notable_terms'] is List ? (p.protection['notable_terms'] as List).whereType<String>().toList() : <String>[];
    final other = c['other'] is List ? (c['other'] as List).whereType<String>().toList() : <String>[];
    final legalLabel = identity['legal_entity_label'] as String?;
    final legalName = identity['legal_entity_name'] as String?;

    return ChatAmbientBackground(
      intensity: 0.85,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: BrokaColors.bg.withOpacity(0.55),
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(p.name.toUpperCase(),
              style: const TextStyle(fontSize: 13, letterSpacing: 1.5, fontWeight: FontWeight.w900, color: BrokaColors.textHigh)),
          centerTitle: false,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            DisclosureBox(notice: notice, points: points),
            const SizedBox(height: 14),

            _Section('1', 'Overview', [
              Row(children: [
                ProviderLogo(name: p.name, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.name, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w900)),
                    Text(p.reviewLabel, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ]),
              const SizedBox(height: 10),
              FreshnessChip(freshness: p.recordFreshness, prefix: 'Details: '),
              const SizedBox(height: 6),
              FreshnessChip(freshness: p.pricingFreshness, prefix: 'Pricing: '),
              for (final w in p.warnings) WarningLine(w),
              for (final x in p.notToBeConfusedWith) WarningLine(x.text),
              const SizedBox(height: 10),
              FactRow('Operator', legalName == null ? legalLabel : '$legalName${legalLabel == null ? '' : '\n$legalLabel'}'),
              if ((identity['operator_note'] as String?)?.isNotEmpty ?? false) FactRow('About the operator', identity['operator_note'] as String),
              FactRow('Countries', _list(identity['countries'])),
              FactRow('Transaction types', _list(c['category_labels'])),
              for (final t in notable) WarningLine(t),
            ]),

            _Section('2', 'Fees and charges', [
              FactRow('What it publishes', p.summaries['fees'] ?? p.feeSummary),
              if (pricing['public_note'] is String) FactRow('Note', pricing['public_note'] as String),
              FactRow('How fees are set', _feeBasis(pricing)),
              FactRow('Who pays', _payers(pricing)),
              FactRow('Provider absorbs M-Pesa charges', _bool(pricing['absorbs_mpesa_fees'], 'Yes, it says it pays them', 'No')),
              FactRow('Other fees may apply', _bool(pricing['additional_fees_may_apply'], 'Yes', 'No, it says none')),
              FactRow('Pricing last verified by Broka', p.pricingFreshness.verifiedOn),
              FactRow('Where this was read from', pricing['source_url'] as String?),
              const WarningLine("BROKA's calculator shows an estimate. The quotation on the provider's own checkout is the "
                  'amount you actually pay.'),
            ]),

            _Section('3', 'Transaction limits', [
              FactRow('Limits', p.summaries['limits']),
              FactRow('Minimum', c['min_amount'] is int ? formatKes(c['min_amount'] as int) : null),
              FactRow('Maximum', c['max_amount'] is int ? formatKes(c['max_amount'] as int) : null),
              FactRow('Amount the limits apply to', _basis(c['amount_basis'] as String?)),
              for (final line in other) FactRow('Also published', line),
            ]),

            _Section('4', 'How payment works', [
              FactRow('Buyer pays with', _list(c['payment_method_labels'])),
              FactRow('Seller is paid by', _list(c['payout_method_labels'])),
              FactRow('Funds are held', p.protectionText('how_funds_are_held')),
              FactRow('Funds become locked', p.protectionText('when_funds_locked')),
              const WarningLine('Before you approve an M-Pesa prompt, check the payee, the amount and what it is for. Never '
                  'share your PIN, an OTP or a password, and never pay a personal number given in a chat.'),
              if (p.protectionText('deposit_insurance') != null) WarningLine(p.protectionText('deposit_insurance')!),
            ]),

            _Section('5', 'How funds are released', [
              FactRow('Release conditions', p.protectionText('release_conditions')),
              FactRow('Automatic release',
                  auto is Map && auto['can_occur'] == true ? ((auto['description'] as String?) ?? 'It can happen.')
                      : (auto is Map && auto['can_occur'] == false ? 'It says funds are not released automatically.' : null)),
              FactRow('Buyer confirmation window', p.protectionText('confirmation_window')),
            ]),

            _Section('6', 'Buyer protection', [
              FactRow('What it describes', p.protectionText('buyer_protection')),
              FactRow('Cancellation', p.protectionText('cancellation_policy')),
              const WarningLine("A provider's protection applies only according to that provider's own rules. Broka cannot "
                  'guarantee it.'),
            ]),

            _Section('7', 'Seller protection', [
              FactRow('What it describes', p.protectionText('seller_protection')),
              const WarningLine('Do not dispatch on a payment screenshot or a forwarded SMS. Check the real transaction '
                  "status on the provider's own account or page."),
            ]),

            _Section('8', 'Disputes and refunds', [
              FactRow('How a dispute is started', p.protectionText('dispute_initiation')),
              FactRow('Evidence it asks for', p.protectionText('evidence_required')),
              FactRow('How long it says it takes', p.protectionText('dispute_timeframe')),
              FactRow('Refund conditions', p.protectionText('refund_conditions')),
              const WarningLine('Broka cannot guarantee that a dispute will end in a refund.'),
            ]),

            _Section('9', 'Registration and verification', [
              FactRow('Account', _bool(c['registration_required'], 'Required', 'Not required')),
              FactRow('ID checks (KYC)', _bool(c['kyc_required'], 'Required', 'Not required')),
            ]),

            _Section('10', 'Contacts and official policies', [
              FactRow('Official website', p.websiteUrl),
              FactRow('Email', identity['contact_email'] as String?),
              FactRow('Phone', identity['contact_phone'] as String?),
              FactRow('Terms', identity['terms_url'] as String?),
              FactRow('Privacy policy', identity['privacy_url'] as String?),
              for (final s in p.sources) FactRow('Source: ${s.label}', s.url),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('detail-visit'),
                    onPressed: () => openProviderSite(context, p, p.websiteUrl, openUrl: openUrl),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Visit official website'),
                    style: FilledButton.styleFrom(backgroundColor: BrokaColors.neonBlue, foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  ),
                ),
              ]),
              for (final (label, url) in [('Read its terms', identity['terms_url']), ('Read its privacy policy', identity['privacy_url'])])
                if (url is String && url.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: () => openProviderSite(context, p, url, openUrl: openUrl), child: Text(label)),
                  ),
            ]),

            _Section('11', "Broka's relationship with this provider", [
              for (final line in _relationship)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('•  ', style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
                    Expanded(child: Text(line, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.45))),
                  ]),
                ),
              TextButton.icon(
                onPressed: () => (onZeno ?? (_) {})('Walk me through paying with ${p.name}'),
                icon: const Icon(Icons.auto_awesome_rounded, size: 15),
                label: Text('Ask Zeno to walk me through ${p.name}'),
              ),
              TextButton.icon(
                key: const Key('report-scam'),
                onPressed: () => Navigator.of(context).pushNamed('/report-scam', arguments: {'providerId': p.id}),
                icon: const Icon(Icons.flag_outlined, size: 15),
                label: const Text('Report a suspected scam'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  static String? _basis(String? basis) => switch (basis) {
        'seller_receives' => 'The amount the seller receives',
        'transaction_value' => 'The transaction value (it does not say whether fees are included)',
        _ => null,
      };

  static String? _feeBasis(Map<String, dynamic> pricing) => switch (pricing['disclosure']) {
        'published_fixed' => 'A fixed fee per transaction',
        'published_percentage' => 'A percentage of the amount',
        'published_tiered' => 'A percentage plus a fixed charge, by amount band',
        'quote_required' => 'Shown in its own checkout before you pay (live quotation)',
        'not_disclosed' => 'Not publicly specified',
        'under_review' => 'Under review',
        _ => null,
      };

  static String? _payers(Map<String, dynamic> pricing) {
    final seen = <String>{};
    void add(Object? rule) {
      if (rule is! Map) return;
      final payer = rule['payer'];
      final label = switch (payer) {
        'buyer' => 'buyer',
        'seller' => 'seller',
        'either' => 'buyer or seller',
        _ => null,
      };
      if (label != null) seen.add('${rule['label'] ?? 'Charge'}: $label');
    }

    add(pricing['commission']);
    for (final k in ['processing_fees', 'payout_fees']) {
      if (pricing[k] is List) {
        (pricing[k] as List).forEach(add);
      }
    }
    return seen.isEmpty ? null : seen.join('\n');
  }
}

class _Section extends StatelessWidget {
  const _Section(this.number, this.title, this.children);
  final String number;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          key: Key('section-$number'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$number. $title', style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );
}
