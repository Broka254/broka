// "Store details" - its own screen, opened from "More details" under the
// store's name or the info button in its bar. Everything a buyer arriving
// from a shared link needs to know about a store before buying from it,
// with the store's home left to its products:
//
//   summary    logo (when it has one), name, what and where, open or
//              taking a break
//   seller     who runs it, and their record in three numbers: deals
//              done, rating, and the year they joined BROKA (these were
//              chips crowding the store's header)
//   reviews    the owner's buyer reviews, their star breakdown and reply
//              time (a store has none of its own; these are the owner's,
//              fetched from /stores/{id}/reviews)
//   photos     the cover and shop photos
//   about      the owner's own description, in full
//   location   where the shop is, with a way to find it on a map
//   contact    the verified business email, and how to ask about a product
//   info       category, link, products, when it opened
//   safety     how to pay the store safely while BROKA holds no payments,
//              and the Paying safely sheet (escrow services BROKA doesn't run)
//
// The web storefront has the same page at /store/<name>/about, and that
// link opens this screen in the app.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../main.dart' show BrokaColors;
import '../../../../core/utils/result.dart';
import '../../../../models/seller_standing.dart';
import '../../../../widgets/broka_image.dart';
import '../../../../widgets/constellation_background.dart';
import '../../../../widgets/seller_standing_tiles.dart' show SellerStandingTiles;
import '../../../reviews/domain/models/review.dart';
import '../../../safe_payment/payments_shown.dart';
import '../../../safe_payment/safe_payment.dart';
import '../../data/repositories/stores_repository.dart';
import '../../domain/models/store.dart';
import '../../domain/models/store_reviews.dart';
import '../my_store_screen.dart' show StoreLogo;

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _monthYear(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// Opens [store]'s details on top of whatever is showing. With
/// [repository], the screen fetches the store's reviews; without one it
/// shows everything it already has and no reviews section.
/// [animateBackground] follows the screen it's opened from (tests draw
/// the constellation still).
Future<void> showStoreDetails(BuildContext context, Store store,
        {bool animateBackground = true, StoresRepository? repository}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'store-details'),
      builder: (_) => StoreDetailsScreen(store: store, animateBackground: animateBackground,
          repository: repository),
    ));

class StoreDetailsScreen extends StatefulWidget {
  const StoreDetailsScreen({
    super.key,
    required this.store,
    this.repository,
    this.openUrl,
    this.animateBackground = true,
  });

  final Store store;

  /// Where the buyer reviews come from. Null keeps the screen static -
  /// widget tests of the rest of the page don't answer a network call.
  final StoresRepository? repository;
  final Future<bool> Function(Uri uri)? openUrl;
  final bool animateBackground;

  @override
  State<StoreDetailsScreen> createState() => _StoreDetailsScreenState();
}

class _StoreDetailsScreenState extends State<StoreDetailsScreen> {
  StoreReviews? _reviews;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.repository != null) {
      _loading = true;
      _fetch();
    }
  }

  Future<void> _fetch() async {
    final result = await widget.repository!.getStoreReviews(widget.store.id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          _reviews = data;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: BrokaColors.textHigh,
        title: const Text('Store details', style: TextStyle(color: BrokaColors.textHigh,
            fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: ListView(
          key: const Key('store-details-list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            StoreDetailsView(
              store: widget.store,
              openUrl: widget.openUrl,
              reviews: _reviews,
              reviewsLoading: _loading,
              reviewsError: _error,
              onRetryReviews: _retry,
            ),
          ],
        ),
      ),
    );
  }
}

class StoreDetailsView extends StatelessWidget {
  const StoreDetailsView({
    super.key,
    required this.store,
    this.openUrl,
    this.reviews,
    this.reviewsLoading = false,
    this.reviewsError,
    this.onRetryReviews,
  });

  final Store store;

  /// Opens a mailto: or maps link. Defaults to the system handler; tests
  /// pass their own.
  final Future<bool> Function(Uri uri)? openUrl;

  /// The owner's buyer reviews. Null while they are on their way (or when
  /// the screen wasn't given a repository at all).
  final StoreReviews? reviews;
  final bool reviewsLoading;
  final String? reviewsError;

  /// Loads the reviews again after a failure.
  final VoidCallback? onRetryReviews;

