// BROKA - paying a seller safely while BROKA handles no deal payments
// (backend: GET /pricing/safe-payment, api/domains/pricing/safe_payment.py).
//
// For launch BROKA holds no deal money: buyers pay sellers through one of
// Kenya's independent escrow services, and Zeno walks them through it step
// by step (backend zeno_assistant/escrow_walkthrough.py). So escrow is the
// first thing every pay button shows, loudly (escrow_callout.dart), and the
// meet-and-check advice comes after it, for deals collected in person.
//
// The providers, their fees and the advice come from the server, so the
// list can change without an app release. The providers are independent
// businesses: every screen says so beside them, because a buyer who thinks
// BROKA stands behind a provider will blame BROKA when it fails them.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../main.dart';
import '../../screens/zeno_screen.dart';
import '../../utils/auth_gate.dart';
import 'escrow_services_screen.dart';

/// The `code` a payment route answers with while payments are paused.
const String paymentsOffCode = 'IN_APP_PAYMENTS_OFF';

/// What the user says to Zeno to start the walkthrough - one of the
/// phrases the server answers without a model (escrow_walkthrough.py).
const String zenoEscrowPrompt = ZenoScreen.escrowOpener;

class EscrowProvider {
  const EscrowProvider({
    required this.name,
    required this.url,
    required this.note,
    this.id = '',
    this.tagline = '',
    this.bestFor = '',
    this.pay = '',
    this.fees = '',
    this.limits = '',
    this.start = '',
    this.release = '',
    this.payout = '',
    this.dispute = '',
  });

  final String id;
  final String name;
  final String url;

  /// One line under the name - what older builds showed, and the fallback.
  final String note;
  final String tagline;
  final String bestFor;

  /// How the buyer pays in, how a deal starts, how the buyer releases the
  /// money, how the seller is paid (said to the seller), and disputes - as
  /// the provider publishes them.
  final String pay;
  final String fees;
  final String limits;
  final String start;
  final String release;
  final String payout;
  final String dispute;

  /// Where the site lives, as a person would type it.
  String get site => url.replaceFirst(RegExp(r'^https?://(www\.)?'), '').replaceFirst(RegExp(r'/$'), '');

  factory EscrowProvider.fromJson(Map<String, dynamic> j) {
    String s(String k) => (j[k] as String? ?? '').trim();
    return EscrowProvider(
      id: s('id'),
      name: s('name'),
      url: s('url'),
      note: s('note'),
      tagline: s('tagline'),
      bestFor: s('best_for'),
      pay: s('pay'),
      fees: s('fees'),
      limits: s('limits'),
      start: s('start'),
      release: s('release'),
      payout: s('payout'),
      dispute: s('dispute'),
    );
  }
}

/// One beat of how escrow works, whichever service.
class EscrowBeat {
  const EscrowBeat(this.title, this.detail);
  final String title;
  final String detail;
}

class SafePaymentInfo {
  const SafePaymentInfo({
    required this.inAppPayments,
    required this.message,
    required this.advice,
    required this.providers,
    required this.disclaimer,
    this.escrowRules = const [],
    this.howEscrowWorks = const [],
    this.zenoHelp = '',
  });

  final bool inAppPayments;
  final String message;
  final List<String> advice;
  final List<EscrowProvider> providers;
  final String disclaimer;
  final List<String> escrowRules;
  final List<EscrowBeat> howEscrowWorks;
  final String zenoHelp;

  factory SafePaymentInfo.fromJson(Map<String, dynamic> j) => SafePaymentInfo(
        inAppPayments: j['in_app_payments'] == true,
        message: j['message'] as String? ?? '',
        advice: [for (final a in (j['advice'] as List? ?? const [])) '$a'],
        providers: [
          for (final p in (j['providers'] as List? ?? const []))
            if (p is Map) EscrowProvider.fromJson(p.cast<String, dynamic>()),
        ].where((p) => p.name.isNotEmpty && p.url.startsWith('https://')).toList(),
        disclaimer: j['disclaimer'] as String? ?? '',
        escrowRules: [for (final r in (j['escrow_rules'] as List? ?? const [])) '$r'],
        howEscrowWorks: [
          for (final b in (j['how_escrow_works'] as List? ?? const []))
            if (b is Map && b['title'] is String) EscrowBeat(b['title'] as String, '${b['detail'] ?? ''}'),
        ],
        zenoHelp: j['zeno_help'] as String? ?? '',
      );

