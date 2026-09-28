// My Store - the owner's dashboard.
//
//   Overview  open/paused switch, what needs the owner (products hidden
//             until their fee is paid, products in a deal), what's left
//             to set up, the link with QR and share buttons, and the last
//             7 days of visits (and where they came from)
//   Products  every product in the store, whatever its state (live,
//             hidden, in a deal, sold), with search and a filter per
//             state; each one can be paid for, repriced, shared, checked
//             on, or taken out. New products go straight into the store,
//             existing listings can be moved in
//   Settings  every part of the store, edited with the setup wizard's own
//             pages; the link is shown but fixed
//
// Only real numbers are shown: visits and shares are counted by the
// backend (api/domains/stores/stats.py). Orders and revenue appear once
// checkout exists - not before, and never as placeholders.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../../../models/listing.dart' as listing_model show Listing;
import '../../../screens/sell_photos_screen.dart';
import '../../../services/api_service.dart';
import '../../../widgets/broka_image.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/gradient_button.dart';
import '../../../widgets/wizard_scaffold.dart';
import '../../categories/domain/category_visual.dart';
import '../../listing_fee/presentation/listing_fee_screen.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/stores_repository.dart';
import '../data/store_share.dart';
import '../domain/models/store.dart';
import '../domain/models/store_product.dart';
import 'setup/store_setup_controller.dart';
import 'store_edit_screen.dart';
import 'widgets/store_share_card.dart';

class MyStoreScreen extends StatefulWidget {
  const MyStoreScreen({
    super.key,
    this.repository,
    this.listings,
    this.share,
    this.animateBackground = true,
  });

  final StoresRepository? repository;
  final ListingsRepository? listings;
  final StoreShare? share;
  final bool animateBackground;

  @override
  State<MyStoreScreen> createState() => _MyStoreScreenState();
}

class _MyStoreScreenState extends State<MyStoreScreen> {
  StoresRepository get _repo => widget.repository ?? storesRepository;

  Store? _store;
  bool _loading = true;
  String? _error;
  bool _hasDraft = false;

  /// Which products the Products tab shows (null: all). Kept here so the
  /// Overview can open the tab on, say, the hidden ones.
  final _productFilter = ValueNotifier<StoreProductState?>(null);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _productFilter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final result = await _repo.getMyStore();
    final hasDraft = await StoreSetupController.hasDraft();
    if (!mounted) return;
    switch (result) {
      case Success(:final data):
        setState(() { _store = data; _hasDraft = hasDraft; _loading = false; });
      case Failure(:final message):
        setState(() { _error = message; _loading = false; });
    }
  }

  void _replaceStore(Store store) => setState(() => _store = store);

  /// The store again after a change made inside the dashboard, without
  /// the full-screen spinner. Reloading with _load replaced the whole
  /// dashboard, so taking a product out of the store dropped the owner
  /// back on the Overview tab.
  Future<void> _refreshStore() async {
    final result = await _repo.getMyStore();
    if (!mounted) return;
    if (result case Success(:final data?)) _replaceStore(data);
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
    } else if (_error != null) {
      body = _Message(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't load your store",
        body: _error!,
        action: 'Try again',
        onAction: _load,
      );
    } else if (store == null) {
      body = _NoStore(hasDraft: _hasDraft, onDone: _load);
    } else {
      body = _Dashboard(
        store: store,
        repo: _repo,
        listings: widget.listings ?? listingsRepository,
        share: widget.share,
        productFilter: _productFilter,
        onStoreChanged: _replaceStore,
        onRefresh: _refreshStore,
      );
    }
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: body,
      ),
    );
  }
}

// ── No store yet ─────────────────────────────────────────────────────────────

class _NoStore extends StatelessWidget {
  const _NoStore({required this.hasDraft, required this.onDone});
  final bool hasDraft;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 0, 0),
            child: IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back_rounded, color: BrokaColors.textMid),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(28, 24, 28, 28), children: [
            Center(
              child: Container(
                width: 88, height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(colors: kWizardCtaGradient),
                  boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.4),
                      blurRadius: 30, spreadRadius: 1)],
                ),
                child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 44),
              ),
            ),
            const SizedBox(height: 22),
            const Text('Your own online store', textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 26,
                    fontWeight: FontWeight.w800, letterSpacing: -0.4)),
            const SizedBox(height: 10),
            const Text(
              'All your products in one place, with a link you can share on '
              'WhatsApp, TikTok and Instagram. Buyers browse your store, and every '
              'product still shows on BROKA\'s home screen.',
              textAlign: TextAlign.center,
              style: TextStyle(color: BrokaColors.textMid, fontSize: 14.5, height: 1.5),
            ),
            const SizedBox(height: 28),
            GradientButton(
              key: const Key('open-store-setup'),
              height: 56,
              borderRadius: 16,
              colors: kWizardCtaGradient,
              onPressed: () async {
                await Navigator.of(context).pushNamed('/store-setup');
                onDone();
              },
              child: Text(hasDraft ? 'Continue setting up' : 'Set up my store',
                  style: const TextStyle(color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 10),
            const Text('Takes about 3 minutes', textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
  });
  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: BrokaColors.textMid, size: 40),
              const SizedBox(height: 12),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(body, textAlign: TextAlign.center,
                  style: const TextStyle(color: BrokaColors.textMid)),
              if (action != null) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: onAction,
                  style: FilledButton.styleFrom(backgroundColor: BrokaColors.gold),
                  child: Text(action!),
                ),
              ],
            ]),
          ),
        ),
      );
}

// ── Dashboard ────────────────────────────────────────────────────────────────