  Future<void> _open(BuildContext context, Uri uri) async {
    final messenger = ScaffoldMessenger.of(context);
    var ok = false;
    try {
      ok = await (openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
    } catch (_) {}
    if (!ok) {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't open that on this phone")));
    }
  }

  Future<void> _copy(BuildContext context, String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what copied')));
  }

  @override
  Widget build(BuildContext context) {
    final description = store.description?.trim() ?? '';
    final photos = store.shopPhotos;
    final email = store.businessEmail != null && store.businessEmailVerified
        ? store.businessEmail!
        : null;
    final place = [store.locationDescription, store.subcounty, store.county, store.country]
        .map((s) => s?.trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    final opened = store.openedAt;

    return Column(key: const Key('store-details'),
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Summary(store: store),
      const SizedBox(height: 22),
      _label('The seller'),
      _OwnerCard(store: store),
      if (reviews != null || reviewsLoading || reviewsError != null) ...[
        const SizedBox(height: 22),
        _label('Buyer reviews'),
        _ReviewsSection(
          reviews: reviews,
          loading: reviewsLoading,
          error: reviewsError,
          onRetry: onRetryReviews,
        ),
      ],
      if (photos.isNotEmpty) ...[
        const SizedBox(height: 22),
        _label('Photos of the shop'),
        _PhotoStrip(photos: photos, storeName: store.name),
      ],
      if (description.isNotEmpty) ...[
        const SizedBox(height: 22),
        _label('About the store'),
        _card(child: Text(description, style: const TextStyle(
            color: BrokaColors.textHigh, fontSize: 14, height: 1.5))),
      ],
      const SizedBox(height: 22),
      _label('Location'),
      _card(
        key: const Key('store-location'),
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _InfoRow(
            icon: Icons.place_outlined,
            label: store.locationLine ?? store.country,
            value: (store.locationDescription?.trim().isNotEmpty ?? false)
                ? store.locationDescription!.trim()
                : null,
          ),
          if (place.length > 1)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('store-open-map'),
                onPressed: () => _open(context, Uri.https('www.google.com', '/maps/search/',
                    {'api': '1', 'query': place.join(', ')})),
                icon: const Icon(Icons.map_outlined, size: 18),
                label: const Text('Find it on the map'),
                style: TextButton.styleFrom(foregroundColor: _link),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 22),
      _label('Contact'),
      _card(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (email != null) ...[
            _InfoRow(
              key: const Key('store-email'),
              icon: Icons.alternate_email_rounded,
              label: 'Business email',
              value: email,
              trailing: IconButton(
                tooltip: 'Email the store',
                icon: const Icon(Icons.mail_outline_rounded, color: _link, size: 20),
                onPressed: () => _open(context, Uri(scheme: 'mailto', path: email)),
              ),
            ),
            const SizedBox(height: 10),
          ],
          const _InfoRow(
            icon: Icons.chat_bubble_outline_rounded,
            plainValue: true,
            label: 'Asking about a product',
            value: 'Open the product and tap Start Negotiation. Zeno, your personal assistant, '
                'takes your questions and offers to the seller.',
          ),
        ]),
      ),
      const SizedBox(height: 22),
      _label('Store info'),
      _card(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Column(children: [
          if (store.categories.isNotEmpty)
            _InfoRow(icon: Icons.category_outlined, label: 'Sells',
                value: store.categories.join(', '), dense: true),
          _InfoRow(
            key: const Key('store-details-link'),
            icon: Icons.link_rounded,
            label: 'Store link',
            value: store.displayUrl,
            dense: true,
            trailing: IconButton(
              tooltip: 'Copy link',
              icon: const Icon(Icons.copy_rounded, color: _link, size: 19),
              onPressed: () => _copy(context, store.url, 'Store link'),
            ),
          ),
          _InfoRow(
            icon: Icons.inventory_2_outlined,
            label: 'Products',
            value: '${store.listingCount} on sale',
            dense: true,
          ),
          if (opened != null)
            _InfoRow(icon: Icons.event_outlined, label: 'Opened',
                value: _monthYear(opened), dense: true),
        ]),
      ),
      const SizedBox(height: 22),
      _label('Buying safely'),
      Container(
        key: const Key('store-buying-safely'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: BrokaColors.success.withOpacity(0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.success.withOpacity(0.35)),
        ),
        // This said "Pay only through BROKA. Your money is held in escrow" -
        // untrue while BROKA holds no payments, and the very line a
        // fraudster quotes when asking for money "into BROKA escrow" at
        // their own number. The escrow services are in the Paying safely
        // sheet, beside the note that BROKA doesn't run them, and so is the
        // land and car advice: an M-Pesa escrow can't carry those amounts
        // (KES 250,000 a payment), and the official search is what proves
        // the seller owns it.
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.visibility_outlined, color: BrokaColors.success),
            const SizedBox(width: 12),
            Expanded(child: Text(
              paymentsShown
                  ? "BROKA doesn't hold payments for now. Buying from a distance? Pay through an "
                    "escrow service: it holds the money until you have the item. BROKA doesn't run "
                    'them, and Zeno walks you through it. Collecting? See the item first, then pay '
                    'the store. Never send a deposit to "hold" an item. Land or a car: see Pay with escrow.'
                  : "BROKA doesn't hold payments: you pay the store directly. Delivery or "
                    'pickup is agreed with the store. See the item first, then pay. Never send '
                    'a deposit to "hold" an item, and never pay a number claiming to be BROKA.',
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, height: 1.45),
            )),
          ]),
          if (paymentsShown)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('store-paying-safely'),
                onPressed: () => showSafePaymentSheet(context, openUrl: openUrl),
                icon: const Icon(Icons.shield_rounded, size: 17),
                label: const Text('Pay with escrow'),
              ),
            ),
        ]),
      ),
    ]);
  }
}

