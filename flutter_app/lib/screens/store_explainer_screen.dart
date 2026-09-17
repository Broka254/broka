// BROKA — the online store, explained
//
// The screen behind "See how it works".
//
// The recommendation card's job is to earn the tap; this is where the
// argument lives, because someone who opened it has already said they are
// interested. That is the only place a long pitch is fair.
//
// WHAT THE COPY IS DOING
// It leads with the problem, not the feature. Sellers here are not sitting
// around wishing for "an online store" — they are tired of posting the same
// stock one item at a time and watching a buyer who came for one thing
// leave without seeing the rest. The feature is the answer to that, so the
// answer goes second.
//
// It also does not pretend to be free-of-charge-but. It is free, every sale
// still runs through escrow, and the rating still applies. Saying so plainly
// removes the "what is the catch" reflex that any free upgrade triggers.
//
// A preview strip is stubbed at the bottom, ready for real screenshots.

import 'package:flutter/material.dart';

import '../main.dart';
import '../widgets/chat_ambient_background.dart';
import '../widgets/motion_widgets.dart';

class StoreExplainerScreen extends StatelessWidget {
  const StoreExplainerScreen({super.key});

  static const _reasons = [
    (
      Icons.link_rounded,
      'One link instead of twenty',
      'Right now every item you post is its own island. A store gives you a '
          'single address — broka.co.ke/store/yourname — that opens onto '
          'everything you sell. Put it in your WhatsApp status, your '
          'Instagram bio, or on the sign outside the shop.',
    ),
    (
      Icons.shopping_basket_rounded,
      'A customer who came for one thing sees the rest',
      'Someone searching for a charger finds your charger and leaves. '
          'Someone who lands on your store finds the charger, the cables, '
          'the phones and the cases. The same buyer, several times the '
          'basket — that is the whole difference between a sale and a '
          'customer.',
    ),
    (
      Icons.dashboard_customize_rounded,
      'Manage everything from one place',
      'Prices, photos, what is in stock and what is sold — all of it in one '
          'view instead of opening listings one at a time. If you are '
          'running more than a handful of items, this is the difference '
          'between a side hustle and a shop you can actually operate.',
    ),
    (
      Icons.storefront_rounded,
      'It looks like your business, not like a classified ad',
      'Your name, your items, your layout. Buyers who see a proper '
          'storefront treat you as a business rather than as one more '
          'stranger with something to sell — and that shows up in who is '
          'willing to pay first and ask questions later.',
    ),
    (
      Icons.shield_rounded,
      'Nothing about your protection changes',
      'Every sale still runs through BROKA escrow. Your completion rate, '
          'your rating and your ranking all work exactly as they do now. A '
          'store changes how buyers find you, not how you get paid.',
    ),
  ];

  @override
  Widget build(BuildContext context) => ChatAmbientBackground(
        intensity: 0.85,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: BrokaColors.bg.withOpacity(0.55),
            elevation: 0,
            scrolledUnderElevation: 0,
            title: const Text('YOUR ONLINE STORE',
                style: TextStyle(fontSize: 13, letterSpacing: 1.5,
                    fontWeight: FontWeight.w900, color: BrokaColors.textHigh)),
            centerTitle: false,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              FadeSlideIn(index: 0, child: _hero()),
              const SizedBox(height: 18),
              for (int i = 0; i < _reasons.length; i++)
                FadeSlideIn(index: i + 1, child: _reasonCard(_reasons[i])),
              const SizedBox(height: 6),
              FadeSlideIn(index: _reasons.length + 1, child: _previewStub()),
              const SizedBox(height: 18),
              FadeSlideIn(
                index: _reasons.length + 2,
                child: _cta(context),
              ),
              const SizedBox(height: 14),
              const Text(
                'Free. Takes a few minutes. You can change the name and '
                'layout afterwards.',
                textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textMid, fontSize: 11),
              ),
            ],
          ),
        ),
      );

  Widget _hero() => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            Color.alphaBlend(
                BrokaColors.gold.withOpacity(0.16), BrokaColors.bg),
            Color.alphaBlend(
                BrokaColors.neonBlue.withOpacity(0.08), BrokaColors.bg),
          ], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.34)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: BrokaColors.gold.withOpacity(0.16),
            ),
            child: const Icon(Icons.storefront_rounded,
                color: BrokaColors.gold, size: 24),
          ),
          const SizedBox(height: 14),
          const Text('Your whole shop,\nbehind one link.',
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 24,
                  fontWeight: FontWeight.w900, height: 1.22)),
          const SizedBox(height: 10),
          const Text(
            'Most people selling seriously here are not selling one thing — '
            'they are running a business out of a phone. A store gives that '
            'business an address.',
            style: TextStyle(color: BrokaColors.textMid,
                fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 14),
          // Showing the shape of the URL does more than describing it —
          // the seller can immediately picture their own name in it.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: BrokaColors.bg.withOpacity(0.6),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Row(children: [
              const Icon(Icons.lock_rounded, size: 12,
                  color: BrokaColors.neonGreen),
              const SizedBox(width: 7),
              const Text('broka.co.ke/store/',
                  style: TextStyle(color: BrokaColors.textMid,
                      fontSize: 12.5, fontFamily: 'monospace')),
              Text('yourname',
                  style: TextStyle(color: BrokaColors.gold,
                      fontSize: 12.5, fontFamily: 'monospace',
                      fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
      );

  Widget _reasonCard((IconData, String, String) r) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: BrokaColors.gold.withOpacity(0.13)),
              child: Icon(r.$1, size: 16, color: BrokaColors.gold),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(r.$2,
                style: const TextStyle(color: BrokaColors.textHigh,
                    fontSize: 13.5, fontWeight: FontWeight.w800, height: 1.25))),
          ]),
          const SizedBox(height: 9),
          Text(r.$3,
              style: const TextStyle(color: BrokaColors.textMid,
                  fontSize: 12.5, height: 1.5)),
        ]),
      );

  /// Placeholder for real store screenshots.
  ///
  /// Deliberately labelled rather than filled with a mock. A fabricated
  /// preview of a screen that does not look like that yet would be the same
  /// mistake as the invented statistics elsewhere — it sets an expectation
  /// the product then has to meet.
  Widget _previewStub() => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.6),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
              color: BrokaColors.border, style: BorderStyle.solid),
        ),
        child: Row(children: [
          const Icon(Icons.photo_library_outlined,
              size: 18, color: BrokaColors.textMid),
          const SizedBox(width: 11),
          const Expanded(child: Text(
            'Screenshots of a live store are coming here — so you can see '
            'exactly what buyers will see before you make one.',
            style: TextStyle(color: BrokaColors.textMid,
                fontSize: 11.5, height: 1.4),
          )),
        ]),
      );

  Widget _cta(BuildContext context) => PressableScale(
        onTap: () => Navigator.pushReplacementNamed(context, '/create-store'),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [BrokaColors.gold, BrokaColors.neonBlue]),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.storefront_rounded, color: Colors.white, size: 18),
              SizedBox(width: 9),
              Text('Create my store',
                  style: TextStyle(color: Colors.white, fontSize: 14.5,
                      fontWeight: FontWeight.w900)),
            ],
          ),
        ),
      );
}
