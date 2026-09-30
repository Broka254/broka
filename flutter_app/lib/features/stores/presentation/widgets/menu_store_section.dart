// The Menu's "Online store" section.
//
// Two jobs, depending on whether the account has a store:
//
//  * It has one: a summary a seller can act on without opening anything -
//    the store's name as its sign, over its cover picture; whether it's
//    open; its link (tap to copy); how many products it shows; and the
//    last seven days of visits and shares, with Manage, Preview and Share
//    one tap away. The numbers are the backend's own
//    counts (api/domains/stores/stats.py); a figure that failed to load shows
//    a dash, never a zero.
//  * It hasn't: what a store is, in three lines, and the button that starts
//    one (or picks up a half-finished setup). Only a business can have a
//    store, so for a buyer or someone selling a few items the button sets
//    the business up first (Start selling's business steps) and then goes
//    on to the store - it never opens the store setup for an account that
//    isn't a seller yet.
//
// Loads itself, so the Menu can refresh it by giving it a new key.
import 'package:flutter/material.dart';

import '../../../../core/utils/result.dart';
import '../../../../main.dart' show BrokaColors;
import '../../../../screens/start_selling_screen.dart';
import '../../../../widgets/broka_image.dart';
import '../../../../widgets/gradient_button.dart';
import '../../../../widgets/menu_tiles.dart';
import '../../data/repositories/stores_repository.dart';
import '../../data/store_share.dart';
import '../../../categories/domain/category_visual.dart';
import '../../domain/models/store.dart';
import '../setup/store_setup_controller.dart';
import '../store_entry.dart';

class MenuStoreSection extends StatefulWidget {
  const MenuStoreSection({super.key, this.repository, this.share, this.businessReady});

  final StoresRepository? repository;
  final StoreShare? share;

  /// Whether the account is a seller set up as a business - the only kind
  /// that can open a store. Null while the Menu's account is loading, in
  /// which case the store setup's own check still applies.
  final bool? businessReady;

  @override
  State<MenuStoreSection> createState() => _MenuStoreSectionState();
}

class _MenuStoreSectionState extends State<MenuStoreSection> {
  StoresRepository get _repo => widget.repository ?? storesRepository;

  bool _loading = true;
  String? _error;
  Store? _store;
  StoreStats? _stats;
  bool _hasDraft = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await _repo.getMyStore();
    final hasDraft = await StoreSetupController.hasDraft();
    if (!mounted) return;
    switch (result) {
      case Failure(:final message):
        setState(() {
          _error = message;
          _loading = false;
        });
        return;
      case Success(:final data):
        setState(() {
          _store = data;
          _hasDraft = hasDraft;
          _loading = false;
        });
    }
    final store = _store;
    if (store == null) return;
    // After the card is up: the numbers are a detail, not a reason to keep
    // the whole section on a spinner.
    final stats = await _repo.getStats(store.id, days: 7);
    if (!mounted) return;
    if (stats case Success(:final data)) setState(() => _stats = data);
  }

  Future<void> _openStoreFlow() async {
    if (widget.businessReady == false) {
      final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => const StartSellingScreen(forStore: true)));
      if (done != true || !mounted) return;
    }
    await StoreEntry.open(context, repository: _repo);
    if (mounted) _load();
  }

  Future<void> _manage() async {
    await Navigator.pushNamed(context, '/store-manage');
    if (mounted) _load();
  }

  void _preview(Store store) =>
      Navigator.pushNamed(context, '/store-view', arguments: {'storeId': store.id});

  Future<void> _share(Store store, ShareDestination to) async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await (widget.share ?? StoreShare(repository: _repo)).share(store, to);
    if (outcome == ShareOutcome.shared) return;
    messenger.showSnackBar(const SnackBar(
      content: Text('Store link copied'),
      backgroundColor: BrokaColors.bgCard,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _Skeleton();
    if (_error != null) {
      return MenuGroup(children: [
        MenuTile(
          icon: Icons.cloud_off_rounded,
          tint: BrokaColors.warning,
          title: "Couldn't load your store",
          subtitle: _error,
          trailing: TextButton(onPressed: _load, child: const Text('Retry')),
        ),
      ]);
    }
    final store = _store;
    if (store == null) {
      return _NoStoreCard(
        hasDraft: _hasDraft,
        needsBusiness: widget.businessReady == false,
        onStart: _openStoreFlow,
      );
    }
    return _StoreCard(
      store: store,
      stats: _stats,
      onManage: _manage,
      onPreview: () => _preview(store),
      onShare: () => _share(store, ShareDestination.more),
      onCopyLink: () => _share(store, ShareDestination.copy),
    );
  }
}

