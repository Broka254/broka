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
import '../../../../widgets/broka_image.dart';
import '../../../../widgets/constellation_background.dart';
import '../../../safe_payment/safe_payment.dart';
import '../../domain/models/store.dart';
import '../my_store_screen.dart' show StoreLogo;

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _monthYear(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// Opens [store]'s details on top of whatever is showing.
/// [animateBackground] follows the screen it's opened from (tests draw
/// the constellation still).
Future<void> showStoreDetails(BuildContext context, Store store,
        {bool animateBackground = true}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'store-details'),
      builder: (_) => StoreDetailsScreen(store: store, animateBackground: animateBackground),
    ));

class StoreDetailsScreen extends StatelessWidget {
  const StoreDetailsScreen({
    super.key,
    required this.store,
    this.openUrl,
    this.animateBackground = true,
  });

  final Store store;
  final Future<bool> Function(Uri uri)? openUrl;
  final bool animateBackground;

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
        animate: animateBackground,
        child: ListView(
          key: const Key('store-details-list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [StoreDetailsView(store: store, openUrl: openUrl)],
        ),
      ),
    );
  }
}

class StoreDetailsView extends StatelessWidget {
  const StoreDetailsView({super.key, required this.store, this.openUrl});

  final Store store;

  /// Opens a mailto: or maps link. Defaults to the system handler; tests
  /// pass their own.
  final Future<bool> Function(Uri uri)? openUrl;

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
            value: 'Open the product and tap Start Negotiation. Zeno, BROKA\'s broker, '
                'takes your questions and offers to the seller.',
          ),
        ]),
      ),
      const SizedBox(height: 22),
      _label('Store info'),
      _card(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Column(children: [
          if (store.category != null)
            _InfoRow(icon: Icons.category_outlined, label: 'Sells', value: store.category!,
                dense: true),
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
          const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.visibility_outlined, color: BrokaColors.success),
            SizedBox(width: 12),
            Expanded(child: Text(
              "BROKA doesn't hold payments for now: you pay the store directly, by "
              'M-Pesa. See the item before you pay - meet somewhere public or take '
              'delivery, and check it first. Never send a deposit to "hold" an item. '
              'For a deal at a distance, an independent escrow service can hold the '
              "money; BROKA doesn't run them. Land or a car: see Paying safely.",
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 13, height: 1.45),
            )),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('store-paying-safely'),
              onPressed: () => showSafePaymentSheet(context, openUrl: openUrl),
              child: const Text('Paying safely'),
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
    final place = [store.category, store.locationLine]
        .whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final color = store.isActive ? BrokaColors.success : BrokaColors.warning;
    return _card(
      key: const Key('store-details-summary'),
      child: Row(children: [
        // The store's own logo when it has one; no placeholder square
        // standing in for it.
        if (store.logoSource != null) ...[
          StoreLogo(store: store, size: 60),
          const SizedBox(width: 14),
        ],
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