/// Opens one part of the store in the setup wizard's own page, and passes
/// the saved store on.
Future<void> _editStore(BuildContext context, Store store, StoreSetupStep step,
    ValueChanged<Store> onStoreChanged) async {
  final updated = await Navigator.of(context).push<Store>(MaterialPageRoute(
      builder: (_) => StoreEditScreen(store: store, step: step)));
  if (updated != null) onStoreChanged(updated);
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({
    required this.store,
    required this.repo,
    required this.listings,
    required this.share,
    required this.productFilter,
    required this.onStoreChanged,
    required this.onRefresh,
  });

  final Store store;
  final StoresRepository repo;
  final ListingsRepository listings;
  final StoreShare? share;
  final ValueNotifier<StoreProductState?> productFilter;
  final ValueChanged<Store> onStoreChanged;

  /// Fetches the store again, quietly.
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          // With _tabList's injector, keeps each tab's content below the
          // pinned bar and tabs. Without it the top of every tab (Add
          // product, the search) slid under them once the header collapsed.
          SliverOverlapAbsorber(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            sliver: SliverAppBar(
              pinned: true,
              expandedHeight: 230,
              backgroundColor: BrokaColors.bg.withOpacity(0.92),
              iconTheme: const IconThemeData(color: Colors.white),
              title: Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontWeight: FontWeight.w800, fontSize: 17)),
              actions: [
                IconButton(
                  tooltip: 'View as a buyer',
                  icon: const Icon(Icons.visibility_outlined),
                  onPressed: () => Navigator.of(context).pushNamed('/store-view',
                      arguments: {'storeId': store.id}),
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                collapseMode: CollapseMode.parallax,
                background: _Header(store: store),
              ),
              bottom: const TabBar(
                indicatorColor: BrokaColors.gold,
                labelColor: BrokaColors.textHigh,
                unselectedLabelColor: BrokaColors.textMid,
                labelStyle: TextStyle(fontWeight: FontWeight.w700),
                tabs: [Tab(text: 'Overview'), Tab(text: 'Products'), Tab(text: 'Settings')],
              ),
            ),
          ),
        ],
        body: TabBarView(children: [
          _OverviewTab(store: store, repo: repo, share: share, productFilter: productFilter,
              onStoreChanged: onStoreChanged, onRefresh: onRefresh),
          _ProductsTab(store: store, repo: repo, listings: listings, share: share,
              filter: productFilter, onProductsChanged: onRefresh),
          _SettingsTab(store: store, onStoreChanged: onStoreChanged),
        ]),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    final cover = store.coverSource;
    return Stack(fit: StackFit.expand, children: [
      if (cover != null)
        BrokaImage(cover, fit: BoxFit.cover)
      else
        DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: CategoryVisuals.gradientFor(store.category)
              .map((c) => c.withOpacity(0.55)).toList(),
        ))),
      const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0x66000000), Color(0x00000000), Color(0xE603040A)],
        stops: [0, 0.4, 1],
      ))),
      Positioned(
        left: 16, right: 16, bottom: 58,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          StoreLogo(store: store, size: 60),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 20,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Row(children: [
              _StatusPill(active: store.isActive),
              const SizedBox(width: 8),
              Flexible(child: Text(
                  '${store.listingCount} product${store.listingCount == 1 ? '' : 's'}'
                  '${store.category != null ? ' · ${store.category}' : ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFD7D2EA), fontSize: 12.5))),
            ]),
          ])),
        ]),
      ),
    ]);
  }
}

/// A store's logo, or its initial on the brand gradient.
class StoreLogo extends StatelessWidget {
  const StoreLogo({super.key, required this.store, this.size = 48});
  final Store store;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.28);
    final source = store.logoSource;
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: Colors.white.withOpacity(0.85), width: 2),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 10)],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: source != null
            ? BrokaImage(source, fit: BoxFit.cover)
            : Container(
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: kWizardCtaGradient)),
                child: Text(store.name.isEmpty ? '?' : store.name.characters.first.toUpperCase(),
                    style: TextStyle(color: Colors.white, fontSize: size * 0.42,
                        fontWeight: FontWeight.w800)),
              ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? BrokaColors.success : BrokaColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Text(active ? 'Open' : 'Paused', style: TextStyle(color: color, fontSize: 11,
          fontWeight: FontWeight.w700)),
    );
  }
}

/// A tab's scrolling content, starting below the dashboard's pinned header
/// (see the SliverOverlapAbsorber in _Dashboard).
Widget _tabList(BuildContext context, {Key? key, required List<Widget> children}) =>
    CustomScrollView(key: key, slivers: [
      SliverOverlapInjector(handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context)),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        sliver: SliverList(delegate: SliverChildListDelegate(children)),
      ),
    ]);

Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) => Container(
      padding: padding,
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
      ),
      child: child,
    );

Widget _sectionLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(text.toUpperCase(), style: const TextStyle(color: BrokaColors.textMid,
          fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1)),
    );

// ── Overview ─────────────────────────────────────────────────────────────────

class _OverviewTab extends StatefulWidget {
  const _OverviewTab({
    required this.store,
    required this.repo,
    required this.share,
    required this.productFilter,
    required this.onStoreChanged,
    required this.onRefresh,
  });

  final Store store;
  final StoresRepository repo;
  final StoreShare? share;

  /// Set before switching to the Products tab, to open it on one state.
  final ValueNotifier<StoreProductState?> productFilter;
  final ValueChanged<Store> onStoreChanged;
  final Future<void> Function() onRefresh;

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  StoreStats? _stats;
  String? _statsError;
  bool _toggling = false;