// ── Has a store ──────────────────────────────────────────────────────────────

class _StoreCard extends StatelessWidget {
  const _StoreCard({
    required this.store,
    required this.stats,
    required this.onManage,
    required this.onPreview,
    required this.onShare,
    required this.onCopyLink,
  });

  final Store store;
  final StoreStats? stats;
  final VoidCallback onManage;
  final VoidCallback onPreview;
  final VoidCallback onShare;
  final VoidCallback onCopyLink;

  @override
  Widget build(BuildContext context) {
    final colors = CategoryVisuals.gradientFor(store.category);
    return Container(
      key: const Key('menu-store-card'),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.94),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.45)),
        boxShadow: [
          BoxShadow(color: BrokaColors.gold.withOpacity(0.14), blurRadius: 22),
          BoxShadow(color: colors.first.withOpacity(0.10), blurRadius: 30, offset: const Offset(0, 10)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // The store's sign: its name, large, over the picture the owner
        // chose for it (the cover, else a shop photo) or, without one, the
        // store page's aurora colours. No logo square and no initial - the
        // "C" in a box read as a missing profile picture, not a shop.
        _Banner(store: store, colors: colors, onCopyLink: onCopyLink),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              _Stat(
                icon: Icons.inventory_2_outlined,
                color: BrokaColors.gold,
                value: '${store.listingCount}',
                label: 'Products',
              ),
              const SizedBox(width: 8),
              _Stat(
                icon: Icons.visibility_outlined,
                color: BrokaColors.neonBlue,
                value: stats == null ? '—' : '${stats!.visits}',
                label: 'Visits · 7 days',
              ),
              const SizedBox(width: 8),
              _Stat(
                icon: Icons.share_outlined,
                color: BrokaColors.neonCyan,
                value: stats == null ? '—' : '${stats!.shares}',
                label: 'Shares · 7 days',
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: GradientButton(
                  height: 46,
                  borderRadius: 14,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  colors: const [BrokaColors.neonPurple, BrokaColors.neonBlue],
                  onPressed: onManage,
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.dashboard_customize_outlined, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text('Manage store', maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800,
                              fontSize: 14.5)),
                    ),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              _SquareAction(icon: Icons.storefront_outlined, tooltip: 'Preview store', onTap: onPreview),
              const SizedBox(width: 8),
              _SquareAction(icon: Icons.ios_share_rounded, tooltip: 'Share store link', onTap: onShare),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.store, required this.colors, required this.onCopyLink});
  final Store store;
  final List<Color> colors;
  final VoidCallback onCopyLink;

  @override
  Widget build(BuildContext context) {
    final picture = store.coverSource;
    final art = CustomPaint(painter: _BannerArt(colors));
    return SizedBox(
      height: 150,
      child: Stack(fit: StackFit.expand, children: [
        picture == null ? art : BrokaImage(picture, fit: BoxFit.cover, placeholder: art),
        // Dark at the foot, where the name sits, whatever the picture is.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x55000000), Color(0x11000000), Color(0xDD0B0820)],
              stops: [0, 0.4, 1],
            ),
          ),
        ),
        Positioned(
          top: 10,
          left: 12,
          right: 12,
          child: Row(children: [
            if (store.category != null)
              Flexible(
                child: _Glass(
                  child: Text('${CategoryVisuals.emojiFor(store.category)}  ${store.category}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 11.5,
                          fontWeight: FontWeight.w700)),
                ),
              ),
            const Spacer(),
            store.isActive
                ? const MenuPill('Open', color: BrokaColors.success, icon: Icons.circle)
                : const MenuPill('Paused', color: BrokaColors.warning, icon: Icons.pause_rounded),
          ]),
        ),
        Positioned(
          left: 14,
          right: 14,
          bottom: 12,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (rect) => const LinearGradient(
                colors: [Colors.white, Color(0xFFE2D4FF), Color(0xFF9ED8FF)],
              ).createShader(rect),
              child: Text(store.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 27,
                      height: 1.1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                      shadows: [Shadow(color: BrokaColors.gold.withOpacity(0.8), blurRadius: 18)])),
            ),
            const SizedBox(height: 6),
            Semantics(
              button: true,
              label: 'Copy store link',
              child: GestureDetector(
                onTap: onCopyLink,
                child: _Glass(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.link_rounded, size: 14, color: Color(0xFF9ED8FF)),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(store.displayUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.copy_rounded, size: 13, color: Colors.white70),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// The banner without a picture: the store page's aurora, still - glowing
/// orbs of the store's category colours and BROKA's violet and blue, with
/// a scatter of stars.
class _BannerArt extends CustomPainter {
  _BannerArt(this.colors);
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0B0820));
    for (final (color, x, y, r) in [
      (colors.first, 0.12, 0.2, 0.55),
      (BrokaColors.neonPurple, 0.8, 0.1, 0.6),
      (BrokaColors.neonBlue, 0.65, 1.0, 0.5),
      (colors.last, 0.3, 1.0, 0.35),
    ]) {
      final center = Offset(x * w, y * h);
      final radius = r * w;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [color.withOpacity(0.78), color.withOpacity(0)])
              .createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    final star = Paint()..color = Colors.white.withOpacity(0.55);
    var seed = 7;
    for (var i = 0; i < 26; i++) {
      // A fixed scatter (a tiny LCG), the same on every paint.
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final x = (seed % 1000) / 1000 * w;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final y = (seed % 1000) / 1000 * h;
      canvas.drawCircle(Offset(x, y), i.isEven ? 0.9 : 1.4, star);
    }
  }

  @override
  bool shouldRepaint(_BannerArt old) => old.colors != colors;
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.45),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.18)),
        ),
        child: child,
      );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.color, required this.value, required this.label});
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
          decoration: BoxDecoration(
            color: BrokaColors.bg.withOpacity(0.55),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.35)),
          ),
          child: Column(children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: color.withOpacity(0.16), shape: BoxShape.circle),
              child: Icon(icon, size: 15, color: color),
            ),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 1),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5, height: 1.2)),
          ]),
        ),
      );
}

