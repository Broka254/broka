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

/// Both launch offers on one card, with the way in. This is the card a
/// seller sees without starting anything: first on the Seller Dashboard's
/// Overview, again above the Products list. It is deliberately loud - a
/// claimed-so-far bar and big remaining counts per offer, turning amber
/// with an "Almost gone" pill at five or fewer left - because a new seller
/// must never scroll past it wondering where the free offer is.
/// Each offer keeps its own remaining count and state: a taken or exhausted
/// offer says so instead of offering a dead button, and five or fewer left
/// turns the card urgent (amber) instead of calm (green).
class LaunchOffersCard extends StatelessWidget {
  const LaunchOffersCard({
    super.key,
    required this.offers,
    this.onPostListing,
    this.onOpenStore,
    this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 4),
  });

  final LaunchOffers offers;
  final VoidCallback? onPostListing;
  final VoidCallback? onOpenStore;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final showListing = offers.listingFree.shouldShow;
    final showStore = offers.storeFree.shouldShow;
    if (!showListing && !showStore) return const SizedBox.shrink();
    final urgent = _isLow(offers.listingFree) || _isLow(offers.storeFree);
    final accent = urgent ? BrokaColors.warning : BrokaColors.success;
    return Container(
      key: const Key('launch-offers-card'),
      margin: margin,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.09),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withOpacity(urgent ? 0.7 : 0.5), width: urgent ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(urgent ? Icons.local_fire_department_rounded : Icons.celebration_rounded,
              color: accent, size: 22),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Launch offers — free to start',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
          ),
          if (urgent)
            Container(
              key: const Key('launch-offers-urgent-pill'),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: BrokaColors.warning.withOpacity(0.16),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: BrokaColors.warning.withOpacity(0.5)),
              ),
              child: const Text('Almost gone',
                  style: TextStyle(
                      color: BrokaColors.warning, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
        ]),
        const SizedBox(height: 4),
        const Text('BROKA is launching. The first listings and stores are free — one of each per person.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
        if (showListing) ...[
          const SizedBox(height: 14),
          _OfferRow(
            icon: Icons.sell_rounded,
            offer: offers.listingFree,
            title: offers.listingFree.alreadyClaimed == true
                ? 'Your free listing — claimed'
                : 'First ${offers.listingFree.limit} listings free',
            detail: offers.listingFree.alreadyClaimed == true
                ? 'You have used your one free listing. It stays live for its free period.'
                : '${offers.listingFree.freeDays} days free · ${offers.listingFree.remaining} of ${offers.listingFree.limit} left · one per person',
            scarcityUnit: 'posting',
            actionLabel: offers.listingFree.alreadyClaimed == true ? null : 'Post free',
            onAction: onPostListing,
            key: const Key('launch-offers-listing-row'),
          ),
        ],
        if (showStore) ...[
          const SizedBox(height: 12),
          _OfferRow(
            icon: Icons.storefront_rounded,
            offer: offers.storeFree,
            title: offers.storeFree.alreadyClaimed == true
                ? 'Your free store — claimed'
                : 'First ${offers.storeFree.limit} online stores free',
            detail: offers.storeFree.alreadyClaimed == true
                ? 'You have used your one free store setup.'
                : 'Free setup + ${offers.storeFree.freeDays} days · ${offers.storeFree.remaining} of ${offers.storeFree.limit} left · one per person · listings in a store never pay a listing fee',
            scarcityUnit: 'store setup',
            actionLabel: offers.storeFree.alreadyClaimed == true ? null : 'Open free',
            onAction: onOpenStore,
            key: const Key('launch-offers-store-row'),
          ),
        ],
      ]),
    );
  }
}

/// Five or fewer slots left and still claimable by someone: scarce enough
/// to say so loudly.
bool _isLow(LaunchOffer o) =>
    o.alreadyClaimed != true && o.remaining > 0 && o.remaining <= 5;

class _OfferRow extends StatelessWidget {
  const _OfferRow({
    super.key,
    required this.icon,
    required this.offer,
    required this.title,
    required this.detail,
    required this.scarcityUnit,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final LaunchOffer offer;
  final String title;
  final String detail;

  /// "posting" / "store setup": what turns paid once the slots run out.
  final String scarcityUnit;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final taken = offer.alreadyClaimed == true;
    final low = _isLow(offer);
    final last = !taken && offer.remaining == 1;
    final fraction = offer.limit <= 0
        ? 0.0
        : (offer.claimed / offer.limit).clamp(0.0, 1.0);
    final accent = low ? BrokaColors.warning : BrokaColors.success;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: accent, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style:
                    const TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(detail, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
          ]),
        ),
        if (actionLabel != null) ...[
          const SizedBox(width: 8),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              backgroundColor: accent.withOpacity(0.16),
              foregroundColor: accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(actionLabel!, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ]),
      if (!taken) ...[
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            key: Key('launch-offers-progress-${scarcityUnit == 'posting' ? 'listing' : 'store'}'),
            value: fraction,
            minHeight: 6,
            backgroundColor: BrokaColors.textHigh.withOpacity(0.10),
            valueColor: AlwaysStoppedAnimation<Color>(accent),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          last
              ? 'Last free slot — after this, $scarcityUnit is paid.'
              : low
                  ? 'Only ${offer.remaining} left — when they run out, $scarcityUnit is paid.'
                  : '${offer.claimed} of ${offer.limit} claimed',
          key: Key('launch-offers-scarcity-${scarcityUnit == 'posting' ? 'listing' : 'store'}'),
          style: TextStyle(
              color: low ? BrokaColors.warning : BrokaColors.textMid,
              fontSize: 11.5,
              fontWeight: low ? FontWeight.w800 : FontWeight.w600,
              height: 1.3),
        ),
      ],
    ]);
  }
}