  /// How many products are in each state. Null until loaded (or if that
  /// failed): the cards that need it just don't show.
  StoreProductCounts? _counts;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadCounts();
  }

  @override
  void didUpdateWidget(_OverviewTab old) {
    super.didUpdateWidget(old);
    // A new store object means something changed - a product added, paid
    // for or taken out, or the store edited.
    if (!identical(old.store, widget.store)) _loadCounts();
  }

  Future<void> _loadCounts() async {
    final result = await widget.repo.getOwnerProducts(widget.store.id, limit: 1);
    if (!mounted) return;
    if (result case Success(:final data)) setState(() => _counts = data.counts);
  }

  void _showProducts(StoreProductState state) {
    widget.productFilter.value = state;
    DefaultTabController.of(context).animateTo(1);
  }

  Future<void> _addProduct() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SellPhotosScreen(presetStoreId: widget.store.id)));
    if (mounted) await widget.onRefresh();
  }

  Future<void> _loadStats() async {
    final result = await widget.repo.getStats(widget.store.id);
    if (!mounted) return;
    setState(() {
      switch (result) {
        case Success(:final data):
          _stats = data;
          _statsError = null;
        case Failure(:final message):
          _statsError = message;
      }
    });
  }

  Future<void> _setActive(bool active) async {
    if (!active) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          backgroundColor: BrokaColors.bgMid,
          title: const Text('Pause your store?', style: TextStyle(color: BrokaColors.textHigh)),
          content: const Text(
              'Your link keeps working, but buyers will see that the store is paused '
              'and no products. Your products stay on BROKA\'s home screen.',
              style: TextStyle(color: BrokaColors.textMid)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(d, true),
                child: const Text('Pause', style: TextStyle(color: BrokaColors.warning))),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _toggling = true);
    final result = await widget.repo.setStoreStatus(widget.store.id, active);
    if (!mounted) return;
    setState(() => _toggling = false);
    switch (result) {
      case Success(:final data):
        widget.onStoreChanged(data);
      case Failure(:final message):
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final counts = _counts;
    return RefreshIndicator(
      color: BrokaColors.gold,
      onRefresh: () async {
        await Future.wait([_loadStats(), _loadCounts(), widget.onRefresh()]);
      },
      child: _tabList(context, key: const Key('overview-list'), children: [
        _card(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(children: [
            Icon(store.isActive ? Icons.storefront_rounded : Icons.pause_circle_outline_rounded,
                color: store.isActive ? BrokaColors.success : BrokaColors.warning),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(store.isActive ? 'Your store is open' : 'Your store is paused',
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontWeight: FontWeight.w700, fontSize: 15)),
              Text(store.isActive
                  ? 'Buyers can browse it from your link'
                  : 'Buyers see it, but no products',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
            ])),
            _toggling
                ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold)))
                : Switch(
                    key: const Key('store-open-switch'),
                    value: store.isActive,
                    activeColor: BrokaColors.success,
                    onChanged: _setActive,
                  ),
          ]),
        ),
        if (counts != null && (counts.hidden > 0 || counts.inDeal > 0)) ...[
          const SizedBox(height: 14),
          _NeedsAttention(counts: counts, onShow: _showProducts),
        ],
        _SetupChecklist(
          store: store,
          productCount: counts?.all ?? store.listingCount,
          onEdit: (step) => _editStore(context, store, step, widget.onStoreChanged),
          onAddProduct: _addProduct,
        ),
        const SizedBox(height: 14),
        StoreShareCard(store: store, share: widget.share),
        const SizedBox(height: 22),
        _sectionLabel('Last 7 days'),
        _StatsCard(stats: _stats, error: _statsError, onRetry: _loadStats),
        const SizedBox(height: 22),
        _sectionLabel('Quick actions'),
        Row(children: [
          Expanded(child: _QuickAction(
            icon: Icons.add_box_outlined,
            label: 'Add a product',
            onTap: _addProduct,
          )),
          const SizedBox(width: 12),
          Expanded(child: _QuickAction(
            icon: Icons.drive_file_move_outline,
            label: 'Move listings in',
            onTap: () async {
              final moved = await showAddExistingListings(context, store);
              if (moved > 0) await widget.onRefresh();
            },
          )),
        ]),
      ]),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
            ),
            child: Column(children: [
              Icon(icon, color: BrokaColors.gold, size: 26),
              const SizedBox(height: 8),
              Text(label, textAlign: TextAlign.center, style: const TextStyle(
                  color: BrokaColors.textHigh, fontWeight: FontWeight.w600, fontSize: 13)),
            ]),
          ),
        ),
      );
}

/// Products that need the owner: hidden until their fee is paid, and in a
/// deal. Each row opens the Products tab on those products.
class _NeedsAttention extends StatelessWidget {
  const _NeedsAttention({required this.counts, required this.onShow});
  final StoreProductCounts counts;
  final ValueChanged<StoreProductState> onShow;

