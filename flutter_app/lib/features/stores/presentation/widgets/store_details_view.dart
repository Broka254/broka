// "Store details" - everything a buyer arriving from a shared link needs to
// know about a store before buying from it, in one place:
//
//   photos     the cover and shop photos (the store's home no longer puts
//              the cover behind its name, where it fought with the text)
//   about      the owner's own description, in full
//   owner      who runs it, and their real seller record
//   location   where the shop is, with a way to find it on a map
//   contact    the verified business email, and how to ask about a product
//   info       category, link, when it opened, whether it's open
//   safety     how paying through BROKA protects the buyer
//
// Shown on the store's home (StoreHomeScreen's "Store details" tab), which
// the owner also sees through "View as a buyer".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../main.dart' show BrokaColors;
import '../../../../widgets/broka_image.dart';
import '../../domain/models/store.dart';

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _monthYear(DateTime d) => '${_months[d.month - 1]} ${d.year}';

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
      if (photos.isNotEmpty) ...[
        _label('Photos of the shop'),
        _PhotoStrip(photos: photos, storeName: store.name),
        const SizedBox(height: 22),
      ],
      if (description.isNotEmpty) ...[
        _label('About the store'),
        _card(child: Text(description, style: const TextStyle(
            color: BrokaColors.textHigh, fontSize: 14, height: 1.5))),
        const SizedBox(height: 22),
      ],
      _label('Store owner'),
      _OwnerCard(store: store),
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
          _InfoRow(
            icon: store.isActive ? Icons.storefront_rounded : Icons.pause_circle_outline_rounded,
            label: 'Status',
            value: store.isActive ? 'Open' : 'Taking a break',
            valueColor: store.isActive ? BrokaColors.success : BrokaColors.warning,
            dense: true,
          ),
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
        child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.shield_outlined, color: BrokaColors.success),
          SizedBox(width: 12),
          Expanded(child: Text(
            'Pay only through BROKA. Your money is held in escrow, and the seller '
            'is paid once you confirm you have the item. Never send money to a '
            'seller directly.',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 13, height: 1.45),
          )),
        ]),
      ),
    ]);
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
    this.valueColor,
    this.trailing,
    this.dense = false,
    this.plainValue = false,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Color? valueColor;
  final Widget? trailing;

  /// A label beside its value on one line, for the short facts under
  /// "Store info"; otherwise the value sits under the label.
  final bool dense;

  /// A sentence rather than a fact: regular weight, not bold.
  final bool plainValue;

  @override
  Widget build(BuildContext context) {
    final valueStyle = TextStyle(color: valueColor ?? BrokaColors.textHigh,
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
            width: 52, height: 52,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: BrokaColors.brandGradient),
            ),
            child: Text(name.characters.first.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 22,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Row(children: [
              Icon(verified ? Icons.verified_rounded : Icons.info_outline_rounded, size: 15,
                  color: verified ? BrokaColors.success : BrokaColors.textMid),
              const SizedBox(width: 5),
              Flexible(child: Text(verified ? 'Verified seller' : 'Not verified yet',
                  style: TextStyle(color: verified ? BrokaColors.success : BrokaColors.textMid,
                      fontSize: 12.5, fontWeight: FontWeight.w600))),
            ]),
            if (since != null) ...[
              const SizedBox(height: 2),
              Text('On BROKA since ${_monthYear(since)}',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
            ],
          ])),
        ]),
        const SizedBox(height: 14),
        Container(height: 1, color: BrokaColors.border),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(children: [
            _fact('$deals', deals == 1 ? 'deal done' : 'deals done'),
            const VerticalDivider(color: BrokaColors.border, width: 1),
            _fact(rating != null ? rating.toStringAsFixed(1) : 'New', 'rating',
                icon: rating != null ? Icons.star_rounded : null),
            const VerticalDivider(color: BrokaColors.border, width: 1),
            _fact('${store.listingCount}', store.listingCount == 1 ? 'product' : 'products'),
          ]),
        ),
      ]),
    );
  }

  Widget _fact(String value, String label, {IconData? icon}) => Expanded(
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[
              Icon(icon, size: 17, color: const Color(0xFFFBBF24)),
              const SizedBox(width: 3),
            ],
            Flexible(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                    fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        ]),
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