/// One listing's time left, ALWAYS shown on owner surfaces — including
/// "No expiry", so a seller can tell a listing with no deadline from one
/// whose deadline simply was not rendered. [onRenew] appears only when
/// the deadline needs one (ending/offline and not store-covered).
class ListingTimeLeftRow extends StatelessWidget {
  const ListingTimeLeftRow({super.key, required this.timeLeft, this.onRenew});

  final TimeLeft? timeLeft;
  final VoidCallback? onRenew;

  @override
  Widget build(BuildContext context) {
    final t = timeLeft;
    final (icon, color, text) = switch (t) {
      null => (Icons.schedule_rounded, BrokaColors.textMid, 'Time left: not available'),
      TimeLeft(isStoreCovered: true) => (
          Icons.storefront_rounded,
          BrokaColors.success,
          'Live via your store plan — no listing fee, no own deadline',
        ),
      TimeLeft(isUnlimited: true) => (
          Icons.all_inclusive_rounded,
          BrokaColors.success,
          'No expiry — this listing stays live',
        ),
      TimeLeft(isOffline: true) => (
          Icons.visibility_off_rounded,
          BrokaColors.danger,
          'Offline${t!.offlineDateLabel != null ? ' since ${t.offlineDateLabel}' : ''} — buyers can\'t see it',
        ),
      TimeLeft(isExpiringSoon: true) => (
          Icons.schedule_rounded,
          BrokaColors.warning,
          '${t!.label} · goes offline ${t.offlineDateLabel ?? ''} · we text you 2 days before',
        ),
      _ => (
          Icons.schedule_rounded,
          BrokaColors.success,
          '${t!.label} · goes offline ${t.offlineDateLabel ?? ''}',
        ),
    };
    return Container(
      key: const Key('listing-time-left-row'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(text,
              style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700, height: 1.3)),
        ),
        if (onRenew != null && t != null && t.needsAttention && !t.isStoreCovered)
          TextButton(
            key: const Key('listing-time-left-renew'),
            onPressed: onRenew,
            child: const Text('Renew', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
      ]),
    );
  }
}

/// The offer's state in one line, for the exact spots where money is
/// asked: the Menu's store card, the store Review step, the store billing
/// screen. Unlike the banner, this also speaks when the offer is GONE —
/// a seller facing a paywall deserves to read "all 10 free stores were
/// claimed" instead of silently wondering where the free offer went.
/// Renders nothing only when the offer is not configured at all, or
/// when [offer] has not loaded.
class OfferStateLine extends StatelessWidget {
  const OfferStateLine({
    super.key,
    required this.offer,
    required this.kind,
    this.existingStore = false,
  });

  final LaunchOffer? offer;
  final LaunchOfferKind kind;

  /// On the billing screen of a store that already exists: a free slot
  /// still remaining platform-wide does not cover THIS store — claiming
  /// happens when the store is created, one per person.
  final bool existingStore;

  bool get _isListing => kind == LaunchOfferKind.listing;

  @override
  Widget build(BuildContext context) {
    final o = offer;
    if (o == null || o.limit <= 0) return const SizedBox.shrink();
    final (icon, color, text) = switch (o) {
      LaunchOffer(alreadyClaimed: true) => (
          Icons.verified_rounded,
          BrokaColors.success,
          _isListing
              ? 'Your free listing is claimed — no payment needed for it.'
              : 'Your free store setup is claimed — no payment needed.',
        ),
      LaunchOffer(hasSlots: true) when existingStore => (
          Icons.info_outline_rounded,
          BrokaColors.textMid,
          'The launch offer is claimed when a store is created — this store '
              'opened without one, so its plan is paid. (${o.remaining} free stores left.)',
        ),
      LaunchOffer(hasSlots: true) => (
          Icons.celebration_rounded,
          BrokaColors.success,
          _isListing
              ? 'First ${o.limit} listings free — only ${o.remaining} left. '
                  'Post now and yours is free for ${o.freeDays} days.'
              : 'First ${o.limit} online stores free — only ${o.remaining} left. '
                  'Open yours now and setup is free, with ${o.freeDays} days on BROKA.',
        ),
      _ => (
          Icons.info_outline_rounded,
          BrokaColors.warning,
          _isListing
              ? 'All ${o.limit} free listings have been claimed — the launch offer has ended.'
              : 'All ${o.limit} free stores have been claimed — the launch offer has ended.',
        ),
    };
    return Container(
      key: const Key('offer-state-line'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Text(text,
              style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w700, height: 1.35)),
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