  @override
  Widget build(BuildContext context) {
    String products(int n) => '$n product${n == 1 ? '' : 's'}';
    final rows = [
      if (counts.hidden > 0)
        (
          state: StoreProductState.hidden,
          icon: Icons.visibility_off_rounded,
          title: '${products(counts.hidden)} hidden from buyers',
          body: counts.hidden == 1
              ? 'Its listing fee is unpaid or ran out. Pay to show it again.'
              : 'Their listing fee is unpaid or ran out. Pay to show them again.',
        ),
      if (counts.inDeal > 0)
        (
          state: StoreProductState.inDeal,
          icon: Icons.handshake_outlined,
          title: '${products(counts.inDeal)} in a deal',
          body: 'Off your store until the deal is done.',
        ),
    ];
    return _card(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionLabel('Needs your attention'),
        for (final r in rows)
          InkWell(
            key: Key('attention-${r.state.value}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => onShow(r.state),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Icon(r.icon, color: _stateColor(r.state)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.title, style: const TextStyle(color: BrokaColors.textHigh,
                      fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(r.body, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
                ])),
                const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// What's left to make the store look finished, each a tap away from the
/// page that does it. Gone once everything is done.
class _SetupChecklist extends StatelessWidget {
  const _SetupChecklist({
    required this.store,
    required this.productCount,
    required this.onEdit,
    required this.onAddProduct,
  });

  final Store store;
  final int productCount;
  final ValueChanged<StoreSetupStep> onEdit;
  final VoidCallback onAddProduct;

  static const minProducts = 3;

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        key: 'logo',
        done: store.logoSource != null,
        title: 'Add your logo',
        hint: 'It sits at the top of your store and on every link you share',
        onTap: () => onEdit(StoreSetupStep.logo),
      ),
      (
        key: 'cover',
        done: store.coverSource != null,
        title: 'Add a cover photo',
        hint: 'A wide photo across the top of your store',
        onTap: () => onEdit(StoreSetupStep.photos),
      ),
      (
        key: 'about',
        done: (store.description ?? '').trim().isNotEmpty,
        title: 'Say what you sell',
        hint: "A line or two under your store's name",
        onTap: () => onEdit(StoreSetupStep.category),
      ),
      (
        key: 'products',
        done: productCount >= minProducts,
        title: 'Add at least $minProducts products',
        hint: productCount == 0
            ? 'So buyers have something to browse'
            : '$productCount so far',
        onTap: onAddProduct,
      ),
      (
        key: 'email',
        done: store.businessEmail != null && store.businessEmailVerified,
        title: 'Add a business email',
        hint: 'Where order updates will go',
        onTap: () => onEdit(StoreSetupStep.email),
      ),
    ];
    final done = items.where((i) => i.done).length;
    if (done == items.length) return const SizedBox.shrink();

    return Padding(
      key: const Key('setup-checklist'),
      padding: const EdgeInsets.only(top: 14),
      child: _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Expanded(child: Text('Finish setting up your store', style: TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 15))),
          const SizedBox(width: 8),
          Text('$done of ${items.length} done', style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: done / items.length,
            minHeight: 6,
            backgroundColor: BrokaColors.border,
            valueColor: const AlwaysStoppedAnimation(BrokaColors.success),
          ),
        ),
        const SizedBox(height: 6),
        // Only what's left: the bar above says how much is done.
        for (final i in items.where((i) => !i.done))
          InkWell(
            key: Key('checklist-${i.key}'),
            borderRadius: BorderRadius.circular(12),
            onTap: i.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                const Icon(Icons.radio_button_unchecked_rounded,
                    color: BrokaColors.textMid, size: 22),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(i.title, style: const TextStyle(color: BrokaColors.textHigh,
                      fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(i.hint, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                ])),
                const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid),
              ]),
            ),
          ),
      ])),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats, required this.error, required this.onRetry});
  final StoreStats? stats;
  final String? error;
  final VoidCallback onRetry;

  static const _sourceLabels = {
    'whatsapp': 'WhatsApp',
    'tiktok': 'TikTok',
    'instagram': 'Instagram',
    'facebook': 'Facebook',
    'x': 'X',
    'qr': 'QR code',
    'direct': 'Direct / typed',
    'other': 'Other',
  };

  static const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final s = stats;
    if (s == null) {
      return _card(child: SizedBox(
        height: 120,
        child: Center(child: error == null
            ? const CircularProgressIndicator(color: BrokaColors.gold)
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Text(error!, textAlign: TextAlign.center,
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
              ])),
      ));
    }
    final maxDay = s.visitsByDay.fold<int>(0, (m, d) => d.count > m ? d.count : m);
    final sources = s.visitsBySource.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('${s.visits}', key: const Key('visits-total'), style: const TextStyle(
            color: BrokaColors.textHigh, fontSize: 30, fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text('visitor${s.visits == 1 ? '' : 's'}',
              style: const TextStyle(color: BrokaColors.textMid)),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text('${s.shares} share${s.shares == 1 ? '' : 's'}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
        ),
      ]),
      const SizedBox(height: 14),
      SizedBox(
        // Count label + tallest bar (55) + weekday label, with room for
        // larger system text.
        height: 104,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final d in s.visitsByDay)
            Expanded(child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (d.count > 0)
                  Text('${d.count}', style: const TextStyle(color: BrokaColors.textMid,
                      fontSize: 10)),
                const SizedBox(height: 2),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  height: maxDay == 0 ? 3 : 3 + 52 * d.count / maxDay,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    gradient: const LinearGradient(colors: kWizardCtaGradient,
                        begin: Alignment.bottomCenter, end: Alignment.topCenter),
                  ),
                ),
                const SizedBox(height: 4),
                Text(_weekdays[d.date.weekday - 1], style: const TextStyle(
                    color: BrokaColors.textLow, fontSize: 10.5)),
              ]),
            )),
        ]),
      ),
      const SizedBox(height: 14),
      if (sources.isEmpty)
        const Text('No visitors yet. Share your link on WhatsApp or your socials to '
            'bring in your first customers.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4))
      else ...[
        const Text('Where visitors came from', style: TextStyle(color: BrokaColors.textMid,
            fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        for (final e in sources.take(5))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              SizedBox(width: 110, child: Text(_sourceLabels[e.key] ?? e.key,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5))),
              Expanded(child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: s.visits == 0 ? 0 : e.value / s.visits,
                  minHeight: 6,
                  backgroundColor: BrokaColors.border,
                  valueColor: const AlwaysStoppedAnimation(BrokaColors.gold),
                ),
              )),
              SizedBox(width: 36, child: Text('${e.value}', textAlign: TextAlign.right,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12))),
            ]),
          ),
      ],
    ]));
  }
}

// ── Products ─────────────────────────────────────────────────────────────────

