// Pay with escrow - Kenya's independent escrow services, side by side, and
// Zeno to walk the user through whichever they pick (2026-10-08).
//
// BROKA holds no deal money for launch: an escrow service is how a buyer
// who can't see the item first is protected, and most people here have
// never used one. So this screen answers what a first-timer asks, in the
// order they ask it: what escrow is, which service, what it costs, how a
// deal goes on it - and "can someone just walk me through it?", which is
// Zeno's walkthrough (backend zeno_assistant/escrow_walkthrough.py), one
// tap away from the top and from every service.
//
// Everything about a service comes from GET /pricing/safe-payment, as the
// service publishes it; offline, the services still show by name and
// address (SafePaymentInfo.offline) and fees are left to their sites.

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../widgets/chat_ambient_background.dart';
import 'safe_payment.dart';

class EscrowServicesScreen extends StatefulWidget {
  const EscrowServicesScreen({super.key, this.repository, this.openUrl, this.onZeno});

  final SafePaymentRepository? repository;

  /// Tests pass these; the app opens the browser and Zeno.
  final Future<bool> Function(Uri)? openUrl;
  final void Function(String prompt)? onZeno;

  @override
  State<EscrowServicesScreen> createState() => _EscrowServicesScreenState();
}

class _EscrowServicesScreenState extends State<EscrowServicesScreen> {
  SafePaymentInfo? _info;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    (widget.repository ?? safePaymentRepository).fetch().then((info) {
      if (mounted) setState(() { _info = info; _loading = false; });
    });
  }

  void _zeno(String prompt) =>
      widget.onZeno != null ? widget.onZeno!(prompt) : openZenoEscrowGuide(context, prompt: prompt);

  @override
  Widget build(BuildContext context) {
    final info = _info ?? SafePaymentInfo.offline;
    final providers = info.providers.isNotEmpty ? info.providers : SafePaymentInfo.offline.providers;
    final beats = info.howEscrowWorks.isNotEmpty ? info.howEscrowWorks : SafePaymentInfo.offline.howEscrowWorks;
    final rules = info.escrowRules.isNotEmpty ? info.escrowRules : SafePaymentInfo.offline.escrowRules;
    return ChatAmbientBackground(
      intensity: 0.85,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: BrokaColors.bg.withOpacity(0.55),
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text('PAY WITH ESCROW',
              style: TextStyle(fontSize: 13, letterSpacing: 1.5,
                  fontWeight: FontWeight.w900, color: BrokaColors.textHigh)),
          centerTitle: false,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            _Hero(onBuyer: () => _zeno(zenoEscrowPrompt),
                onSeller: () => _zeno('How do I get paid through escrow?'),
                zenoHelp: info.zenoHelp),
            const SizedBox(height: 18),
            const _Heading('How escrow works'),
            for (final (i, b) in beats.indexed) _Beat(number: i + 1, beat: b),
            const SizedBox(height: 14),
            _RulesBox(rules: rules),
            const SizedBox(height: 18),
            _Heading(_loading ? 'Escrow services in Kenya…' : 'Escrow services in Kenya'),
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                'Pick one with the other person and agree it in the BROKA chat. Not sure which? '
                'Zeno helps you choose.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.45),
              ),
            ),
            for (final p in providers)
              _ProviderCard(
                provider: p,
                onOpen: () => openEscrowSite(context, p.url, openUrl: widget.openUrl),
                onZeno: () => _zeno('Walk me through paying with ${p.name}'),
              ),
            if (info.advice.isNotEmpty) ...[
              const SizedBox(height: 10),
              const _Heading('More ways to stay safe'),
              for (final a in info.advice)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.check_circle_outline, size: 15, color: BrokaColors.neonGreen),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(a, style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12.5, height: 1.45))),
                  ]),
                ),
            ],
            const SizedBox(height: 12),
            Text(info.disclaimer,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(
            color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800)),
      );
}

