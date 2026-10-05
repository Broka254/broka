// BROKA — how it works
//
// The explainer a seller can read once and stop guessing.
//
// Everything on the dashboard assumes the seller already knows what DCR is,
// why rank matters, and what escrow does. None of that is obvious, and a
// number nobody understands is a number nobody acts on — a seller who does
// not know that off-platform deals cost them ranking has no reason to stop
// doing them, and every metric on the dashboard is then just decoration.
//
// Written plainly and without marketing. The claims here are mechanical —
// this is what the code does — so they have to stay true as the code
// changes. Nothing on this screen quotes a statistic, because the moment it
// does, someone has to keep it honest.

import 'package:flutter/material.dart';

import '../features/safe_payment/safe_payment.dart';
import '../main.dart';
import '../widgets/chat_ambient_background.dart';
import '../widgets/motion_widgets.dart';

class _Topic {
  final IconData icon;
  final Color accent;
  final String title;
  final String lede;
  final List<String> body;
  const _Topic(this.icon, this.accent, this.title, this.lede, this.body);
}

const List<_Topic> _topics = [
  _Topic(
    Icons.lock_rounded, BrokaColors.neonGreen,
    'Escrow: how money moves',
    'The buyer pays BROKA, not you. You get paid when they confirm delivery.',
    [
      'When a buyer agrees a price, they pay into escrow. The money leaves '
      'their account, so you know it is real — but it does not reach you '
      'yet. BROKA holds it.',
      'You hand over the item. The buyer confirms they received it, and the '
      'money is released to you.',
      'If the buyer never confirms, the deal resolves on a timer rather than '
      'sitting forever. If something goes genuinely wrong, either side can '
      'open a dispute and the evidence from the deal is reviewed.',
      'This is why BROKA can put a stranger in front of you. Without it, '
      'every first-time buyer has to decide whether to trust someone they '
      'have never met with their money — and most of them decide not to.',
    ],
  ),
  _Topic(
    Icons.verified_rounded, BrokaColors.gold,
    'Deal completion rate',
    'The share of your deals that actually finish on BROKA.',
    [
      'A deal counts as completed when payment goes through escrow and the '
      'buyer confirms. A deal settled in cash outside the app does not '
      'count — not because we are trying to catch you out, but because '
      'BROKA has no way to know it happened.',
      'It is smoothed, which protects you from a bad week and stops anyone '
      'gaming it with a handful of tiny deals. A new seller does not start '
      'at zero; they start near the platform average and move from there as '
      'evidence accumulates.',
      'Recent deals count for more than old ones. A rough patch a year ago '
      'fades; how you have been trading this month is what shows.',
      'This is the heaviest single input to your rating and your ranking. '
      'If you change one thing, change this.',
    ],
  ),
  _Topic(
    Icons.speed_rounded, BrokaColors.neonBlue,
    'Response time',
    'How long buyers wait for you, measured from their message to your reply.',
    [
      'Measured across your recent conversations and reported as a median, '
      'so one forgotten thread does not define your month.',
      'A conversation you never answer counts too. Leaving a buyer on read '
      'is treated as at least as costly as a slow reply — otherwise '
      'ignoring people would look better than being late.',
      'It is the fastest thing on this screen to change. Completion rate '
      'takes weeks of closed deals to move; reply speed moves this '
      'afternoon.',
      'It matters because buyers rarely message one seller. Whoever answers '
      'first is usually who they buy from.',
    ],
  ),
  _Topic(
    Icons.star_rounded, BrokaColors.gold,
    'Your rating',
    'One number out of ten, combining everything you control.',
    [
      'Completion rate carries the most weight, then response time, then '
      'the volume of deals you have closed. Your backlog of unresolved '
      'deals pulls it down.',
      'Time on BROKA counts for very little here — deliberately. Being '
      'around a long time is not the same as being good, and a careful new '
      'seller should be able to out-rate a careless old one.',
      'Thin evidence is treated as thin. Two perfect deals do not produce a '
      'perfect rating; the number stays near the middle until there is '
      'enough history to say more. That cuts both ways, and it is what '
      'stops a brand-new account outranking someone with years of work '
      'behind them.',
    ],
  ),
  _Topic(
    Icons.shield_rounded, BrokaColors.neonCyan,
    'Credibility',
    'Your track record, as opposed to your current form.',
    [
      'Where the rating asks "how are you trading right now", credibility '
      'asks "how long have you been doing this properly". It leans on your '
      'completion rate and on how long you have been here.',
      'It is slow on purpose. It cannot be fixed in an afternoon, which is '
      'exactly what makes it worth something to a buyer deciding whether to '
      'send money to someone they have never met.',
      'Time alone does not buy it. A seller of two years whose deals keep '
      'leaving the platform scores below a careful six-month-old account.',
    ],
  ),
  _Topic(
    Icons.leaderboard_rounded, BrokaColors.neonBlue,
    'Ranking, and what buyers see first',
    'Position is earned. There is no way to pay for it.',
    [
      'Your rank is computed from your completion rate, your response time '
      'and your credibility. That rank decides how high your listings sit '
      'when a buyer searches your category.',
      'There is no featured placement, no promoted listing and no paid '
      'badge on BROKA. We removed them. If position could be bought, there '
      'would be no reason for anyone to work on any of the numbers above, '
      'and a buyer could no longer read the order of results as meaning '
      'anything.',
      'The practical consequence: the seller ahead of you got there by '
      'closing deals here and answering quickly. So can you, and nobody can '
      'outspend you to stop it.',
    ],
  ),
  _Topic(
    Icons.storefront_rounded, BrokaColors.gold,
    'Your online store',
    'All your listings behind one link you can share anywhere.',
    [
      'Most people running a real business here are managing many listings, '
      'not one. A store gathers them into a shop of your own with its own '
      'address — broka.co.ke/store/yourname.',
      'Put that link on WhatsApp status, on Instagram, on your shop sign. A '
      'customer who came for one item sees everything else you stock, which '
      'is the difference between a sale and a customer.',
      // Not "every sale still runs through escrow": none does while BROKA
      // holds no payments, and this screen shows either way.
      'It is free. A sale from your store counts toward your rating and '
      'ranking exactly as any other sale does.',
    ],
  ),
  _Topic(
    Icons.videocam_rounded, BrokaColors.neonGreen,
    'Calls and video',
    'Show the item without anyone travelling.',
    [
      'Buyers who want to see something before paying do not have to come '
      'to you. Start a video call from the chat and flip to the rear camera '
      '— they get the same look they would have got in person.',
      'It closes deals the same day instead of whenever you can both be in '
      'the same place, and it removes the trip that makes a buyer decide it '
      'is not worth the effort.',
      'Calls stay inside BROKA, so neither side has to hand out a phone '
      'number to a stranger.',
    ],
  ),
];