/// Which store this is, so the screen stands on its own when a link
/// opened it straight away.
class _Summary extends StatelessWidget {
  const _Summary({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    final place = [
      if (store.categories.isNotEmpty) store.categories.join(', '),
      store.locationLine,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final color = store.isActive ? BrokaColors.success : BrokaColors.warning;
    return _card(
      key: const Key('store-details-summary'),
      child: Row(children: [
        // The store's own logo, or BROKA's when it has none (StoreLogo).
        StoreLogo(store: store, size: 60),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(store.name, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18,
                  fontWeight: FontWeight.w800, height: 1.2)),
          if (place.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(place, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withOpacity(0.6)),
              ),
              child: Text(store.isActive ? 'Open' : 'Taking a break', style: TextStyle(
                  color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
            ),
            // The buyer's first question about a shop, in the one place a
            // buyer goes to judge it. Nothing at all when the distance is
            // unknown - a guess is worse than silence.
            if (store.anyDistanceLabel != null)
              Container(
                key: const Key('store-details-distance'),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: BrokaColors.gold.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: BrokaColors.gold.withOpacity(0.6)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.near_me_rounded, size: 12, color: BrokaColors.gold),
                  const SizedBox(width: 4),
                  Text(store.anyDistanceLabel!, style: const TextStyle(
                      color: BrokaColors.gold, fontSize: 11.5, fontWeight: FontWeight.w700)),
                ]),
              ),
          ]),
        ])),
      ]),
    );
  }
}

// Links on cards: BrokaColors.gold is under 4:1 on a card; this lighter
// violet reads at 7:1.
const _link = Color(0xFFB69CFF);

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(text.toUpperCase(), style: const TextStyle(color: BrokaColors.textMid,
          fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1)),
    );

