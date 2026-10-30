// The free-offer banner and the time-left surfaces.
//
// One visual language, three jobs:
//  * sell the offer before it is taken (scarcity + what is free + one
//    per user, in plain words, with a real remaining count);
//  * confirm it once taken (free until a date, no payment due);
//  * warn before a listing/store goes offline, with the way to renew.
//
// Colour is meaning, not decoration: green = free/live, amber = ending,
// red = offline. No card claims urgency the server did not report.
import 'package:flutter/material.dart';

import '../../../main.dart';
import '../domain/launch_offers.dart';

enum LaunchOfferKind { listing, store }

/// "First 50 listings free" / "First 10 stores free" for this user.
class LaunchOfferBanner extends StatelessWidget {
  const LaunchOfferBanner({super.key, required this.offer, required this.kind});

  final LaunchOffer offer;
  final LaunchOfferKind kind;

  bool get _isListing => kind == LaunchOfferKind.listing;

  @override
  Widget build(BuildContext context) {
    if (!offer.shouldShow) return const SizedBox.shrink();
    final taken = offer.alreadyClaimed == true;
    final title = taken
        ? (_isListing ? 'Your free listing is claimed' : 'Your free store setup is claimed')
        : (_isListing
            ? 'Post your first listing free'
            : 'Open your online store free');
    final body = taken
        ? 'One launch offer per person — yours is already used. '
            'Renewals after the free period are paid as usual.'
        : '${offer.freeDays} days free, no M-Pesa prompt, no card. '
            'Only ${offer.remaining} of ${offer.limit} '
            '${_isListing ? 'free listings' : 'free stores'} left — one per person. '
            '${_isListing ? 'When it is gone, listing is paid.' : 'When they are gone, store setup is paid.'}';
    return Container(
      key: Key(taken
          ? 'launch-offer-claimed'
          : (_isListing ? 'launch-offer-listing' : 'launch-offer-store')),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.success.withOpacity(0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.success.withOpacity(0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.verified_outlined, color: BrokaColors.success, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
              ),
              if (!taken)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: BrokaColors.success.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${offer.remaining} left',
                      style: const TextStyle(
                          color: BrokaColors.success, fontSize: 11, fontWeight: FontWeight.w800)),
                ),
            ]),
            const SizedBox(height: 4),
            Text(body,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

/// A listing posted through a store never pays a listing fee.
class StoreCoveredBanner extends StatelessWidget {
  const StoreCoveredBanner({super.key, this.storeName});
  final String? storeName;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('store-covered-banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.success.withOpacity(0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.success.withOpacity(0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.storefront_rounded, color: BrokaColors.success, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('No listing fee for this one',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Listings in ${storeName ?? 'your store'} are covered by the store plan — '
              'no per-listing payment, and no free-listing slot is used.',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Small countdown chip for cards and rows. Renders nothing unless the
/// deadline is actually near (or already passed, on owner rows).
class TimeLeftChip extends StatelessWidget {
  const TimeLeftChip({super.key, required this.timeLeft, this.showWhenOffline = false});
  final TimeLeft? timeLeft;
  final bool showWhenOffline;

  @override
  Widget build(BuildContext context) {
    final t = timeLeft;
    if (t == null) return const SizedBox.shrink();
    if (!t.showOnCard && !(showWhenOffline && t.isOffline)) {
      return const SizedBox.shrink();
    }
    final color = t.isOffline
        ? BrokaColors.danger
        : (t.isExpiringSoon ? BrokaColors.warning : BrokaColors.success);
    return Container(
      key: const Key('time-left-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.58),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.6), width: 0.8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.schedule_rounded, size: 11, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(t.isOffline ? 'Offline' : 'Ends in ${t.label.replaceAll(' left', '')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

/// Owner-facing countdown: time left, the exact offline date, and the
/// renewal action when one is due. Quiet when there is no deadline.
class TimeLeftBanner extends StatelessWidget {
  const TimeLeftBanner({
    super.key,
    required this.timeLeft,
    required this.subject,
    this.onRenew,
    this.renewLabel = 'Renew',
  });

  final TimeLeft? timeLeft;

  /// "Your listing" / "Your store" — used in the offline/ending sentence.
  final String subject;
  final VoidCallback? onRenew;
  final String renewLabel;

  @override
  Widget build(BuildContext context) {
    final t = timeLeft;
    if (t == null || t.isUnlimited || t.isStoreCovered) {
      if (t?.isStoreCovered != true) return const SizedBox.shrink();
      return _box(
        color: BrokaColors.success,
        icon: Icons.storefront_rounded,
        title: 'Covered by your store plan',
        body: 'This listing stays live while your store plan is paid. '
            'Its deadline is your store\'s, shown on My Store.',
      );
    }
    if (!t.needsAttention && !t.isOffline) {
      // Live with time to spare: one calm line, no alarm.
      return _box(
        color: BrokaColors.success,
        icon: Icons.schedule_rounded,
        title: t.label,
        body: t.offlineDateLabel == null
            ? '$subject is live.'
            : '$subject goes offline ${t.offlineDateLabel}. We text you 2 days before.',
      );
    }
    final color = t.isOffline ? BrokaColors.danger : BrokaColors.warning;
    return _box(
      color: color,
      icon: t.isOffline ? Icons.visibility_off_rounded : Icons.schedule_rounded,
      title: t.isOffline ? '$subject is offline' : 'Ends in ${t.label.replaceAll(' left', '')}',
      body: t.isOffline
          ? 'Buyers can\'t see it until you renew. Renewing brings it straight back.'
          : '$subject goes offline ${t.offlineDateLabel ?? 'soon'}. '
              'We text you 2 days before — renew now and there is no gap.',
      action: onRenew == null
          ? null
          : TextButton(
              key: const Key('time-left-renew'),
              onPressed: onRenew,
              child: Text(renewLabel,
                  style: TextStyle(color: color, fontWeight: FontWeight.w800)),
            ),
    );
  }

  Widget _box({
    required Color color,
    required IconData icon,
    required String title,
    required String body,
    Widget? action,
  }) {
    return Container(
      key: const Key('time-left-banner'),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(body, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
          ]),
        ),
        if (action != null) action,
      ]),
    );
  }
}