/// A product's state, in the colour it's shown in.
Color _stateColor(StoreProductState state) => switch (state) {
      StoreProductState.live => BrokaColors.success,
      StoreProductState.hidden => BrokaColors.warning,
      StoreProductState.inDeal => BrokaColors.neonBlue,
      StoreProductState.sold => BrokaColors.textMid,
    };

// BrokaColors.gold is under 4:1 on a card; this lighter violet reads at 7:1
// (the web storefront's price colour).
const _priceColor = Color(0xFFB69CFF);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _shortDate(DateTime utc) {
  final d = utc.toLocal();
  return '${d.day} ${_months[d.month - 1]}';
}

enum _ProductAction { pay, price, share, insights, view, remove }

class _ProductsTab extends StatefulWidget {
  const _ProductsTab({
    required this.store,
    required this.repo,
    required this.listings,
    required this.share,
    required this.filter,
    required this.onProductsChanged,
  });
  final Store store;
  final StoresRepository repo;
  final ListingsRepository listings;
  final StoreShare? share;

  /// The state shown (null: all). The filter chips set it, and so does the
  /// Overview's "needs your attention" card.
  final ValueNotifier<StoreProductState?> filter;

  /// A product was added, paid for, moved in or taken out.
  final Future<void> Function() onProductsChanged;

