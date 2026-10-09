// BROKA — how it works
//
// The whole of BROKA on one screen: buying, selling, paying, Zeno, and what
// the numbers on a seller's dashboard mean (2026-10-08 rewrite).
//
// It used to be the seller's explainer only - DCR, rank, escrow - and the
// buyer, who is most of BROKA's users and the one deciding whether to send
// money to a stranger, had nothing. It opens with how a deal goes for each
// of them, then how to pay: BROKA holds no deal money for launch, so the
// way to pay someone you can't meet is an independent escrow service, and
// Zeno walks you through one (escrow_walkthrough.py on the server).
//
// Written plainly and without marketing. The claims here are mechanical -
// this is what the code does - so they have to stay true as the code
// changes. Nothing on this screen quotes a statistic, because the moment it
// does, someone has to keep it honest. It said there was "no featured
// placement and no paid badge"; boosts and the Verified badge are both
// paid for, so it says what each does instead.

import 'package:flutter/material.dart';

import '../features/safe_payment/escrow_callout.dart';
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

/// A deal from one side, as numbered steps.
class _Journey {
  final IconData icon;
  final Color accent;
  final String title;
  final List<(String, String)> steps;
  const _Journey(this.icon, this.accent, this.title, this.steps);
}

const _buying = _Journey(Icons.shopping_bag_rounded, BrokaColors.neonBlue, 'Buying on BROKA', [
  ('Find it', 'Browse a category, search, or tell Zeno\'s Buying Agent what you want - it '
      'searches, compares and keeps watching for you.'),
  ('Ask Zeno', 'Is the price fair? Is the seller reliable? What should you check? Tap "Ask '
      'Zeno" on any listing.'),
  ('Agree the deal', 'In the deal room Zeno negotiates beside you, or chat with the seller '
      'directly. A video call shows you the item without a trip.'),
  ('Pay with escrow', 'An independent escrow service holds your money until you have the item. '
      'Zeno walks you through it, step by step. Collecting in person? Check it, then pay.'),
  ('Confirm, then review', 'Release the money once it\'s what you agreed, and tell other '
      'buyers how the seller did.'),
]);

const _selling = _Journey(Icons.storefront_rounded, BrokaColors.gold, 'Selling on BROKA', [
  ('List it', 'Photos first - Zeno can write the listing from them. A fair price and a clear '
      'title get you found.'),
  ('Answer fast', 'Buyers rarely message one seller. Whoever answers first is usually who '
      'they buy from.'),
  ('Agree the deal', 'Zeno brokers the price with the buyer and keeps it civil.'),
  ('Get paid through escrow', 'Wait until the escrow service itself shows the buyer\'s money '
      'is held - never a screenshot or an SMS - then hand it over. The service pays you when '
      'the buyer confirms.'),
  ('Grow', 'An online store gathers your listings behind one link; verification shows buyers '
      'who you are.'),
]);