Widget _card({Key? key, required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) =>
    Container(
      key: key,
      padding: padding,
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
      ),
      child: child,
    );

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.trailing,
    this.dense = false,
    this.plainValue = false,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Widget? trailing;

  /// A label beside its value on one line, for the short facts under
  /// "Store info"; otherwise the value sits under the label.
  final bool dense;

  /// A sentence rather than a fact: regular weight, not bold.
  final bool plainValue;

  @override
  Widget build(BuildContext context) {
    final valueStyle = TextStyle(color: BrokaColors.textHigh,
        fontSize: 14, fontWeight: plainValue ? FontWeight.w400 : FontWeight.w600, height: 1.4);
    const labelStyle = TextStyle(color: BrokaColors.textMid, fontSize: 12.5);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: dense ? 46 : 0),
      child: Row(crossAxisAlignment: dense ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
        Padding(
          padding: EdgeInsets.only(top: dense ? 0 : 1),
          child: Icon(icon, color: BrokaColors.textMid, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: dense
              ? Row(children: [
                  Text(label, style: labelStyle),
                  const SizedBox(width: 12),
                  Expanded(child: Text(value ?? '', textAlign: TextAlign.right,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: valueStyle)),
                  if (trailing == null) const SizedBox(width: 8),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: value == null ? valueStyle : labelStyle),
                  if (value != null) ...[
                    const SizedBox(height: 2),
                    Text(value!, style: valueStyle),
                  ],
                ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class _OwnerCard extends StatelessWidget {
  const _OwnerCard({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    final owner = store.owner;
    final name = owner?.name ?? 'The owner of ${store.name}';
    final verified = owner?.verified ?? false;
    final deals = owner?.completedDeals ?? 0;
    final since = owner?.memberSince;
    // A rating only means something once there are deals behind it.
    final rating = deals > 0 ? owner?.rating : null;

    return _card(
      key: const Key('store-owner'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 48, height: 48,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: BrokaColors.brandGradient),
            ),
            child: Text(name.characters.first.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 20,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Row(children: [
              Icon(verified ? Icons.verified_rounded : Icons.info_outline_rounded, size: 15,
                  color: verified ? BrokaColors.success : BrokaColors.textMid),
              const SizedBox(width: 5),
              Flexible(child: Text(verified ? 'Verified seller' : 'Not verified yet',
                  style: TextStyle(color: verified ? BrokaColors.success : BrokaColors.textMid,
                      fontSize: 12.5, fontWeight: FontWeight.w600))),
            ]),
          ])),
        ]),
        const SizedBox(height: 14),
        // The seller's record in three numbers, side by side, each with
        // what it counts under it.
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _fact(
            key: const Key('owner-deals'),
            icon: Icons.handshake_outlined,
            iconColor: _link,
            value: '$deals',
            label: deals == 1 ? 'Deal done' : 'Deals done',
          ),
          const SizedBox(width: 8),
          _fact(
            key: const Key('owner-rating'),
            icon: Icons.star_rounded,
            iconColor: const Color(0xFFFBBF24),
            value: rating != null ? rating.toStringAsFixed(1) : 'New',
            label: rating != null ? 'Rating' : 'No rating yet',
          ),
          const SizedBox(width: 8),
          _fact(
            key: const Key('owner-since'),
            icon: Icons.calendar_month_outlined,
            iconColor: _link,
            value: since != null ? '${since.year}' : '–',
            label: 'On BROKA since',
          ),
        ]),
      ]),
    );
  }

  Widget _fact({
    required Key key,
    required IconData icon,
    required Color iconColor,
    required String value,
    required String label,
  }) =>
      Expanded(
        child: Container(
          key: key,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          decoration: BoxDecoration(
            color: BrokaColors.bg.withOpacity(0.55),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Column(children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(height: 6),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label, maxLines: 2, textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.2)),
          ]),
        ),
      );
}

/// The owner's buyer reviews: the star summary, the reply time, and the
/// reviews themselves. A store has no reviews of its own - these are the
/// seller's, from /stores/{id}/reviews - and the empty state says how
/// reviews come to exist at all.
class _ReviewsSection extends StatelessWidget {
  const _ReviewsSection({
    this.reviews,
    required this.loading,
    this.error,
    this.onRetry,
  });

