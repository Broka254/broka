// BROKA — seller insights
//
// Fixed, hand-written cards. No model call.
//
// WHY THESE ARE NOT AI-GENERATED
// The previous version asked Zeno for "three sharp tips" on every refresh.
// It cost tokens on every tap and produced generic marketplace advice —
// price against a benchmark, get your first deal — because the model was
// never given the seller's objectives, their plans, or anything a business
// advisor would need. It assumed what the seller needed to know, and then
// charged for the assumption.
//
// These do a different job. Each one explains a lever the seller actually
// controls and connects it to a consequence the platform actually applies,
// so they stay true regardless of who is reading them. That is the thing
// generated advice could not guarantee.
//
// THEY ARE ALSO THE MONETISATION ARGUMENT
// BROKA earns when deals settle through escrow. So does the seller — higher
// DCR lifts their rank, their rank lifts their listings, and visible
// listings close faster. Every card below sits on that alignment, which is
// why none of them is a nag: "route this through BROKA" and "get more
// buyers" are the same instruction.
//
// Except while BROKA holds no payments (IN_APP_PAYMENTS_ENABLED off): then
// no deal can settle through escrow, and a card telling a seller to sell
// escrow has them promising buyers protection that doesn't exist - the
// promise a fraudster's "pay BROKA escrow at this number" borrows. The two
// payment cards say how to get paid safely instead.
//
// A real Zeno advisory conversation — one that knows the seller's goals and
// can be reasoned with — is a separate, deliberate feature. These cards do
// not pretend to be it.

import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;

class SellerInsight {
  final String title;
  final String body;
  final IconData icon;
  final Color accent;
  const SellerInsight(this.title, this.body, this.icon, this.accent);
}