const _zeno = _Topic(
  Icons.auto_awesome_rounded, BrokaColors.neonPurple,
  'Zeno, on your side',
  'The AI broker in every deal - and the assistant in the Zeno tab.',
  [
    'In a deal room, Zeno negotiates between buyer and seller and keeps both honest: it never '
        'invents what the other side said, and never pushes a price past what the seller set.',
    'In the Zeno tab it answers questions, opens screens, searches, finds things for you, and '
        'walks you through paying with escrow one step at a time - which service, how to pay in, '
        'and when it is safe to release the money. Say "walk me through escrow" to start.',
    'It can list an item for you from its photo, and voice mode lets you just talk to it.',
  ],
);

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
    'Average response time',
    'How long buyers wait for you, on average, from their message to your reply.',
    [
      'The average of every wait across your conversations in the last 30 '
      'days. A thread left unanswered counts for at most two days, so one '
      'forgotten conversation can not define your month.',
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
    'Earned from your numbers - with one paid exception, always marked.',
    [
      'Your rank is computed from your completion rate, your response time '
      'and your credibility. That rank decides how high your listings sit '
      'when a buyer browses your category.',
      // It said "there is no featured placement, no promoted listing and no
      // paid badge" - while the app sold boosts and the Verified badge.
      'The one thing you can pay for is a boost: a boosted listing is put '
      'ahead of the others for the time you paid for, and it wears a '
      'FEATURED badge so buyers always know. The Verified badge is paid for '
      'too, but it is given only after an ID check, and it does not move '
      'you up the list.',
      'Everything else is earned: the seller ahead of you got there by '
      'closing deals here and answering quickly. So can you.',
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
// replaced by paying through an independent escrow service, and the
// completion rate says why it isn't moving.
const _payWithEscrow = _Topic(
  Icons.shield_rounded, BrokaColors.neonGreen,
  'Pay safely with escrow',
  "BROKA doesn't take payments itself yet. An independent escrow service does the holding.",
  [
    'With escrow, the buyer pays a neutral service, not the seller. The service holds the money '
        'and pays the seller only once the buyer confirms they got what they paid for. If something '
        'goes wrong, the service decides the dispute.',
    'Kenya has several: E-Confirm, Escrow Kenya, Kenya Escrow, Lipasafe and Shikilia. They are '
        "independent - BROKA doesn't run them and isn't paid by them - so check a service's fee "
        'before you pay. Zeno walks you through whichever you choose.',
    // The scam escrow invites: a "seller" who sends their own escrow link
    // runs the fake site it opens.
    'Open the service yourself, from BROKA\'s list. Never use an escrow link or number the other '
        'person sends you - fake escrow sites are a common scam.',
    // Land and cars apart: M-Pesa moves at most KES 250,000 a payment, and
    // the official search is what proves the seller owns it (the server's
    // advice, safe_payment.py).
    'Collecting in person? Meet somewhere public, check the item, then pay - never a deposit. Land '
        'and cars go through an official search (Ardhisasa, NTSA) and a bank or an advocate.',
  ],
);

const _completionWhilePaused = _Topic(
  Icons.verified_rounded, BrokaColors.gold,
  'Deal completion rate',
  'The share of your deals that actually finish on BROKA.',
  [
    'A deal counts as completed when its payment goes through BROKA and the buyer confirms. While '
        'BROKA takes no payments itself, no deal can complete through it - so the rate is not '
        'moving for anyone, and a deal paid through an escrow service or on collection is never '
        'counted against you.',
    'It is smoothed, and a new seller starts near the platform average rather than at zero.',
    'Once payments run through BROKA again it becomes the heaviest single input to your rating '
        'and ranking. Until then, reply speed is what you can move.',
  ],
);

class HowBrokaWorksScreen extends StatefulWidget {
  const HowBrokaWorksScreen({super.key, this.repository});

  final SafePaymentRepository? repository;

  @override
  State<HowBrokaWorksScreen> createState() => _HowBrokaWorksScreenState();
}

class _HowBrokaWorksScreenState extends State<HowBrokaWorksScreen> {
  /// Until the server says otherwise, BROKA is described as it runs for
  /// launch - holding no payments. Showing "BROKA holds the money" while
  /// the answer loads, or when it can't load, would be the one wrong thing
  /// this screen could say.
  bool _inAppPayments = false;

  @override
  void initState() {
    super.initState();
    (widget.repository ?? safePaymentRepository).fetch().then((info) {
      if (!mounted || info == null || !info.inAppPayments) return;
      setState(() => _inAppPayments = true);
    });
  }

  List<_Topic> get _shown => _inAppPayments
      ? _topics
      : [_payWithEscrow, _completionWhilePaused, ..._topics.skip(2)];

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final items = <Widget>[
      const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Text(
          'BROKA is where you buy and sell with Zeno, an AI broker, on your side. '
          'Here is how a deal goes, how to pay safely, and what the numbers on a '
          "seller's dashboard mean.",
          style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.45),
        ),
      ),
      const _JourneyCard(_buying),
      const _JourneyCard(_selling),
      if (!_inAppPayments)
        EscrowCallout(
          margin: const EdgeInsets.only(bottom: 14),
          onOpen: () => openEscrowServices(context, repository: widget.repository),
        ),
      for (final t in shown) ...[
        _TopicCard(t, repository: widget.repository),
        if (identical(t, shown.first)) const _TopicCard(_zeno),
      ],
    ];
    return ChatAmbientBackground(
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
          itemCount: items.length,
          itemBuilder: (_, i) => FadeSlideIn(index: i, child: items[i]),
        ),
      ),
    );
  }
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard(this.journey);
  final _Journey journey;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: journey.accent.withOpacity(0.3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(journey.icon, size: 20, color: journey.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(journey.title, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: 12),
          for (final (i, (title, detail)) in journey.steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 24, height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // Paying is the step people get wrong: it stands out.
                    color: (title.contains('escrow') ? BrokaColors.neonGreen : journey.accent).withOpacity(0.18),
                  ),
                  child: Text('${i + 1}', style: TextStyle(
                      color: title.contains('escrow') ? BrokaColors.neonGreen : journey.accent,
                      fontSize: 11.5, fontWeight: FontWeight.w900)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: TextStyle(
                        color: title.contains('escrow') ? BrokaColors.neonGreen : BrokaColors.textHigh,
                        fontSize: 13, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(detail, style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12.5, height: 1.45)),
                  ]),
                ),
              ]),
            ),
        ]),
      );
}

class _TopicCard extends StatelessWidget {
  const _TopicCard(this.t, {this.repository});
  final _Topic t;
  final SafePaymentRepository? repository;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.accent.withOpacity(identical(t, _payWithEscrow) ? 0.6 : 0.24),
              width: identical(t, _payWithEscrow) ? 1.4 : 1),
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
            if (identical(t, _payWithEscrow)) ...[
              const SizedBox(height: 12),
              ZenoGuideButton(onTap: () => openZenoEscrowGuide(context)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => showSafePaymentSheet(context, repository: repository),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Escrow services and safety tips'),
                ),
              ),
            ],
            if (identical(t, _zeno)) ...[
              const SizedBox(height: 12),
              ZenoGuideButton(
                label: 'Walk me through paying with escrow',
                onTap: () => openZenoEscrowGuide(context),
              ),
            ],
          ],
        ),
      );
}
