// BROKA — all seller insights
//
// The full list, readable at the seller's own pace.
//
// The dashboard rail drifts so a passing glance meets something different
// each time. That is right for a glance and wrong for a seller who has
// actually decided to read them: waiting for a card to scroll into view, or
// swiping back because one went past, is a bad way to read twenty things.
// So the rail keeps the drift and hands off to this the moment someone
// signals real interest.
//
// No AI here either. These are the same fixed cards from
// data/seller_insights.dart.

import 'package:flutter/material.dart';

import '../data/seller_insights.dart';
import '../main.dart';
import '../widgets/chat_ambient_background.dart';
import '../widgets/motion_widgets.dart';
import '../widgets/zeno_avatar.dart';

class ZenoInsightsScreen extends StatelessWidget {
  const ZenoInsightsScreen({super.key});

  @override
  Widget build(BuildContext context) => ChatAmbientBackground(
        intensity: 0.85,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: BrokaColors.bg.withOpacity(0.55),
            elevation: 0,
            scrolledUnderElevation: 0,
            title: const Row(children: [
              ZenoAvatar(size: 26),
              SizedBox(width: 8),
              Text('ZENO INSIGHTS',
                  style: TextStyle(fontSize: 13, letterSpacing: 1.5,
                      fontWeight: FontWeight.w900,
                      color: BrokaColors.textHigh)),
            ]),
            centerTitle: false,
          ),
          body: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            itemCount: kSellerInsights.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'How BROKA actually decides what buyers see — and what '
                    'you can change today.',
                    style: TextStyle(color: BrokaColors.textMid,
                        fontSize: 12.5, height: 1.4),
                  ),
                );
              }
              final t = kSellerInsights[i - 1];
              return FadeSlideIn(
                index: i,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    // Opaque: the constellation belongs between the cards,
                    // not behind the text on them.
                    color: BrokaColors.bgCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: t.accent.withOpacity(0.26)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Container(
                          width: 30, height: 30,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: t.accent.withOpacity(0.14)),
                          child: Icon(t.icon, size: 16, color: t.accent),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(t.title,
                              style: const TextStyle(
                                  color: BrokaColors.textHigh,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ]),
                      const SizedBox(height: 9),
                      // No maxLines here, unlike the rail. The whole reason
                      // to open this screen is to read the part the card
                      // was cutting off.
                      Text(t.body,
                          style: const TextStyle(
                              color: BrokaColors.textMid,
                              fontSize: 12.5, height: 1.45)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
}
