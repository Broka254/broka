// BROKA - paying a seller safely while BROKA handles no deal payments
// (backend: GET /pricing/safe-payment, api/domains/pricing/safe_payment.py).
//
// The advice and the escrow providers come from the server, so the list can
// change without an app release. The providers are independent businesses:
// the sheet says so beside them, every time, because a buyer who thinks
// BROKA stands behind a provider will blame BROKA when it fails them.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../main.dart';

/// The `code` a payment route answers with while payments are paused.
const String paymentsOffCode = 'IN_APP_PAYMENTS_OFF';

class EscrowProvider {
  const EscrowProvider({required this.name, required this.url, required this.note});

  final String name;
  final String url;
  final String note;

  factory EscrowProvider.fromJson(Map<String, dynamic> j) => EscrowProvider(
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        note: j['note'] as String? ?? '',
      );
}

class SafePaymentInfo {
  const SafePaymentInfo({
    required this.inAppPayments,
    required this.message,
    required this.advice,
    required this.providers,
    required this.disclaimer,
  });

  final bool inAppPayments;
  final String message;
  final List<String> advice;
  final List<EscrowProvider> providers;
  final String disclaimer;

  factory SafePaymentInfo.fromJson(Map<String, dynamic> j) => SafePaymentInfo(
        inAppPayments: j['in_app_payments'] == true,
        message: j['message'] as String? ?? '',
        advice: [for (final a in (j['advice'] as List? ?? const [])) '$a'],
        providers: [
          for (final p in (j['providers'] as List? ?? const []))
            if (p is Map) EscrowProvider.fromJson(p.cast<String, dynamic>()),
        ],
        disclaimer: j['disclaimer'] as String? ?? '',
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

/// Shown where the app would have taken a payment: what to do instead.
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
    builder: (_) => SafePaymentView(info: info, openUrl: openUrl),
  );
}

class SafePaymentView extends StatelessWidget {
  const SafePaymentView({super.key, required this.info, this.openUrl});

  /// Null when the server couldn't be reached: the core advice still shows.
  final SafePaymentInfo? info;
  final Future<bool> Function(Uri)? openUrl;

  static const _fallbackAdvice = [
    'Meet in a busy public place and check the item works before you pay.',
    'Pay only after you have the item. Never send a deposit to "hold" it.',
  ];

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await (openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Open $url in your browser.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final advice = info?.advice.isNotEmpty == true ? info!.advice : _fallbackAdvice;
    const body = TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(children: [
              Icon(Icons.shield_outlined, color: BrokaColors.neonGreen, size: 20),
              SizedBox(width: 10),
              Text('Paying safely',
                  style: TextStyle(color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 10),
            const Text(
              "BROKA doesn't handle payments yet. You pay the seller directly, so "
              'these steps are your protection.',
              style: body,
            ),
            const SizedBox(height: 14),
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
            if (info != null && info!.providers.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Escrow services',
                  style: TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              // Not "anything expensive": an M-Pesa escrow carries at most
              // KES 250,000 a payment, and the advice above sends land and
              // cars through a bank or an advocate.
              const Text("For a deal at a distance, or anything you can't collect.", style: body),
              const SizedBox(height: 8),
              for (final p in info!.providers)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(p.name,
                      style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
                  subtitle: Text(p.note, style: body),
                  trailing: const Icon(Icons.open_in_new, size: 18, color: BrokaColors.neonBlue),
                  onTap: () => _open(context, p.url),
                ),
              const SizedBox(height: 6),
              Text(info!.disclaimer,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4)),
            ],
          ],
        ),
      ),
    );
  }
}