/// Ordered loosely by how directly the seller controls the lever.
const List<SellerInsight> kSellerInsights = [
  SellerInsight(
    'Agree it in the chat',
    "BROKA doesn't hold payments for now, so the buyer pays you directly. "
    'Agree the price and the handover in the BROKA chat anyway: it is the '
    'record of what was promised if anything is disputed later. Check the '
    'money is in your M-Pesa before you hand anything over.',
    Icons.handshake_outlined, BrokaColors.neonGreen,
  ),
  SellerInsight(
    'Your completion rate decides your reach',
    'Rank is weighted heavily on completion rate, and rank decides whose '
    'listing a buyer sees first. Sellers who keep deals on the platform get '
    'shown more often — that placement is earned, and it is not for sale.',
    Icons.trending_up_rounded, BrokaColors.gold,
  ),
  SellerInsight(
    'The first hour is the whole game',
    'Most buyers message three or four sellers at once and buy from whoever '
    'answers first. Replying inside an hour is usually the difference '
    'between the deal and the runner-up.',
    Icons.bolt_rounded, BrokaColors.neonBlue,
  ),
  SellerInsight(
    'Reply speed is the fastest lever you have',
    'Completion rate takes weeks of closed deals to move. Response time '
    'moves this afternoon — it is the one part of your score you can change '
    'today.',
    Icons.speed_rounded, BrokaColors.neonCyan,
  ),
  SellerInsight(
    'Silence costs more than a slow reply',
    'A thread you never answer counts against you as heavily as a very late '
    'one. If you cannot help, say so — closing the conversation is better '
    'for your score than leaving it open.',
    Icons.mark_chat_unread_rounded, BrokaColors.danger,
  ),
  SellerInsight(
    'A save is a buyer telling you the price is close',
    'People who save a listing wanted it but did not buy. That gap is almost '
    'always price. Saves without offers is the clearest signal to adjust.',
    Icons.bookmark_rounded, BrokaColors.gold,
  ),
  SellerInsight(
    'Time on BROKA builds credibility, slowly',
    'Longevity counts toward your credibility score, but it cannot carry a '
    'poor completion rate. A careful six-month seller outranks a two-year '
    'one whose deals keep leaving the platform.',
    Icons.history_rounded, BrokaColors.neonBlue,
  ),
  SellerInsight(
    'Show it on video instead of meeting',
    'Buyers who want to see the item before paying do not have to travel to '
    'you. Start a video call from the chat and flip to the rear camera - '
    'they get the same look they came for, and the deal closes today '
    'instead of whenever you can both be in the same place.',
    Icons.videocam_rounded, BrokaColors.neonBlue,
  ),
  SellerInsight(
    'Make paying you feel safe',
    "Buyers hesitate most on payment, and BROKA doesn't hold payments for "
    'now. Offer to meet somewhere public, or let them check the item on '
    'delivery before they pay - and never ask for a deposit to hold it. '
    'Buyers are told that is a warning sign.',
    Icons.visibility_outlined, BrokaColors.neonGreen,
  ),
  SellerInsight(
    'Photos do the work your description cannot',
    'Clear, well-lit photos from several angles reduce the number of '
    '"can you send more pictures" messages — which shortens the thread and '
    'gets you to a decision faster.',
    Icons.photo_camera_rounded, BrokaColors.neonCyan,
  ),
  SellerInsight(
    'Price against what actually sold',
    'Your listing competes with the ones a buyer sees beside it. Check the '
    'live median for your category before you anchor to what you paid.',
    Icons.query_stats_rounded, BrokaColors.gold,
  ),
  SellerInsight(
    'A stale listing quietly stops being shown',
    'Freshness feeds into ranking. An item that has sat untouched for weeks '
    'slides down the feed — re-check the price and the photos rather than '
    'waiting it out.',
    Icons.update_rounded, BrokaColors.neonBlue,
  ),
  SellerInsight(
    'Your first completed deal is worth more than the next ten',
    'A seller with no record is an unknown quantity to every buyer. The '
    'first closed deal moves your credibility further than any single deal '
    'after it.',
    Icons.flag_rounded, BrokaColors.neonGreen,
  ),
  SellerInsight(
    'Repeat buyers count, and they count properly',
    'Someone coming back is loyalty, not a loophole — returning customers '
    'strengthen your record rather than diluting it.',
    Icons.repeat_rounded, BrokaColors.neonCyan,
  ),
  SellerInsight(
    'Let Zeno take the first message',
    'Zeno answers availability and basic questions while you are busy, so '
    'the buyer is not left waiting and your clock does not run.',
    Icons.smart_toy_rounded, BrokaColors.gold,
  ),
  SellerInsight(
    'Open deals hold your score down',
    'A deal that is neither completed nor cancelled sits against you. '
    'Closing it either way is better than leaving it open.',
    Icons.pending_actions_rounded, BrokaColors.danger,
  ),
  SellerInsight(
    'Share your store link, not just the listing',
    'Your store URL carries every item you have. One link on WhatsApp status '
    'or Instagram sends buyers to all of it instead of one product.',
    Icons.link_rounded, BrokaColors.neonBlue,
  ),
  SellerInsight(
    'Answer the question they asked',
    'Buyers who get a direct answer to a specific question convert far more '
    'often than ones who get a sales pitch back.',
    Icons.chat_bubble_rounded, BrokaColors.neonGreen,
  ),
  SellerInsight(
    'Meeting nearby closes faster',
    'Distance is a real obstacle to a deal. Buyers close to you are the ones '
    'most likely to say yes — keeping your location accurate puts you in '
    'front of them.',
    Icons.near_me_rounded, BrokaColors.neonCyan,
  ),
  SellerInsight(
    'Nobody can buy their way past you',
    'There is no paid placement on BROKA. Position comes from completion '
    'rate, reply speed and credibility — which means the seller ahead of you '
    'earned it, and so can you.',
    Icons.workspace_premium_rounded, BrokaColors.gold,
  ),
  SellerInsight(
    "Check your trend, not today's number",
    'One slow day is noise. The direction your lines are moving over a few '
    'weeks is the thing worth acting on.',
    Icons.show_chart_rounded, BrokaColors.neonBlue,
  ),
];