  @override
  State<_ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends State<_ProductsTab> {
  static const _pageSize = 20;
  final List<StoreProduct> _items = [];
  StoreProductCounts? _counts;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  String _search = '';
  Timer? _searchDebounce;
  final _searchCtrl = TextEditingController();

  // Bumped whenever the filter or the search changes, so a page that
  // arrives for the old one is dropped instead of mixed into the new list.
  int _generation = 0;

  StoreProductState? get _state => widget.filter.value;

  @override
  void initState() {
    super.initState();
    widget.filter.addListener(_reload);
    _loadMore();
  }

  @override
  void didUpdateWidget(_ProductsTab old) {
    super.didUpdateWidget(old);
    if (old.filter != widget.filter) {
      old.filter.removeListener(_reload);
      widget.filter.addListener(_reload);
    }
  }

  @override
  void dispose() {
    widget.filter.removeListener(_reload);
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    _generation++;
    setState(() {
      _items.clear();
      _hasMore = true;
      _loading = false;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final generation = _generation;
    setState(() { _loading = true; _error = null; });
    // Every product in the store, whatever its state. The public catalogue
    // (GET /listings?store_id=) showed only live ones, so a product left
    // the owner's list the moment it went into a deal, sold, or waited for
    // its listing fee.
    final result = await widget.repo.getOwnerProducts(widget.store.id,
        state: _state, search: _search, limit: _pageSize, offset: _items.length);
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          final seen = _items.map((p) => p.id).toSet();
          _items.addAll(data.items.where((p) => !seen.contains(p.id)));
          _hasMore = data.items.length == _pageSize;
          _counts = data.counts;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () => _setSearch(value));
  }

  void _setSearch(String value) {
    _searchDebounce?.cancel();
    if (!mounted || value.trim() == _search) return;
    _search = value.trim();
    _reload();
  }

  /// After a change to the store's products: this list, and the store
  /// (its product count) with the Overview's numbers.
  Future<void> _changed() => Future.wait([_reload(), widget.onProductsChanged()]);

  Future<void> _addNew() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SellPhotosScreen(presetStoreId: widget.store.id)));
    if (mounted) await _changed();
  }

  Future<void> _moveIn() async {
    final moved = await showAddExistingListings(context, widget.store);
    if (moved > 0 && mounted) await _changed();
  }

  Future<void> _openActions(StoreProduct product) async {
    final action = await showModalBottomSheet<_ProductAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _ProductActionsSheet(product: product),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _ProductAction.pay:
        await _pay(product);
      case _ProductAction.price:
        await _changePrice(product);
      case _ProductAction.share:
        await _shareProduct(product);
      case _ProductAction.insights:
        Navigator.of(context).pushNamed('/listing-insights',
            arguments: listing_model.Listing.fromJson(product.json));
      case _ProductAction.view:
        Navigator.of(context).pushNamed('/product', arguments: {'listingId': product.id});
      case _ProductAction.remove:
        await _remove(product);
    }
  }

  Future<void> _pay(StoreProduct product) async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(
        builder: (_) => ListingFeeScreen(
            listingId: product.id, listingName: product.listing.name)));
    // Reloaded whether or not it says paid: an M-Pesa payment can be
    // confirmed after the owner has left the payment screen.
    if (mounted) await _changed();
  }

  Future<void> _changePrice(StoreProduct product) async {
    final price = await showDialog<double>(
        context: context, builder: (_) => _PriceDialog(product: product));
    if (price == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.listings.changePrice(product.id, price);
    if (!mounted) return;
    switch (result) {
      case Success(:final data):
        messenger.showSnackBar(SnackBar(content: Text(switch (data) {
          null => 'Price updated',
          0 => "Price updated. That was this week's last price change.",
          1 => 'Price updated. You can change it once more this week.',
          final n => 'Price updated. You can change it $n more times this week.',
        })));
        await _reload();
      case Failure(:final message):
        // The server's own words: they say which limit applies and when
        // it lifts.
        messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _shareProduct(StoreProduct product) async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await (widget.share ?? StoreShare(repository: widget.repo)).shareProduct(
        widget.store,
        listingId: product.id,
        name: product.listing.name,
        price: product.listing.priceFormatted);
    if (outcome != ShareOutcome.shared) {
      messenger.showSnackBar(const SnackBar(content: Text('Product link copied')));
    }
  }

  Future<void> _remove(StoreProduct product) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Take out of your store?', style: TextStyle(color: BrokaColors.textHigh)),
        content: Text('"${product.listing.name}" stays on BROKA as your own listing; '
            'it just won\'t appear in your store.',
            style: const TextStyle(color: BrokaColors.textMid)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Take out')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.listings.removeListingStore(product.id);
    if (!mounted) return;
    switch (result) {
      case Success():
        await _changed();
      case Failure(:final message):
        messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = _counts;
    return RefreshIndicator(
      color: BrokaColors.gold,
      onRefresh: _changed,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) _loadMore();
          return false;
        },
        child: _tabList(context, key: const Key('products-list'), children: [
          Row(children: [
            Expanded(child: FilledButton.icon(
              key: const Key('add-product'),
              onPressed: _addNew,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add product'),
              style: FilledButton.styleFrom(
                backgroundColor: BrokaColors.gold,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            )),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(
              key: const Key('move-listings-in'),
              onPressed: _moveIn,
              icon: const Icon(Icons.drive_file_move_outline),
              label: const Text('Move in'),
              style: OutlinedButton.styleFrom(
                foregroundColor: BrokaColors.textHigh,
                side: const BorderSide(color: BrokaColors.border),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            )),
          ]),
          const SizedBox(height: 14),
          _searchField(),
          const SizedBox(height: 10),
          _filterChips(counts),
          const SizedBox(height: 12),
          if (_items.isEmpty && !_loading && _error == null) _empty(counts),
          for (final p in _items)
            _ProductRow(
              product: p,
              onTap: () => _openActions(p),
              onPay: p.needsPayment && p.priceEditable ? () => _pay(p) : null,
            ),
          if (_loading)
            const Padding(padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator(color: BrokaColors.gold))),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Text(_error!, textAlign: TextAlign.center,
                    style: const TextStyle(color: BrokaColors.textMid)),
                TextButton(onPressed: _loadMore, child: const Text('Retry')),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _searchField() => TextField(
        key: const Key('product-search'),
        controller: _searchCtrl,
        onChanged: (v) {
          _onSearchChanged(v);
          setState(() {});
        },
        textInputAction: TextInputAction.search,
        onSubmitted: _setSearch,
        style: const TextStyle(color: BrokaColors.textHigh),
        decoration: InputDecoration(
          hintText: 'Search your products',
          hintStyle: const TextStyle(color: BrokaColors.textMid),
          isDense: true,
          filled: true,
          fillColor: BrokaColors.bgCard.withOpacity(0.6),
          prefixIcon: const Icon(Icons.search_rounded, color: BrokaColors.textMid),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    _setSearch('');
                    setState(() {});
                  },
                ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: BrokaColors.border)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: BrokaColors.border)),
        ),
      );

  Widget _filterChips(StoreProductCounts? counts) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final state in <StoreProductState?>[null, ...StoreProductState.values])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _FilterChip(
                key: Key('product-filter-${state?.value ?? 'all'}'),
                label: state?.label ?? 'All',
                count: counts?.of(state),
                color: state == null ? BrokaColors.gold : _stateColor(state),
                selected: state == _state,
                onTap: () => widget.filter.value = state,
              ),
            ),
        ]),
      );

  Widget _empty(StoreProductCounts? counts) {
    final (IconData icon, String title, String body) = switch (_state) {
      _ when (counts?.all ?? 0) == 0 && _search.isEmpty && _state == null => (
          Icons.inventory_2_outlined,
          'No products yet',
          'Add a new product, or move listings you already have into your store.'),
      _ when _search.isNotEmpty => (
          Icons.search_off_rounded,
          'No products match "$_search"',
          'Try another word, or clear the search.'),
      StoreProductState.hidden => (
          Icons.visibility_rounded,
          'Nothing hidden',
          'Every product in your store is showing to buyers.'),
      StoreProductState.inDeal => (
          Icons.handshake_outlined,
          'No deals in progress',
          'A product shows here while a buyer\'s deal on it is open.'),
      StoreProductState.sold => (
          Icons.sell_outlined,
          'Nothing sold yet',
          'Products show here once their deal is complete.'),
      _ => (
          Icons.storefront_outlined,
          'Nothing live right now',
          'Products show here while buyers can see them.'),
    };
    return _card(child: Column(children: [
      Icon(icon, color: BrokaColors.textMid, size: 36),
      const SizedBox(height: 10),
      Text(title, textAlign: TextAlign.center,
          style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(body, textAlign: TextAlign.center,
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
    ]));
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.count,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final int? count;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? color.withOpacity(0.18) : BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? color : BrokaColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: TextStyle(
                  color: selected ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w600)),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text('$count', style: TextStyle(
                    color: selected ? color : BrokaColors.textMid,
                    fontSize: 12, fontWeight: FontWeight.w800)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.6)),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 11,
            fontWeight: FontWeight.w700)),
      );
}

/// The line under a product's state that says what it means for the owner.
String? _stateNote(StoreProduct p) => switch (p.state) {
      StoreProductState.hidden => p.feeStatus == 'expired'
          ? "Its listing time ran out, so buyers can't see it"
          : "Not paid for yet, so buyers can't see it",
      StoreProductState.inDeal => 'A buyer agreed a deal on it',
      StoreProductState.live when p.endingSoon && p.paidUntil != null =>
        'Listing time ends ${_shortDate(p.paidUntil!)}',
      _ => null,
    };

Widget _productThumb(StoreProduct p, double size) {
  final thumb = listingThumb(p.listing);
  return ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: SizedBox(
      width: size, height: size,
      child: thumb != null
          ? BrokaImage(thumb, fit: BoxFit.cover)
          : Container(color: BrokaColors.bgMid, alignment: Alignment.center,
              child: Text(CategoryVisuals.emojiFor(p.listing.category),
                  style: TextStyle(fontSize: size * 0.4))),
    ),
  );
}

