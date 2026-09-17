// BROKA — Store discovery (spec §12/§21, Phase 4)
// 1-column list, modeled directly on trader_list_screen.dart - same
// reasoning applies: ProductGridView is a fixed 2-column grid shared by
// four other screens, so a list layout for this one screen is a smaller,
// safer duplication than adding a layout mode to a shared component.
//
// No rating/completed-deals shown on a store card, unlike TraderCard -
// Store has no such field (spec §7/§19: never fabricate one), only a
// real listingCount.
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import 'store_media_image.dart';
import 'store_view_screen.dart';

class StoreListScreen extends StatefulWidget {
  const StoreListScreen({super.key});
  @override
  State<StoreListScreen> createState() => _StoreListScreenState();
}

class _StoreListScreenState extends State<StoreListScreen> {
  final List<Store> _stores = [];
  bool _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final query = _searchCtrl.text.trim();
    final result = await storesRepository.listStores(search: query.isEmpty ? null : query);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _stores..clear()..addAll(data);
        _loading = false;
      }),
      onFailure: (msg, __) => setState(() { _error = msg; _loading = false; }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
        title: const Text('Stores',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold)),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: TextField(
            controller: _searchCtrl,
            onSubmitted: (_) => _load(),
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search stores',
              hintStyle: const TextStyle(color: BrokaColors.textLow),
              prefixIcon: const Icon(Icons.search, color: BrokaColors.textLow, size: 20),
              filled: true,
              fillColor: BrokaColors.bgCard,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: BrokaColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: BrokaColors.border),
              ),
            ),
          ),
        ),
        Expanded(child: _buildBody()),
      ]),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_rounded, color: BrokaColors.textLow, size: 48),
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: BrokaColors.textMid)),
          const SizedBox(height: 8),
          TextButton(onPressed: _load, child: const Text('Retry', style: TextStyle(color: BrokaColors.gold))),
        ]),
      );
    }
    if (_stores.isEmpty) {
      return const Center(
        child: Text('No stores yet', style: TextStyle(color: BrokaColors.textMid)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _stores.length,
        itemBuilder: (_, i) => _StoreCard(
          store: _stores[i],
          onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const StoreViewScreen(),
              settings: RouteSettings(arguments: {'storeId': _stores[i].id}))),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }
}

class _StoreCard extends StatelessWidget {
  final Store store;
  final VoidCallback onTap;
  const _StoreCard({required this.store, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final initial = store.name.isNotEmpty ? store.name[0].toUpperCase() : '?';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: store.logoUrl != null
                ? StoreMediaImage(dataUri: store.logoUrl, width: 52, height: 52)
                : CircleAvatar(
                    radius: 26,
                    backgroundColor: BrokaColors.gold.withOpacity(0.15),
                    child: Text(initial, style: const TextStyle(
                        color: BrokaColors.gold, fontWeight: FontWeight.bold, fontSize: 20)),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 15)),
              if (store.specialization != null) ...[
                const SizedBox(height: 3),
                Text(store.specialization!, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.neonBlue, fontSize: 11.5, fontWeight: FontWeight.w600)),
              ],
              if (store.locationLine != null) ...[
                const SizedBox(height: 3),
                Row(children: [
                  const Icon(Icons.location_on_outlined, size: 12, color: BrokaColors.textLow),
                  const SizedBox(width: 2),
                  Flexible(child: Text(store.locationLine!, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textLow, fontSize: 11))),
                ]),
              ],
              const SizedBox(height: 4),
              Text('${store.listingCount} listing${store.listingCount == 1 ? '' : 's'}',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: BrokaColors.textLow),
        ]),
      ),
    );
  }
}