  final StoreReviews? reviews;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final data = reviews;
    if (data == null) {
      if (error != null) {
        return _card(
          key: const Key('store-reviews-error'),
          child: Row(children: [
            const Icon(Icons.cloud_off_rounded, color: BrokaColors.warning, size: 22),
            const SizedBox(width: 12),
            Expanded(child: Text(error!, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 13, height: 1.4))),
            if (onRetry != null)
              TextButton(
                key: const Key('store-reviews-retry'),
                onPressed: onRetry,
                style: TextButton.styleFrom(foregroundColor: _link),
                child: const Text('Retry'),
              ),
          ]),
        );
      }
      if (loading) {
        return _card(
          key: const Key('store-reviews-loading'),
          child: const Row(children: [
            SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: _link)),
            SizedBox(width: 12),
            Text('Loading buyer reviews...', style: TextStyle(
                color: BrokaColors.textMid, fontSize: 13)),
          ]),
        );
      }
      return const SizedBox.shrink();
    }

    final summary = data.summary;
    final reply = responseTimeLabel(data.sellerStanding?.responseMinutes);
    final band = data.sellerStanding?.responseBand ?? StandingBand.unknown;
    if (summary.count == 0) {
      return _card(
        key: const Key('store-reviews-empty'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.rate_review_outlined, color: BrokaColors.textMid, size: 22),
            SizedBox(width: 12),
            Expanded(child: Text('No reviews yet', style: TextStyle(
                color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 6),
          const Text("Reviews come from buyers after a completed deal. When you buy from this "
              'store, yours will help the next buyer.',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
          if (reply != null) ...[
            const SizedBox(height: 10),
            _replyLine(reply, band),
          ],
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _card(
        key: const Key('store-reviews-summary'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Column(children: [
              Text((summary.average ?? 0).toStringAsFixed(1), style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 34,
                  fontWeight: FontWeight.w900, height: 1.0)),
              const SizedBox(height: 4),
              _stars((summary.average ?? 0).round(), 13),
              const SizedBox(height: 3),
              Text(summary.count == 1 ? '1 review' : '${summary.count} reviews',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
            ]),
            const SizedBox(width: 18),
            Expanded(child: Column(children: [
              for (final star in const [5, 4, 3, 2, 1])
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(children: [
                    SizedBox(width: 10, child: Text('$star', style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 10))),
                    const Icon(Icons.star_rounded, color: BrokaColors.gold, size: 10),
                    const SizedBox(width: 6),
                    Expanded(child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: summary.countFor(star) / summary.count,
                        backgroundColor: BrokaColors.bgMid,
                        valueColor: AlwaysStoppedAnimation(
                            star >= 4 ? BrokaColors.neonGreen
                            : star == 3 ? BrokaColors.warning : BrokaColors.danger),
                        minHeight: 6,
                      ),
                    )),
                    const SizedBox(width: 6),
                    SizedBox(width: 20, child: Text('${summary.countFor(star)}',
                        textAlign: TextAlign.end,
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 10))),
                  ]),
                ),
            ])),
          ]),
          if (reply != null) ...[
            const SizedBox(height: 12),
            _replyLine(reply, band),
          ],
        ]),
      ),
      for (final review in data.reviews) _ReviewCard(review: review),
      if (summary.count > data.reviews.length)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
              'Showing ${data.reviews.length} of ${summary.count} reviews',
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        ),
    ]);
  }

  Widget _replyLine(String reply, StandingBand band) {
    final color = SellerStandingTiles.bandColor(band);
    return Row(key: const Key('store-response-time'), children: [
      Icon(Icons.schedule_rounded, size: 15, color: color),
      const SizedBox(width: 6),
      Flexible(child: Text(reply, style: TextStyle(
          color: color, fontSize: 12.5, fontWeight: FontWeight.w600))),
    ]);
  }

  static Widget _stars(int filled, double size) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(5, (i) => Icon(
            i < filled ? Icons.star_rounded : Icons.star_outline_rounded,
            color: BrokaColors.gold, size: size)),
      );
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.review});
  final SellerReview review;

  @override
  Widget build(BuildContext context) {
    final when = review.createdAt?.toLocal();
    final name = review.reviewerName;
    return Container(
      key: Key('store-review-${review.id}'),
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30, height: 30,
            decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: BrokaColors.brandGradient)),
            child: Center(child: Text(name.isEmpty ? 'B' : name[0].toUpperCase(),
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w800, fontSize: 12))),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh,
                    fontWeight: FontWeight.w700, fontSize: 12)),
            if (when != null)
              Text('${when.day}/${when.month}/${when.year}',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
          ])),
          _ReviewsSection._stars(review.rating, 13),
        ]),
        if (review.comment.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(review.comment, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 12, height: 1.45)),
        ],
      ]),
    );
  }
}

class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({required this.photos, required this.storeName});
  final List<({String thumb, String large})> photos;
  final String storeName;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 118,
      child: ListView.separated(
        key: const Key('store-photos'),
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) => Semantics(
          button: true,
          label: 'Photo ${i + 1} of ${photos.length} of $storeName',
          child: GestureDetector(
            key: Key('store-photo-$i'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: (_) => StorePhotoViewer(photos: photos, initial: i),
            )),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 160,
                child: BrokaImage(photos[i].thumb, fit: BoxFit.cover,
                    placeholder: Container(color: BrokaColors.bgCard)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shop's photos full screen: swipe between them, pinch to zoom.
class StorePhotoViewer extends StatefulWidget {
  const StorePhotoViewer({super.key, required this.photos, this.initial = 0});
  final List<({String thumb, String large})> photos;
  final int initial;

  @override
  State<StorePhotoViewer> createState() => _StorePhotoViewerState();
}

class _StorePhotoViewerState extends State<StorePhotoViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} of ${widget.photos.length}',
            style: const TextStyle(fontSize: 15)),
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.photos.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => InteractiveViewer(
          maxScale: 4,
          child: Center(child: BrokaImage(widget.photos[i].large, fit: BoxFit.contain)),
        ),
      ),
    );
  }
}