String? listingThumb(BrokaListing l) {
  if (l.cover != null) return l.cover!.thumb;
  if (l.photos.isNotEmpty) return l.photos.first.thumb;
  final legacy = l.verifiedPhotos;
  if (legacy != null && legacy.isNotEmpty) return legacy.split(',').first.trim();
  return l.showcaseImageUrl;
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product, required this.onTap, this.onPay});
  final StoreProduct product;
  final VoidCallback onTap;

  /// "Pay" or "Renew" beside the product, when its fee needs paying.
  final VoidCallback? onPay;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final note = _stateNote(p);
    final color = _stateColor(p.state);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: Key('store-product-${p.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              // A hidden product is the one to act on: its edge says so.
              border: Border.all(color: p.state == StoreProductState.hidden
                  ? BrokaColors.warning.withOpacity(0.45)
                  : BrokaColors.border.withOpacity(0.6)),
            ),
            child: Row(children: [
              Opacity(
                opacity: p.state == StoreProductState.sold ? 0.55 : 1,
                child: _productThumb(p, 62),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.listing.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textHigh,
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 3),
                Text(p.listing.priceFormatted, style: const TextStyle(
                    color: _priceColor, fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center, children: [
                  _StatePill(label: p.state.label, color: color),
                  if (note != null)
                    Text(note, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
                ]),
              ])),
              if (onPay != null)
                TextButton(
                  key: Key('pay-${p.id}'),
                  onPressed: onPay,
                  style: TextButton.styleFrom(
                    foregroundColor: BrokaColors.warning,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(48, 40),
                  ),
                  child: Text(p.state == StoreProductState.hidden ? 'Pay' : 'Renew',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              const Icon(Icons.more_vert_rounded, color: BrokaColors.textMid),
            ]),
          ),
        ),
      ),
    );
  }
}

/// What the owner can do with one product, depending on its state.
class _ProductActionsSheet extends StatelessWidget {
  const _ProductActionsSheet({required this.product});
  final StoreProduct product;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final hidden = p.state == StoreProductState.hidden;
    Widget tile(_ProductAction action, IconData icon, String title,
            {String? subtitle, Color? color}) =>
        ListTile(
          key: Key('product-action-${action.name}'),
          leading: Icon(icon, color: color ?? BrokaColors.gold),
          title: Text(title, style: TextStyle(
              color: color ?? BrokaColors.textHigh, fontWeight: FontWeight.w600)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
          onTap: () => Navigator.pop(context, action),
        );

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(
              color: BrokaColors.border, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(children: [
              _productThumb(p, 48),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.listing.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Row(children: [
                  Flexible(child: Text(p.listing.priceFormatted, maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _priceColor, fontWeight: FontWeight.w700))),
                  const SizedBox(width: 8),
                  _StatePill(label: p.state.label, color: _stateColor(p.state)),
                ]),
              ])),
            ]),
          ),
          const Divider(color: BrokaColors.border, height: 1),
          if (p.needsPayment && p.priceEditable)
            tile(_ProductAction.pay,
                hidden ? Icons.visibility_rounded : Icons.autorenew_rounded,
                hidden ? 'Pay to show it to buyers' : 'Renew its listing time',
                subtitle: hidden
                    ? "Buyers can't see it until it's paid for"
                    : (p.paidUntil != null ? 'Ends ${_shortDate(p.paidUntil!)}' : null),
                color: BrokaColors.warning),
          if (p.priceEditable)
            tile(_ProductAction.price, Icons.sell_outlined, 'Change the price',
                subtitle: 'Up to twice a week'),
          if (p.state == StoreProductState.live)
            tile(_ProductAction.share, Icons.ios_share_rounded, 'Share this product',
                subtitle: 'WhatsApp, your status, SMS and more'),
          tile(_ProductAction.insights, Icons.insights_rounded, "See how it's doing"),
          tile(_ProductAction.view, Icons.visibility_outlined, 'See it as buyers do'),
          tile(_ProductAction.remove, Icons.remove_circle_outline_rounded,
              'Take it out of the store',
              subtitle: 'It stays on BROKA as your own listing',
              color: BrokaColors.textMid),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// A new price for one product. Pops the price, or null to leave it.
class _PriceDialog extends StatefulWidget {
  const _PriceDialog({required this.product});
  final StoreProduct product;

  @override
  State<_PriceDialog> createState() => _PriceDialogState();
}

class _PriceDialogState extends State<_PriceDialog> {
  late final _ctrl =
      TextEditingController(text: widget.product.listing.price.round().toString());
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final value = double.tryParse(_ctrl.text.trim());
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter a price in shillings');
      return;
    }
    // The same price isn't a change, and would spend one of the week's two.
    Navigator.pop(context, value == widget.product.listing.price ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: BrokaColors.bgMid,
      title: const Text('Change the price', style: TextStyle(color: BrokaColors.textHigh)),
      content: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.product.listing.name, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textMid)),
        const SizedBox(height: 14),
        TextField(
          key: const Key('price-field'),
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => _save(),
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18,
              fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            prefixText: 'KES ',
            prefixStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 18),
            errorText: _error,
          ),
        ),
        const SizedBox(height: 10),
        const Text('A price can change twice a week, at least 12 hours apart.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          key: const Key('save-price'),
          onPressed: _save,
          child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}

/// Lets the owner pick their listings that aren't in the store yet and
/// moves them in. Returns how many were moved.
Future<int> showAddExistingListings(BuildContext context, Store store,
    {ListingsRepository? listings}) async {
  final moved = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: BrokaColors.bgMid,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => _AddExistingSheet(store: store, listings: listings ?? listingsRepository),
  );
  return moved ?? 0;
}

class _AddExistingSheet extends StatefulWidget {
  const _AddExistingSheet({required this.store, required this.listings});
  final Store store;
  final ListingsRepository listings;