class _SquareAction extends StatelessWidget {
  const _SquareAction({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: BrokaColors.bgMid,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: BrokaColors.gold.withOpacity(0.35)),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(icon, color: BrokaColors.textHigh, size: 20),
            ),
          ),
        ),
      );
}

// ── No store yet ─────────────────────────────────────────────────────────────

class _NoStoreCard extends StatelessWidget {
  const _NoStoreCard({required this.hasDraft, required this.needsBusiness, required this.onStart});
  final bool hasDraft;

  /// Not a business seller yet: the button sets the business up first.
  final bool needsBusiness;
  final VoidCallback onStart;

  static const _benefits = [
    (Icons.link_rounded, 'Your own link - broka.co.ke/store/your-name'),
    (Icons.grid_view_rounded, 'Every product in one place, under your logo'),
    (Icons.qr_code_2_rounded, 'A QR code, one-tap WhatsApp sharing and visitor stats'),
  ];

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [BrokaColors.gold.withOpacity(0.14), BrokaColors.neonBlue.withOpacity(0.08)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          color: BrokaColors.bgCard.withOpacity(0.9),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.45)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: BrokaColors.gold.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.storefront_rounded, color: BrokaColors.gold, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(hasDraft ? 'Finish your online store' : 'Open your online store',
                    style: const TextStyle(
                        color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(
                    needsBusiness
                        ? 'For sellers running a business - set yours up first, then open your store.'
                        : hasDraft
                            ? 'Your setup is saved on this phone - pick up where you left off.'
                            : 'A shop of your own on BROKA, with a link to share anywhere.',
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.3)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          for (final (icon, text) in _benefits)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Icon(icon, size: 17, color: BrokaColors.neonBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text,
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, height: 1.3)),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          GradientButton(
            height: 46,
            borderRadius: 12,
            colors: const [BrokaColors.neonPurple, BrokaColors.neonBlue],
            onPressed: onStart,
            child: Text(
                needsBusiness
                    ? 'Set up my business'
                    : (hasDraft ? 'Continue setting up' : 'Open a store'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14.5)),
          ),
        ]),
      );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => Container(
        height: 250,
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.7),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.border),
        ),
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold),
          ),
        ),
      );
}
