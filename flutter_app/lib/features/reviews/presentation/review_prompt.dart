// "Deal complete - how was the seller?", asked right after the buyer
// confirms the goods and the money is released.
//
// Reviews only came from a buyer who went looking for the seller's profile
// and found the button. The push the backend sends on release
// (api/core/push_subscribers.py, "Deal Complete") was never routed to the
// review screen either (services/notification_service.dart). Asked at the
// moment the deal ends, while the buyer has the goods in hand.
import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../data/repositories/reviews_repository.dart';
import '../domain/models/review.dart';

/// Offers to review [dealId] if it is the buyer's completed, unreviewed
/// deal - the backend says, not this screen's guess about what just
/// happened. Does nothing otherwise (still in escrow, already reviewed, or
/// the call failed: the profile's "Write a review" is still there).
Future<void> promptReviewIfDue(BuildContext context, {
  required String dealId,
  String? sellerId,
}) async {
  final result = await reviewsRepository.myReviewableDeals(sellerId: sellerId);
  if (result is! Success<List<ReviewableDeal>> || !context.mounted) return;
  final deal = result.data.where((d) => d.dealId == dealId && !d.alreadyReviewed).firstOrNull;
  if (deal == null) return;

  final rate = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: BrokaColors.bgMid,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: Padding(
        key: const Key('review-prompt'),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.star_rounded, color: BrokaColors.gold, size: 40),
          const SizedBox(height: 10),
          const Text('Deal complete',
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('How was ${deal.sellerName}? Your review helps the next buyer '
              'of "${deal.listingName}" decide.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45)),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              key: const Key('review-prompt-rate'),
              onTap: () => Navigator.pop(ctx, true),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text('Rate ${deal.sellerName}', style: const TextStyle(
                    color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later', style: TextStyle(color: BrokaColors.textMid)),
          ),
        ]),
      ),
    ),
  );
  if (rate != true || !context.mounted) return;
  await Navigator.pushNamed(context, '/review', arguments: {
    'deal_id': deal.dealId,
    'seller_id': deal.sellerId,
    'seller_name': deal.sellerName,
    'listing_name': deal.listingName,
  });
}