  @override
  State<_AddExistingSheet> createState() => _AddExistingSheetState();
}

class _AddExistingSheetState extends State<_AddExistingSheet> {
  static const _pageSize = 50;
  final List<BrokaListing> _candidates = [];
  final Set<String> _picked = {};
  int _offset = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _moving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    final me = ApiService.currentUserId;
    if (me == null || _loading || !_hasMore) return;
    setState(() { _loading = true; _error = null; });
    final result = await widget.listings.getListings(
        sellerId: me, limit: _pageSize, offset: _offset);
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          _offset += data.length;
          _hasMore = data.length == _pageSize;
          final seen = _candidates.map((l) => l.id).toSet();
          _candidates.addAll(data.where((l) => l.storeId == null && !seen.contains(l.id)));
        case Failure(:final message):
          _error = message;
      }
    });
    // A page of listings that are all in the store already shows nothing;
    // keep going until something is listed or there's nothing left.
    if (_candidates.isEmpty && _hasMore && _error == null) await _loadMore();
  }

  Future<void> _move() async {
    setState(() => _moving = true);
    var moved = 0;
    final failed = <String>[];
    for (final l in _candidates.where((l) => _picked.contains(l.id)).toList()) {
      final result = await widget.listings.setListingStore(l.id, widget.store.id);
      if (result.isSuccess) {
        moved++;
      } else {
        failed.add(l.name);
      }
    }
    if (!mounted) return;
    if (failed.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          "Couldn't move ${failed.length == 1 ? '"${failed.first}"' : '${failed.length} listings'}. "
          'Try again.')));
    }
    Navigator.of(context).pop(moved);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(
              color: BrokaColors.border, borderRadius: BorderRadius.circular(2))),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('Move listings into your store', style: TextStyle(
                color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('They keep their price, photos and chats.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
          ),
          Expanded(
            child: _candidates.isEmpty
                ? Center(child: _loading
                    ? const CircularProgressIndicator(color: BrokaColors.gold)
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error ?? 'All your listings are already in your store.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: BrokaColors.textMid)),
                      ))
                : ListView.builder(
                    itemCount: _candidates.length + (_hasMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= _candidates.length) {
                        _loadMore();
                        return const Padding(padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator(color: BrokaColors.gold)));
                      }
                      final l = _candidates[i];
                      final thumb = listingThumb(l);
                      return CheckboxListTile(
                        value: _picked.contains(l.id),
                        activeColor: BrokaColors.gold,
                        onChanged: _moving ? null : (v) => setState(() {
                          v == true ? _picked.add(l.id) : _picked.remove(l.id);
                        }),
                        secondary: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(width: 46, height: 46,
                              child: thumb != null
                                  ? BrokaImage(thumb, fit: BoxFit.cover)
                                  : Container(color: BrokaColors.bgCard)),
                        ),
                        title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: BrokaColors.textHigh)),
                        subtitle: Text(l.priceFormatted,
                            style: const TextStyle(color: BrokaColors.gold)),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: GradientButton(
              height: 54,
              borderRadius: 16,
              colors: kWizardCtaGradient,
              onPressed: _picked.isEmpty || _moving ? null : _move,
              child: _moving
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(_picked.isEmpty
                      ? 'Choose listings'
                      : 'Move ${_picked.length} into the store',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Settings ─────────────────────────────────────────────────────────────────

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.store, required this.onStoreChanged});
  final Store store;
  final ValueChanged<Store> onStoreChanged;

  Future<void> _edit(BuildContext context, StoreSetupStep step) =>
      _editStore(context, store, step, onStoreChanged);

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData icon, String title, String value, StoreSetupStep? step,
            {Widget? trailing}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: BrokaColors.bgCard.withOpacity(0.6),
            borderRadius: BorderRadius.circular(14),
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: Icon(icon, color: BrokaColors.gold),
              title: Text(title, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
              subtitle: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5)),
              trailing: trailing ??
                  (step != null
                      ? const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid)
                      : null),
              onTap: step == null ? null : () => _edit(context, step),
            ),
          ),
        );

    return _tabList(context, key: const Key('settings-list'), children: [
      tile(Icons.storefront_outlined, 'Store name', store.name, StoreSetupStep.name),
      tile(Icons.link_rounded, 'Store link', store.displayUrl, null,
          trailing: const Tooltip(
            message: "A store's link can't change",
            child: Icon(Icons.lock_outline_rounded, color: BrokaColors.textLow, size: 20),
          )),
      tile(Icons.category_outlined, 'Category and description',
          [store.category ?? 'Not set', if ((store.description ?? '').isNotEmpty) store.description!]
              .join(' · '),
          StoreSetupStep.category),
      tile(Icons.place_outlined, 'Location',
          [store.locationDescription, store.subcounty, store.county]
              .where((s) => s != null && s.trim().isNotEmpty).join(', ').ifEmpty('Not set'),
          StoreSetupStep.location),
      tile(Icons.account_circle_outlined, 'Logo',
          store.logoSource != null ? 'Added' : 'None - your initial is shown',
          StoreSetupStep.logo),
      tile(Icons.photo_library_outlined, 'Cover and shop photos',
          '${store.cover != null ? 'Cover photo' : 'No cover'}, '
          '${store.photoImages.isNotEmpty ? store.photoImages.length : store.photos.length} '
          'shop photo(s)',
          StoreSetupStep.photos),
      tile(Icons.alternate_email_rounded, 'Business email',
          store.businessEmail == null
              ? 'None'
              : '${store.businessEmail}${store.businessEmailVerified ? '' : ' (not verified)'}',
          StoreSetupStep.email,
          trailing: store.businessEmailVerified
              ? const Icon(Icons.verified_rounded, color: BrokaColors.success, size: 20)
              : null),
    ]);
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
