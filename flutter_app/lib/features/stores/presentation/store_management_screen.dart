// BROKA — Store Management (spec §9/§10's "Store Mode", V1 scope)
//
// V1 deliberately does NOT include Deals/Negotiations/Reviews/Analytics
// tabs here (spec §10: "For V1 only implement what is actually supported
// by the current backend... Do NOT create fake analytics dashboards") -
// nothing on the backend yet scopes those to a Store rather than a
// seller, so a tab for them would either be empty or fabricated. What's
// here is only what's real: the store's own identity, its status, its
// catalog, and moving existing listings in.
//
// Hardening-pass fix: both listing sections below used to fetch a single
// hard-capped page (limit: 100 / limit: 50) with no way to see anything
// beyond that cap. Now paginated with an explicit "Load more" action, a
// loading state, an end-of-list state, and a retry-on-error state, using
// the same limit/offset the backend has always supported.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../widgets/gradient_button.dart';
import '../../../core/utils/result.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import 'create_store_screen.dart';
import 'store_media_image.dart';

const int _kPageSize = 20;

class StoreManagementScreen extends StatefulWidget {
  const StoreManagementScreen({super.key});
  @override
  State<StoreManagementScreen> createState() => _StoreManagementScreenState();
}

class _StoreManagementScreenState extends State<StoreManagementScreen> {
  Store? _store;
  bool _loading = true;
  bool _togglingStatus = false;

  // Store's own catalog - paginated.
  final List<BrokaListing> _storeListings = [];
  int _storeOffset = 0;
  bool _storeHasMore = true;
  bool _storeLoadingMore = false;
  String? _storeError;