// While BROKA handles no deal payments (GET /pricing/safe-payment says
// so), the escrow topic would describe a payment buyers can't make: it is
// replaced by how to pay a seller safely.
const _payingSafely = _Topic(
  Icons.shield_outlined, BrokaColors.neonGreen,
  'Paying safely',
  "BROKA doesn't handle payments yet. The buyer pays you directly.",
  [
    'Buyers are advised to meet somewhere public and check the item before '
    'paying, and never to send a deposit to hold something.',
    // Land and cars apart: M-Pesa moves at most KES 250,000 a payment, so
    // an M-Pesa escrow can't carry them, and the official search is what
    // proves the seller owns it (the server's advice, safe_payment.py).
    'For a deal at a distance, an independent escrow service can hold the '
    'money until the buyer has the item; they are not run by BROKA. Land and '
    'cars go through an official search and a bank or advocate. Tap below '
    'for both.',
  ],
);

class HowBrokaWorksScreen extends StatefulWidget {
  const HowBrokaWorksScreen({super.key, this.repository});

  final SafePaymentRepository? repository;

  @override
  State<HowBrokaWorksScreen> createState() => _HowBrokaWorksScreenState();
}

class _HowBrokaWorksScreenState extends State<HowBrokaWorksScreen> {
  List<_Topic> _shown = _topics;

  @override
  void initState() {
    super.initState();
    (widget.repository ?? safePaymentRepository).fetch().then((info) {
      if (!mounted || info == null || info.inAppPayments) return;
      setState(() => _shown = [_payingSafely, ..._topics.skip(1)]);
    });
  }

  @override
  Widget build(BuildContext context) => ChatAmbientBackground(
        intensity: 0.85,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: BrokaColors.bg.withOpacity(0.55),
            elevation: 0,
            scrolledUnderElevation: 0,
            title: const Text('HOW BROKA WORKS',
                style: TextStyle(fontSize: 13, letterSpacing: 1.5,
                    fontWeight: FontWeight.w900, color: BrokaColors.textHigh)),
            centerTitle: false,
          ),
          body: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            itemCount: _shown.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: 18),
                  child: Text(
                    'Every number on your dashboard comes from something you '
                    'control. Here is what each one means and what moves it.',
                    style: TextStyle(color: BrokaColors.textMid,
                        fontSize: 12.5, height: 1.45),
                  ),
                );
              }
              final t = _shown[i - 1];
              return FadeSlideIn(
                index: i,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: BrokaColors.bgCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: t.accent.withOpacity(0.24)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Container(
                          width: 34, height: 34,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: t.accent.withOpacity(0.14)),
                          child: Icon(t.icon, size: 17, color: t.accent),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(t.title,
                              style: const TextStyle(
                                  color: BrokaColors.textHigh,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ]),
                      const SizedBox(height: 9),
                      Text(t.lede,
                          style: TextStyle(color: t.accent,
                              fontSize: 12.5, height: 1.35,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 11),
                      for (final para in t.body) ...[
                        Text(para,
                            style: const TextStyle(
                                color: BrokaColors.textMid,
                                fontSize: 12.5, height: 1.55)),
                        if (para != t.body.last) const SizedBox(height: 10),
                      ],
                      if (identical(t, _payingSafely))
                        TextButton.icon(
                          onPressed: () => showSafePaymentSheet(context,
                              repository: widget.repository),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('Escrow services and safety tips'),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
}
