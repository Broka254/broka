// BROKA — Store View (spec §7/§9/§13's "View Store")
//
// Reads storeId from route arguments: Navigator.pushNamed(context,
// '/store-view', arguments: {'storeId': id}). Works for both "someone
// else's store" and "my own store" - the Manage button only appears once
// getMyStore() confirms the viewer is the owner, so this one screen
// serves as both the public view and the owner's own preview of it.
//
// The catalog reuses ProductGridView (spec: "do not duplicate listings"
// applies to the UI layer too, not just the backend) - listing taps go
// through Navigator arguments: {'listingId': id}, NOT the BrokaListing
// object directly, matching home_screen.dart's exact pattern (ProductScreen
// only recognizes the older Listing model or a listingId map - passing a
// BrokaListing object straight through silently fails to load).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../main.dart';
import '../../../widgets/product_grid_view.dart';
import '../../../core/utils/result.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import 'store_media_image.dart';

class StoreViewScreen extends StatefulWidget {
  const StoreViewScreen({super.key});
  @override
  State<StoreViewScreen> createState() => _StoreViewScreenState();
}

class _StoreViewScreenState extends State<StoreViewScreen> {
  Store? _store;
  bool _loading = true;
  bool _isOwner = false;
  String? _error;
  String? _storeId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_storeId == null) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map && args['storeId'] is String) {
        _storeId = args['storeId'] as String;
        _load();
      } else {
        setState(() { _loading = false; _error = 'Store not specified.'; });
      }
    }
  }

  Future<void> _load() async {
    final id = _storeId;
    if (id == null) return;
    setState(() { _loading = true; _error = null; });

    final result = await storesRepository.getStore(id);
    if (!mounted) return;
    result.fold(
      onSuccess: (store) => setState(() { _store = store; _loading = false; }),
      onFailure: (msg, __) => setState(() { _error = msg; _loading = false; }),
    );

    // Best-effort ownership check - a failed lookup just means no Manage
    // button shows, never blocks the public view itself.
    final mine = await storesRepository.getMyStore();
    if (!mounted) return;
    mine.fold(
      onSuccess: (myStore) => setState(() => _isOwner = myStore?.id == id),
      onFailure: (_, __) {},
    );
  }

  void _copyLink(Store store) {
    // The lightweight public SSR page (spec §14, Phase 5) isn't built yet
    // - this URL becomes live the moment that ships, no app update needed.
    Clipboard.setData(ClipboardData(text: 'https://broka.co.ke/store/${store.slug}'));
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Store link copied')));
  }

  Future<void> _launch(String uri) async {
    final parsed = Uri.parse(uri);
    if (await canLaunchUrl(parsed)) {
      await launchUrl(parsed, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        title: Text(store?.name ?? 'Store',
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
        actions: [
          if (store != null)
            IconButton(
              icon: const Icon(Icons.share_outlined, color: BrokaColors.textHigh),
              onPressed: () => _copyLink(store),
            ),
          if (_isOwner)
            TextButton(
              onPressed: () => Navigator.pushNamed(context, '/store-manage'),
              child: const Text('Manage', style: TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w700)),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_error != null || store == null)
                ? Center(child: Text(_error ?? 'Store not found',
                    style: const TextStyle(color: BrokaColors.textMid)))
                : Column(children: [
                    _header(store),
                    Expanded(
                      child: ProductGridView(
                        fetchPage: (page) => storesRepository
                            .getStoreListings(store.id, limit: 20, offset: page * 20)
                            .then((r) => r.fold(onSuccess: (items) => items, onFailure: (_, __) => <BrokaListing>[])),
                        onTapItem: (item) => Navigator.pushNamed(context, '/product',
                            arguments: {'listingId': (item as BrokaListing).id}),
                        emptyStateBuilder: (_) => const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text('Nothing listed here yet.',
                                style: TextStyle(color: BrokaColors.textLow)),
                          ),
                        ),
                      ),
                    ),
                  ]),
      ),
    );
  }

  Widget _header(Store store) {
    final initial = store.name.isNotEmpty ? store.name[0].toUpperCase() : '?';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: BrokaColors.border)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: store.logoUrl != null
                ? StoreMediaImage(dataUri: store.logoUrl, width: 56, height: 56)
                : CircleAvatar(
                    radius: 28,
                    backgroundColor: BrokaColors.gold.withOpacity(0.15),
                    child: Text(initial, style: const TextStyle(
                        color: BrokaColors.gold, fontSize: 22, fontWeight: FontWeight.w800)),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800))),
                if (!store.isActive) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: BrokaColors.textLow.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('Paused', style: TextStyle(color: BrokaColors.textLow, fontSize: 10)),
                  ),
                ],
              ]),
              if (store.specialization != null || store.locationLine != null)
                Text([store.specialization, store.locationLine]
                        .where((s) => s != null && s.isNotEmpty).join(' · '),
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
              Text('${store.listingCount} listing${store.listingCount == 1 ? '' : 's'}',
                  style: const TextStyle(color: BrokaColors.textLow, fontSize: 11.5)),
            ]),
          ),
        ]),
        if (store.description != null && store.description!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(store.description!, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
        ],
        if (store.photos.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: store.photos.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => StoreMediaImage(
                dataUri: store.photos[i], width: 72, height: 72,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
        if (store.officialPhone != null || store.officialWhatsapp != null || store.officialEmail != null) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (store.officialPhone != null)
              _contactChip(Icons.call_outlined, 'Call', () => _launch('tel:${store.officialPhone}')),
            if (store.officialWhatsapp != null)
              _contactChip(Icons.chat_outlined, 'WhatsApp', () => _launch('https://wa.me/${store.officialWhatsapp}')),
            if (store.officialEmail != null)
              _contactChip(Icons.email_outlined, 'Email', () => _launch('mailto:${store.officialEmail}')),
          ]),
        ],
      ]),
    );
  }

  Widget _contactChip(IconData icon, String label, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: BrokaColors.gold),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    ),
  );
}