  // Seller's own listings not yet in the store - paginated.
  final List<BrokaListing> _addableListings = [];
  int _addableOffset = 0;
  bool _addableHasMore = true;
  bool _addableLoadingMore = false;
  String? _addableError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await storesRepository.getMyStore();
    if (!mounted) return;
    result.fold(
      onSuccess: (store) => setState(() { _store = store; _loading = false; }),
      onFailure: (_, __) => setState(() => _loading = false),
    );
    if (_store != null) {
      setState(() {
        _storeListings.clear();  _storeOffset = 0;  _storeHasMore = true;  _storeError = null;
        _addableListings.clear(); _addableOffset = 0; _addableHasMore = true; _addableError = null;
      });
      await Future.wait([_loadMoreStoreListings(), _loadMoreAddableListings()]);
    }
  }

  Future<void> _loadMoreStoreListings() async {
    final store = _store;
    if (store == null || _storeLoadingMore || !_storeHasMore) return;
    setState(() { _storeLoadingMore = true; _storeError = null; });
    final result = await storesRepository.getStoreListings(store.id, limit: _kPageSize, offset: _storeOffset);
    if (!mounted) return;
    result.fold(
      onSuccess: (items) => setState(() {
        // Guard against a duplicate page landing twice (e.g. a fast
        // double-tap on "Load more") rather than trusting offset math alone.
        final existingIds = _storeListings.map((l) => l.id).toSet();
        _storeListings.addAll(items.where((l) => !existingIds.contains(l.id)));
        _storeOffset += items.length;
        _storeHasMore = items.length == _kPageSize;
        _storeLoadingMore = false;
      }),
      onFailure: (msg, __) => setState(() { _storeError = msg; _storeLoadingMore = false; }),
    );
  }

  Future<void> _loadMoreAddableListings() async {
    final myId = ApiService.currentUserId;
    if (myId == null || _addableLoadingMore || !_addableHasMore) return;
    setState(() { _addableLoadingMore = true; _addableError = null; });
    final result = await listingsRepository.getListings(
        sellerId: myId, limit: _kPageSize, offset: _addableOffset);
    if (!mounted) return;
    result.fold(
      onSuccess: (items) => setState(() {
        final withoutStore = items.where((l) => l.storeId == null);
        final existingIds = _addableListings.map((l) => l.id).toSet();
        _addableListings.addAll(withoutStore.where((l) => !existingIds.contains(l.id)));
        _addableOffset += items.length;
        // The backend filters by seller, not by "has no store" - a page
        // can come back with 20 items but 0 addable ones and still have
        // more pages after it, so "more exists" is about the raw page
        // size, not how many survived the client-side storeId==null filter.
        _addableHasMore = items.length == _kPageSize;
        _addableLoadingMore = false;
      }),
      onFailure: (msg, __) => setState(() { _addableError = msg; _addableLoadingMore = false; }),
    );
  }

  Future<void> _toggleStatus(bool active) async {
    final store = _store;
    if (store == null || _togglingStatus) return;
    setState(() => _togglingStatus = true);
    final result = await storesRepository.setStoreStatus(store.id, active);
    if (!mounted) return;
    result.fold(
      onSuccess: (updated) => setState(() { _store = updated; _togglingStatus = false; }),
      onFailure: (msg, __) {
        setState(() => _togglingStatus = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      },
    );
  }

  Future<void> _addToStore(BrokaListing listing) async {
    final store = _store;
    if (store == null) return;
    final result = await listingsRepository.setListingStore(listing.id, store.id);
    if (!mounted) return;
    result.fold(
      onSuccess: (_) {
        setState(() {
          _addableListings.removeWhere((l) => l.id == listing.id);
          _storeListings.insert(0, listing);
        });
      },
      onFailure: (msg, __) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg))),
    );
  }

  Future<void> _removeFromStore(BrokaListing listing) async {
    final result = await listingsRepository.removeListingStore(listing.id);
    if (!mounted) return;
    result.fold(
      onSuccess: (_) {
        setState(() {
          _storeListings.removeWhere((l) => l.id == listing.id);
          _addableListings.insert(0, listing);
        });
      },
      onFailure: (msg, __) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg))),
    );
  }

  void _copyLink(Store store) {
    Clipboard.setData(ClipboardData(text: 'https://broka.co.ke/store/${store.slug}'));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Store link copied')));
  }

  Future<void> _editStore(Store store) async {
    final updated = await Navigator.push<Store>(context,
        MaterialPageRoute(builder: (_) => CreateStoreScreen(existing: store)));
    if (updated != null && mounted) setState(() => _store = updated);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        title: const Text('My Store',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_store == null ? _noStoreState() : _managementView(_store!)),
      ),
    );
  }

  Widget _noStoreState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.storefront_outlined, size: 48, color: BrokaColors.textLow),
        const SizedBox(height: 16),
        const Text('You don\'t have a store yet',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Create one to group your listings under a single business identity.',
            textAlign: TextAlign.center,
            style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
        const SizedBox(height: 20),
        GradientButton(
          onPressed: () => Navigator.pushNamed(context, '/create-store').then((_) => _load()),
          child: const Text('Create Store',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        ),
      ]),
    ),
  );

  Widget _managementView(Store store) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: store.logoUrl != null
              ? StoreMediaImage(dataUri: store.logoUrl, width: 52, height: 52)
              : CircleAvatar(
                  radius: 26,
                  backgroundColor: BrokaColors.gold.withOpacity(0.15),
                  child: Text(store.name.isNotEmpty ? store.name[0].toUpperCase() : '?',
                      style: const TextStyle(color: BrokaColors.gold, fontSize: 20, fontWeight: FontWeight.w800)),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(store.name, style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800)),
            Text('${store.listingCount} listing${store.listingCount == 1 ? '' : 's'}',
                style: const TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          ]),
        ),
        Switch(
          value: store.isActive,
          onChanged: _togglingStatus ? null : _toggleStatus,
          activeColor: BrokaColors.gold,
        ),
      ]),
      const SizedBox(height: 4),
      Text(store.isActive
              ? 'Live - visible to buyers'
              : 'Paused - profile visible, catalog hidden from buyers',
          style: TextStyle(color: store.isActive ? const Color(0xFF4DD6A5) : BrokaColors.textLow, fontSize: 11.5)),
      const SizedBox(height: 16),

      Row(children: [
        Expanded(child: _actionButton(Icons.edit_outlined, 'Edit', () => _editStore(store))),
        const SizedBox(width: 8),
        Expanded(child: _actionButton(Icons.visibility_outlined, 'View Page',
            () => Navigator.pushNamed(context, '/store-view', arguments: {'storeId': store.id}))),
        const SizedBox(width: 8),
        Expanded(child: _actionButton(Icons.link, 'Copy Link', () => _copyLink(store))),
      ]),
      const SizedBox(height: 24),

      const Text('STORE LISTINGS', style: TextStyle(color: BrokaColors.textLow,
          fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      const SizedBox(height: 10),
      if (_storeListings.isEmpty && !_storeLoadingMore && _storeError == null)
        const Text('No listings in this store yet.', style: TextStyle(color: BrokaColors.textLow, fontSize: 12.5))
      else
        ..._storeListings.map((l) => _listingRow(l, isInStore: true)),
      _paginationFooter(
        hasMore: _storeHasMore,
        loadingMore: _storeLoadingMore,
        error: _storeError,
        hasAnyItems: _storeListings.isNotEmpty,
        onLoadMore: _loadMoreStoreListings,
      ),

      const SizedBox(height: 24),
      const Text('ADD AN EXISTING LISTING', style: TextStyle(color: BrokaColors.textLow,
          fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      const SizedBox(height: 10),
      if (_addableListings.isEmpty && !_addableLoadingMore && _addableError == null && !_addableHasMore)
        const Text('Every personal listing is already in this store.',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 12.5))
      else
        ..._addableListings.map((l) => _listingRow(l, isInStore: false)),
      _paginationFooter(
        hasMore: _addableHasMore,
        loadingMore: _addableLoadingMore,
        error: _addableError,
        hasAnyItems: _addableListings.isNotEmpty,
        onLoadMore: _loadMoreAddableListings,
      ),
    ]),
  );

  /// One shared footer for both paginated sections: a loading spinner
  /// while a page is in flight, a "Load more" tap target while more exist,
  /// a retry row on error, and nothing at all once the list is exhausted
  /// (no noisy "you've reached the end" banner for what's often a short list).
  Widget _paginationFooter({
    required bool hasMore,
    required bool loadingMore,
    required String? error,
    required bool hasAnyItems,
    required VoidCallback onLoadMore,
  }) {
    if (loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(child: SizedBox(
            width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold))),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Column(children: [
            Text('Couldn\'t load more: $error',
                style: const TextStyle(color: BrokaColors.danger, fontSize: 12), textAlign: TextAlign.center),
            TextButton(onPressed: onLoadMore,
                child: const Text('Retry', style: TextStyle(color: BrokaColors.gold))),
          ]),
        ),
      );
    }
    if (hasMore && hasAnyItems) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: TextButton(onPressed: onLoadMore,
              child: const Text('Load more', style: TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w600))),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onTap) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      side: const BorderSide(color: BrokaColors.border),
      padding: const EdgeInsets.symmetric(vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: BrokaColors.gold),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _listingRow(BrokaListing listing, {required bool isInStore}) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(listing.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w600)),
          Text(listing.priceFormatted, style: const TextStyle(color: BrokaColors.gold, fontSize: 12)),
        ]),
      ),
      TextButton(
        onPressed: () => isInStore ? _removeFromStore(listing) : _addToStore(listing),
        child: Text(isInStore ? 'Remove' : 'Add',
            style: TextStyle(color: isInStore ? BrokaColors.danger : BrokaColors.gold, fontWeight: FontWeight.w700)),
      ),
    ]),
  );
}
