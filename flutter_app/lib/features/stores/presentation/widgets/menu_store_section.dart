// The Menu's "Online store" section.
//
// Two jobs, depending on whether the account has a store:
//
//  * It has one: a summary a seller can act on without opening anything -
//    whether the store is open, its link (tap to copy), how many products it
//    shows, and the last seven days of visits and shares, with Manage,
//    Preview and Share one tap away. The numbers are the backend's own
//    counts (api/domains/stores/stats.py); a figure that failed to load shows
//    a dash, never a zero.
//  * It hasn't: what a store is, in three lines, and the button that starts
//    one (or picks up a half-finished setup). Profile used to hide this from
//    buyers entirely, although the setup wizard takes buyers - it collects
//    the business details first.
//
// Loads itself, so the Menu can refresh it by giving it a new key.
import 'package:flutter/material.dart';

import '../../../../core/utils/result.dart';
import '../../../../main.dart' show BrokaColors;
import '../../../../widgets/broka_image.dart';
import '../../../../widgets/gradient_button.dart';
import '../../../../widgets/menu_tiles.dart';
import '../../data/repositories/stores_repository.dart';
import '../../data/store_share.dart';
import '../../domain/models/store.dart';
import '../setup/store_setup_controller.dart';
import '../store_entry.dart';

class MenuStoreSection extends StatefulWidget {
  const MenuStoreSection({super.key, this.repository, this.share});

  final StoresRepository? repository;
  final StoreShare? share;

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
    if (store == null) return _NoStoreCard(hasDraft: _hasDraft, onStart: _openStoreFlow);
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
    final cover = store.coverSource;
    final initial = store.name.isNotEmpty ? store.name[0].toUpperCase() : '?';
    return Container(
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.45)),
        boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.10), blurRadius: 18)],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // The storefront's own header in miniature: the cover photo (or the
        // brand colours when there is none) with the logo sitting across its
        // lower edge and the open/paused state on it - so the card reads as
        // the store, not as another settings row.
        Stack(clipBehavior: Clip.none, children: [
          SizedBox(
            height: 70,
            width: double.infinity,
            child: cover != null
                ? BrokaImage(cover, fit: BoxFit.cover)
                : const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF2A1A5E), Color(0xFF0E1B3D)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
          ),
          Positioned(
            top: 10,
            right: 12,
            child: store.isActive
                ? const MenuPill('Open', color: BrokaColors.success, icon: Icons.circle)
                : const MenuPill('Paused', color: BrokaColors.warning, icon: Icons.pause_rounded),
          ),
          Positioned(
            left: 14,
            bottom: -28,
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: BrokaColors.bgCard,
                border: Border.all(color: BrokaColors.bg, width: 3),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 10)],
              ),
              clipBehavior: Clip.antiAlias,
              child: store.logoSource != null
                  ? BrokaImage(store.logoSource, fit: BoxFit.cover)
                  : Container(
                      color: BrokaColors.gold.withOpacity(0.18),
                      alignment: Alignment.center,
                      child: Text(initial,
                          style: const TextStyle(
                              color: BrokaColors.gold, fontSize: 22, fontWeight: FontWeight.w800)),
                    ),
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Beside the logo's lower half, then full width below it.
            Padding(
              padding: const EdgeInsets.only(left: 70),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(store.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                InkWell(
                  onTap: onCopyLink,
                  borderRadius: BorderRadius.circular(6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                      child: Text(store.displayUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: BrokaColors.neonBlue, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.copy_rounded, size: 13, color: BrokaColors.neonBlue),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            Row(children: [
              _Stat(value: '${store.listingCount}', label: 'Products'),
              _Stat(value: stats == null ? '—' : '${stats!.visits}', label: 'Visits · 7 days'),
              _Stat(value: stats == null ? '—' : '${stats!.shares}', label: 'Shares · 7 days'),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: GradientButton(
                  height: 44,
                  borderRadius: 12,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  colors: const [BrokaColors.neonPurple, BrokaColors.neonBlue],
                  onPressed: onManage,
                  child: const Text('Manage store',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                ),
              ),
              const SizedBox(width: 8),
              _SquareAction(icon: Icons.visibility_outlined, tooltip: 'Preview store', onTap: onPreview),
              const SizedBox(width: 8),
              _SquareAction(icon: Icons.ios_share_rounded, tooltip: 'Share store link', onTap: onShare),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(value,
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        ]),
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
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: BrokaColors.border),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, color: BrokaColors.textHigh, size: 20),
            ),
          ),
        ),
      );
}

// ── No store yet ─────────────────────────────────────────────────────────────

class _NoStoreCard extends StatelessWidget {
  const _NoStoreCard({required this.hasDraft, required this.onStart});
  final bool hasDraft;
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
                    hasDraft
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
            child: Text(hasDraft ? 'Continue setting up' : 'Open a store',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14.5)),
          ),
        ]),
      );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => Container(
        height: 168,
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