class _Hero extends StatelessWidget {
  const _Hero({required this.onBuyer, required this.onSeller, required this.zenoHelp});
  final VoidCallback onBuyer;
  final VoidCallback onSeller;
  final String zenoHelp;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [BrokaColors.neonGreen.withOpacity(0.22), BrokaColors.bgCard, BrokaColors.neonPurple.withOpacity(0.18)],
          ),
          border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.55), width: 1.4),
          boxShadow: [BoxShadow(color: BrokaColors.neonGreen.withOpacity(0.18), blurRadius: 24)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.shield_rounded, color: BrokaColors.neonGreen, size: 30),
            SizedBox(width: 10),
            Expanded(
              child: Text('Pay safely with escrow',
                  style: TextStyle(color: BrokaColors.textHigh, fontSize: 21, fontWeight: FontWeight.w900)),
            ),
          ]),
          const SizedBox(height: 10),
          const Text(
            "BROKA doesn't take payments itself yet. These independent services hold the buyer's "
            'money and pay the seller only once the buyer has what they paid for.',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, height: 1.45),
          ),
          if (zenoHelp.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(zenoHelp, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
          ],
          const SizedBox(height: 14),
          ZenoGuideButton(onTap: onBuyer),
          const SizedBox(height: 6),
          Center(
            child: TextButton(
              onPressed: onSeller,
              child: const Text("I'm selling - show me how to get paid",
                  style: TextStyle(color: BrokaColors.neonCyan, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      );
}

class _Beat extends StatelessWidget {
  const _Beat({required this.number, required this.beat});
  final int number;
  final EscrowBeat beat;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 26, height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: BrokaColors.neonGreen.withOpacity(0.16),
                border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.6))),
            child: Text('$number', style: const TextStyle(
                color: BrokaColors.neonGreen, fontSize: 12, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(beat.title, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w700)),
              if (beat.detail.isNotEmpty)
                Text(beat.detail, style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
            ]),
          ),
        ]),
      );
}

class _RulesBox extends StatelessWidget {
  const _RulesBox({required this.rules});
  final List<String> rules;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: BrokaColors.danger.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.danger.withOpacity(0.4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.warning_amber_rounded, color: BrokaColors.danger, size: 19),
            SizedBox(width: 8),
            Text('Before you pay', style: TextStyle(
                color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          for (final r in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('•  ', style: TextStyle(color: BrokaColors.danger, fontWeight: FontWeight.w900)),
                Expanded(child: Text(r, style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 12.5, height: 1.45))),
              ]),
            ),
        ]),
      );
}

class _ProviderCard extends StatefulWidget {
  const _ProviderCard({required this.provider, required this.onOpen, required this.onZeno});
  final EscrowProvider provider;
  final VoidCallback onOpen;
  final VoidCallback onZeno;

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  bool _open = false;

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _fact(String label, String value) => value.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '$label  ', style: const TextStyle(
                color: BrokaColors.neonGreen, fontSize: 12, fontWeight: FontWeight.w800)),
            TextSpan(text: _cap(value), style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
          ])),
        );

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final detailed = p.start.isNotEmpty || p.release.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.verified_user_outlined, color: BrokaColors.neonGreen, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(p.name, style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w900)),
          ),
          Text(p.site, style: const TextStyle(color: BrokaColors.neonBlue, fontSize: 11.5)),
        ]),
        if (p.tagline.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(p.tagline, style: const TextStyle(
                color: BrokaColors.neonCyan, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(p.note, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
        ),
        _fact('BEST FOR', p.bestFor),
        _fact('YOU PAY WITH', p.pay),
        _fact('FEES', p.fees),
        _fact('LIMITS', p.limits),
        if (detailed && _open) ...[
          _fact('STARTING A DEAL', p.start),
          _fact('RELEASING THE MONEY', p.release),
          _fact('THE SELLER IS PAID', p.payout),
          _fact('IF SOMETHING GOES WRONG', p.dispute),
        ],
        if (detailed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => setState(() => _open = !_open),
              child: Text(_open ? 'Less' : 'How a deal works on ${p.name}',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
          ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: widget.onOpen,
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text('Open ${p.name}', overflow: TextOverflow.ellipsis),
              style: OutlinedButton.styleFrom(
                foregroundColor: BrokaColors.textHigh,
                side: BorderSide(color: BrokaColors.neonBlue.withOpacity(0.6)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: widget.onZeno,
              icon: const Icon(Icons.auto_awesome_rounded, size: 16),
              label: const Text('Zeno, guide me', overflow: TextOverflow.ellipsis),
              style: FilledButton.styleFrom(
                backgroundColor: BrokaColors.neonPurple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}