  /// What the app shows when the server can't be reached: the services by
  /// name and address only - their fees change, so those come from the
  /// server or not at all - with the rules that matter most.
  static const offline = SafePaymentInfo(
    inAppPayments: false,
    message: '',
    advice: [
      'Collecting in person? Meet in a busy public place and check the item works before you pay.',
      'Never send a deposit to "hold" an item, whatever the reason given.',
    ],
    providers: [
      EscrowProvider(name: 'E-Confirm', url: 'https://econfirm.co.ke',
          note: 'M-Pesa escrow for buyers and sellers.'),
      EscrowProvider(name: 'Escrow Kenya', url: 'https://escrowkenya.com',
          note: 'Pay by M-Pesa or bank. Not the same company as Kenya Escrow.'),
      EscrowProvider(name: 'Kenya Escrow', url: 'https://www.kenyaescrow.com',
          note: 'M-Pesa escrow, no account to create. Not the same company as Escrow Kenya.'),
      EscrowProvider(name: 'Lipasafe', url: 'https://lipasafe.co.ke',
          note: 'M-Pesa escrow; every user is ID-checked.'),
      EscrowProvider(name: 'Shikilia', url: 'https://www.shikilia.co.ke',
          note: 'Escrow that runs on WhatsApp.'),
    ],
    escrowRules: [
      'Open the escrow service yourself from this list. Never use an escrow link, paybill or '
          "'agent' the other person sends you - fake escrow sites are a common scam.",
      'Buyers: pay the escrow service, never the seller.',
      'Sellers: hand over nothing on a screenshot or an SMS - check on the escrow service itself.',
    ],
    howEscrowWorks: [
      EscrowBeat('Agree the deal', "Price, what's included, delivery - and the escrow service you'll use."),
      EscrowBeat('The buyer pays the escrow service', 'Not the seller. The service holds the money.'),
      EscrowBeat('The seller delivers', 'Once the service shows the money is held.'),
      EscrowBeat('The buyer releases the money', 'The service pays the seller.'),
    ],
    zenoHelp: 'Not sure how? Zeno walks you through it, one step at a time.',
    disclaimer: "These are independent services. BROKA doesn't run them, isn't paid by them, and "
        "can't get money back from them - check their fees and terms before you pay.",
  );
}

class SafePaymentRepository {
  SafePaymentRepository({ApiClient? client}) : _client = client ?? apiClient;

  final ApiClient _client;
  static SafePaymentInfo? _cached;

  /// The server's advice; null when it can't be reached. Kept for the
  /// session once fetched - it changes with a server setting, not by the
  /// minute.
  Future<SafePaymentInfo?> fetch() async {
    if (_cached != null) return _cached;
    try {
      final data = await _client.get('/pricing/safe-payment');
      return _cached = SafePaymentInfo.fromJson((data as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}

final safePaymentRepository = SafePaymentRepository();

/// Opens Zeno on the escrow walkthrough. Zeno needs an account, so a guest
/// is asked to sign in first.
Future<void> openZenoEscrowGuide(BuildContext context, {String prompt = zenoEscrowPrompt}) async {
  if (!await requireAuth(context, reason: 'so Zeno can walk you through paying with escrow')) return;
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => ZenoScreen(initialQuery: prompt),
  ));
}

/// The escrow services, on a screen of their own.
Future<void> openEscrowServices(BuildContext context, {SafePaymentRepository? repository}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EscrowServicesScreen(repository: repository),
    ));

/// Opens [url] in the browser; says where to go when it can't.
Future<void> openEscrowSite(BuildContext context, String url, {Future<bool> Function(Uri)? openUrl}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return;
  final ok = await (openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Open ${uri.host} in your browser.')));
  }
}

/// Shown where the app would have taken a payment: escrow, loudly, then
/// what else keeps a buyer safe.
Future<void> showSafePaymentSheet(BuildContext context,
    {SafePaymentRepository? repository,
    Future<bool> Function(Uri)? openUrl}) async {
  final info = await (repository ?? safePaymentRepository).fetch();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: BrokaColors.bgCard,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (sheet) => FractionallySizedBox(
      heightFactor: 0.9,
      child: SafePaymentView(
        info: info,
        openUrl: openUrl,
        onZeno: () {
          Navigator.of(sheet).pop();
          openZenoEscrowGuide(context);
        },
        onAllServices: () {
          Navigator.of(sheet).pop();
          openEscrowServices(context, repository: repository);
        },
      ),
    ),
  );
}

