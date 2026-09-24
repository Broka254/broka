// My Store - the owner's dashboard.
//
//   Overview  open/paused switch, the link with QR and share buttons, and
//             the last 7 days of visits (and where they came from)
//   Products  the store's catalogue: add a new product straight into the
//             store, move existing listings in, take one out
//   Settings  every part of the store, edited with the setup wizard's own
//             pages; the link is shown but fixed
//
// Only real numbers are shown: visits and shares are counted by the
// backend (api/domains/stores/stats.py). Orders and revenue appear once
// checkout exists - not before, and never as placeholders.
import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../../../screens/sell_photos_screen.dart';
import '../../../services/api_service.dart';
import '../../../widgets/broka_image.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/gradient_button.dart';
import '../../../widgets/wizard_scaffold.dart';
import '../../categories/domain/category_visual.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/stores_repository.dart';
import '../data/store_share.dart';
import '../domain/models/store.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
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
        onStoreChanged: _replaceStore,
        onRefresh: _load,
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

class _Dashboard extends StatelessWidget {
  const _Dashboard({
    required this.store,
    required this.repo,
    required this.listings,
    required this.share,
    required this.onStoreChanged,
    required this.onRefresh,
  });

  final Store store;
  final StoresRepository repo;
  final ListingsRepository listings;
  final StoreShare? share;
  final ValueChanged<Store> onStoreChanged;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverAppBar(
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
        ],
        body: TabBarView(children: [
          _OverviewTab(store: store, repo: repo, share: share,
              onStoreChanged: onStoreChanged, onRefresh: onRefresh),
          _ProductsTab(store: store, repo: repo, listings: listings,
              onCountChanged: onRefresh),
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
    required this.onStoreChanged,
    required this.onRefresh,
  });

  final Store store;
  final StoresRepository repo;
  final StoreShare? share;
  final ValueChanged<Store> onStoreChanged;
  final Future<void> Function() onRefresh;

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  StoreStats? _stats;
  String? _statsError;
  bool _toggling = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
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
    return RefreshIndicator(
      color: BrokaColors.gold,
      onRefresh: () async {
        await Future.wait([_loadStats(), widget.onRefresh()]);
      },
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
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
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SellPhotosScreen(presetStoreId: store.id))),
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

class _ProductsTab extends StatefulWidget {
  const _ProductsTab({
    required this.store,
    required this.repo,
    required this.listings,
    required this.onCountChanged,
  });
  final Store store;
  final StoresRepository repo;
  final ListingsRepository listings;
  final Future<void> Function() onCountChanged;

  @override
  State<_ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends State<_ProductsTab> {
  static const _pageSize = 20;
  final List<BrokaListing> _items = [];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _reload() async {
    setState(() { _items.clear(); _hasMore = true; _error = null; });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() { _loading = true; _error = null; });
    // A paused store's public catalogue is empty; its owner still sees
    // their products, straight from the listings API.
    final result = await widget.listings.getListings(
        storeId: widget.store.id, limit: _pageSize, offset: _items.length);
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          final seen = _items.map((l) => l.id).toSet();
          _items.addAll(data.where((l) => !seen.contains(l.id)));
          _hasMore = data.length == _pageSize;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  Future<void> _remove(BrokaListing listing) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Take out of your store?', style: TextStyle(color: BrokaColors.textHigh)),
        content: Text('"${listing.name}" stays on BROKA as your own listing; '
            'it just won\'t appear in your store.',
            style: const TextStyle(color: BrokaColors.textMid)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Take out')),
        ],
      ),
    );
    if (ok != true) return;
    final result = await widget.listings.removeListingStore(listing.id);
    if (!mounted) return;
    switch (result) {
      case Success():
        setState(() => _items.removeWhere((l) => l.id == listing.id));
        widget.onCountChanged();
      case Failure(:final message):
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _addNew() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SellPhotosScreen(presetStoreId: widget.store.id)));
    if (mounted) await _reload();
  }

  Future<void> _moveIn() async {
    final moved = await showAddExistingListings(context, widget.store);
    if (moved > 0 && mounted) {
      await _reload();
      await widget.onCountChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: BrokaColors.gold,
      onRefresh: _reload,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) _loadMore();
          return false;
        },
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
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
          const SizedBox(height: 16),
          if (_items.isEmpty && !_loading && _error == null)
            _card(child: const Column(children: [
              Icon(Icons.inventory_2_outlined, color: BrokaColors.textMid, size: 36),
              SizedBox(height: 10),
              Text('No products yet', style: TextStyle(color: BrokaColors.textHigh,
                  fontWeight: FontWeight.w700)),
              SizedBox(height: 4),
              Text('Add a new product, or move listings you already have into your store.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
            ])),
          for (final l in _items) _ProductRow(listing: l, onRemove: () => _remove(l)),
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
}

String? listingThumb(BrokaListing l) {
  if (l.cover != null) return l.cover!.thumb;
  if (l.photos.isNotEmpty) return l.photos.first.thumb;
  final legacy = l.verifiedPhotos;
  if (legacy != null && legacy.isNotEmpty) return legacy.split(',').first.trim();
  return l.showcaseImageUrl;
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.listing, required this.onRemove});
  final BrokaListing listing;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final thumb = listingThumb(listing);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).pushNamed('/product',
              arguments: {'listingId': listing.id}),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 62, height: 62,
                  child: thumb != null
                      ? BrokaImage(thumb, fit: BoxFit.cover)
                      : Container(color: BrokaColors.bgMid, alignment: Alignment.center,
                          child: Text(CategoryVisuals.emojiFor(listing.category),
                              style: const TextStyle(fontSize: 24))),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(listing.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textHigh,
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 4),
                Text(listing.priceFormatted, style: const TextStyle(
                    color: BrokaColors.gold, fontWeight: FontWeight.w700, fontSize: 13)),
                if (listing.status != 'active')
                  Text(listing.status[0].toUpperCase() + listing.status.substring(1),
                      style: const TextStyle(color: BrokaColors.warning, fontSize: 11)),
              ])),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: BrokaColors.textMid),
                color: BrokaColors.bgMid,
                onSelected: (v) {
                  if (v == 'remove') onRemove();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'remove', child: Text('Take out of store',
                      style: TextStyle(color: BrokaColors.textHigh))),
                ],
              ),
            ]),
          ),
        ),
      ),
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

  Future<void> _edit(BuildContext context, StoreSetupStep step) async {
    final updated = await Navigator.of(context).push<Store>(MaterialPageRoute(
        builder: (_) => StoreEditScreen(store: store, step: step)));
    if (updated != null) onStoreChanged(updated);
  }

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

    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
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