class SafePaymentView extends StatelessWidget {
  const SafePaymentView({super.key, required this.info, this.openUrl, this.onZeno, this.onAllServices});

  /// Null when the server couldn't be reached: the services by name, and
  /// the core advice, still show (SafePaymentInfo.offline).
  final SafePaymentInfo? info;
  final Future<bool> Function(Uri)? openUrl;
  final VoidCallback? onZeno;
  final VoidCallback? onAllServices;

  @override
  Widget build(BuildContext context) {
    final shown = info ?? SafePaymentInfo.offline;
    final providers = shown.providers.isNotEmpty ? shown.providers : SafePaymentInfo.offline.providers;
    final advice = shown.advice.isNotEmpty ? shown.advice : SafePaymentInfo.offline.advice;
    const body = TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: BrokaColors.neonGreen.withOpacity(0.16),
                  boxShadow: [BoxShadow(color: BrokaColors.neonGreen.withOpacity(0.35), blurRadius: 16)],
                ),
                child: const Icon(Icons.shield_rounded, color: BrokaColors.neonGreen, size: 21),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Pay safely with escrow',
                    style: TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w900)),
              ),
            ]),
            const SizedBox(height: 10),
            const Text(
              "BROKA doesn't take payments itself yet. An escrow service holds the buyer's money "
              'and pays the seller only once the buyer has the item.',
              style: body,
            ),
            const SizedBox(height: 14),
            ZenoGuideButton(onTap: onZeno ?? () => openZenoEscrowGuide(context)),
            const SizedBox(height: 16),
            const Text('Escrow services',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            for (final p in providers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.verified_user_outlined, color: BrokaColors.neonGreen, size: 20),
                title: Text(p.name,
                    style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
                subtitle: Text(p.tagline.isNotEmpty ? '${p.tagline} · ${p.site}' : p.note, style: body),
                trailing: const Icon(Icons.open_in_new, size: 18, color: BrokaColors.neonBlue),
                onTap: () => openEscrowSite(context, p.url, openUrl: openUrl),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onAllServices ?? () => openEscrowServices(context),
                icon: const Icon(Icons.compare_arrows_rounded, size: 18),
                label: const Text('Compare fees and how each one works'),
              ),
            ),
            if (shown.escrowRules.isNotEmpty) ...[
              const SizedBox(height: 6),
              _Rule(shown.escrowRules.first, style: body),
            ],
            const SizedBox(height: 14),
            const Text('Collecting in person',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            for (final a in advice)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(Icons.check_circle_outline, size: 15, color: BrokaColors.neonGreen),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(a, style: body)),
                ]),
              ),
            const SizedBox(height: 6),
            Text(shown.disclaimer,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule(this.text, {required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: BrokaColors.danger.withOpacity(0.09),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.danger.withOpacity(0.35)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: BrokaColors.danger),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: style.copyWith(color: BrokaColors.textHigh))),
        ]),
      );
}

/// "Let Zeno guide me, step by step" - the button that tells people Zeno
/// helps with escrow, wherever escrow is offered.
class ZenoGuideButton extends StatelessWidget {
  const ZenoGuideButton({super.key, required this.onTap, this.label = 'Let Zeno guide me, step by step'});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.brandGradient),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.35), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(children: [
                const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
                ),
                const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 19),
              ]),
            ),
          ),
        ),
      );
}
