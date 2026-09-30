// BROKA — Store discovery (spec §12/§21, Phase 4)
// 1-column list, modeled directly on trader_list_screen.dart - same
// reasoning applies: ProductGridView is a fixed 2-column grid shared by
// four other screens, so a list layout for this one screen is a smaller,
// safer duplication than adding a layout mode to a shared component.
//
// A store card shows its owner's real seller record (rating once there
// are deals behind it, deals done) - never a store rating, which nothing
// computes (spec §7/§19: never fabricate one).
//
// Destination-alignment pass (2026-09-18): restyled onto the same system as
// Home and the Category Zones - ConstellationBackground, one CustomScrollView
// with the shared collapsing header, and Home's search control in place of a
// filled TextField whose textLow placeholder was effectively unreadable on a
// bgCard surface. The search now scrolls away with the rest of the header
// content instead of sitting in a fixed band above an Expanded list. Same
// repository call, same routes.
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../../../widgets/broka_search_field.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../theme/motion.dart';
import '../../categories/domain/category_visual.dart';
import '../../discovery/domain/destination_visual.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import 'store_media_image.dart';
import 'store_home_screen.dart';

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

  static const _visual = DestinationVisuals.stores;

  final _scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.25,
              colors: [
                _visual.gradient.first.withOpacity(0.15),
                Colors.transparent
              ],
              stops: const [0.0, 0.62],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: RefreshIndicator(
              onRefresh: _load,
              color: BrokaColors.gold,
              backgroundColor: BrokaColors.bgCard,
              displacement: 72,
              child: CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: CollapsingScreenHeader(
                      title: _visual.title,
                      emoji: _visual.emoji,
                      gradient: _visual.gradient,
                      onBack: () => Navigator.pop(context),
                      narrow: media.size.width < 360,
                      textScale: media.textScaler
                          .scale(1.0)
                          .clamp(1.0, 1.35)
                          .toDouble(),
                    ),
                  ),
                  SliverToBoxAdapter(child: _searchBar()),
                  ..._bodySlivers(),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The same search field as the Category Zones and Traders (see
  /// widgets/broka_search_field.dart) - the old 44px pill with 13px text was
  /// too small to read back what had been typed.
  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
        child: BrokaSearchField(
          controller: _searchCtrl,
          hintText: 'Search stores',
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _load(),
          onCleared: _load,
        ),
      );

  List<Widget> _bodySlivers() {
    if (_loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
              child: Padding(
            padding: EdgeInsets.only(bottom: 80),
            child: CircularProgressIndicator(color: BrokaColors.gold),
          )),
        ),
      ];
    }
    if (_error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: BrokaEmptyState(
              emoji: '📡',
              gradient: _visual.gradient,
              headline: "Couldn't load stores",
              body: _error!,
              action:
                  OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ),
          ),
        ),
      ];
    }
    if (_stores.isEmpty) {
      final searching = _searchCtrl.text.trim().isNotEmpty;
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: BrokaEmptyState(
              emoji: _visual.emoji,
              gradient: _visual.gradient,
              headline: searching
                  ? 'No stores match "${_searchCtrl.text.trim()}"'
                  : _visual.emptyHeadline,
              body: searching
                  ? 'Try a shorter or different search'
                  : _visual.emptyBody,
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => _StoreCard(
              store: _stores[i],
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => StoreHomeScreen(storeId: _stores[i].id))),
            ),
            childCount: _stores.length,
          ),
        ),
      ),
    ];
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

/// A store in the directory, as a shop window: the picture its owner chose
/// to show (the cover, else a shop photo, else the logo), whether the owner
/// is online, what and where it is, the seller's record, and Visit store.
///
/// Was a 52dp circle with the store's initial and three lines of small
/// text - the same card as a trader's, and nothing to show it was a shop.
///
/// Visual upgrade (2026-09-30), onto Home's product-card system: the thin
/// violet-to-blue edge and card gradient instead of a flat border, the
/// picture taller, the store's logo as its sign where the picture meets the
/// details, the seller's record as chips, and a card that sinks a little
/// under a finger. Visit store was a 42dp bar across the whole card - the
/// loudest thing on it, louder than the shop's own picture, when the whole
/// card already opens the store. It is now a pill sized to its words, at
/// the foot beside the product count, where the thumb lands.
class _StoreCard extends StatefulWidget {
  final Store store;
  final VoidCallback onTap;
  const _StoreCard({required this.store, required this.onTap});

  @override
  State<_StoreCard> createState() => _StoreCardState();
}

class _StoreCardState extends State<_StoreCard> {
  bool _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  static const _pictureHeight = 150.0;
  static const _logoSize = 58.0;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final owner = store.owner;
    final colors = CategoryVisuals.gradientFor(store.category);
    final picture = store.coverSource ?? store.logo?.medium ?? store.logoUrl;
    final logo = store.logoSource;
    // The logo as a sign only when the picture is something else: a card
    // whose only image is the logo would show it twice.
    final showLogo = logo != null && store.coverSource != null;
    final rating = owner?.shownRating;
    final deals = owner?.completedDeals ?? 0;
    final products = '${store.listingCount} product${store.listingCount == 1 ? '' : 's'}';

    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            BrokaColors.gold.withOpacity(0.45),
            BrokaColors.bgCard,
            colors.last.withOpacity(0.40),
          ],
        ),
      ),
      child: Center(
        child: Text(CategoryVisuals.emojiFor(store.category),
            style: const TextStyle(fontSize: 46)),
      ),
    );

    return Semantics(
      button: true,
      label: 'Visit ${store.name}',
      child: GestureDetector(
        key: Key('store-card-${store.id}'),
        onTap: widget.onTap,
        onTapDown: (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        child: AnimatedScale(
          scale: _down && !BrokaMotion.reduced(context) ? 0.98 : 1.0,
          duration: BrokaMotion.instant,
          curve: Curves.easeOut,
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(1.2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [BrokaColors.gold.withOpacity(0.55), BrokaColors.neonBlue.withOpacity(0.40)],
              ),
              boxShadow: [
                BoxShadow(color: BrokaColors.gold.withOpacity(0.12), blurRadius: 18),
              ],
            ),
            child: Container(
              decoration: BoxDecoration(
                gradient: BrokaColors.cardGradient,
                borderRadius: BorderRadius.circular(19),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  height: _pictureHeight,
                  child: Stack(fit: StackFit.expand, children: [
                    picture == null
                        ? fallback
                        : StoreMediaImage(dataUri: picture, placeholderBuilder: (_) => fallback),
                    // Dark at the top and foot, so the chips on the picture
                    // stay legible whatever the photo is.
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x66000000), Colors.transparent, Color(0xCC0A1220)],
                          stops: [0, 0.42, 1],
                        ),
                      ),
                    ),
                    if (owner != null && (owner.online || owner.lastActive != null))
                      Positioned(
                        top: 10,
                        left: 10,
                        child: _Pill(
                          key: const Key('store-card-presence'),
                          dot: owner.online ? BrokaColors.success : BrokaColors.textMid,
                          label: owner.online ? 'Online now' : owner.lastActive!,
                          color: owner.online ? BrokaColors.success : Colors.white70,
                        ),
                      ),
                    if (store.category != null)
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: _Pill(
                          label: '${CategoryVisuals.emojiFor(store.category)}  ${store.category}',
                          color: Colors.white,
                        ),
                      ),
                  ]),
                ),
                // The logo sits over the picture's lower edge - the sign on
                // the shop front - so the Stack lets it paint above itself.
                Stack(clipBehavior: Clip.none, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: EdgeInsets.only(left: showLogo ? _logoSize + 12 : 0),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Flexible(
                              child: Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: BrokaColors.textHigh,
                                      fontWeight: FontWeight.w800, fontSize: 17.5,
                                      letterSpacing: -0.2)),
                            ),
                            if (owner?.verified ?? false) ...[
                              const SizedBox(width: 5),
                              const Icon(Icons.verified_rounded, size: 17,
                                  color: BrokaColors.success, semanticLabel: 'Verified seller'),
                            ],
                          ]),
                          if (store.locationLine != null) ...[
                            const SizedBox(height: 3),
                            Row(children: [
                              const Icon(Icons.location_on_outlined, size: 14,
                                  color: BrokaColors.textMid),
                              const SizedBox(width: 3),
                              Flexible(child: Text(store.locationLine!, maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: BrokaColors.textMid,
                                      fontSize: 12.5))),
                            ]),
                          ],
                        ]),
                      ),
                      // At least the logo's overhang, so the chips never run
                      // under it when there's no location line.
                      SizedBox(height: showLogo && store.locationLine == null ? 16 : 10),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        _Fact(icon: Icons.star_rounded, color: BrokaColors.zoneAmber,
                            text: rating != null ? rating.toStringAsFixed(1) : 'New seller'),
                        _Fact(icon: Icons.handshake_outlined, color: BrokaColors.neonCyan,
                            text: '$deals deal${deals == 1 ? '' : 's'} done'),
                        const _Fact(icon: Icons.shield_outlined, color: BrokaColors.success,
                            text: 'Escrow protected'),
                      ]),
                      const SizedBox(height: 12),
                      Container(height: 1, color: BrokaColors.border.withOpacity(0.8)),
                      const SizedBox(height: 10),
                      Row(children: [
                        const Icon(Icons.inventory_2_outlined, size: 15,
                            color: BrokaColors.textMid),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(products, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 10),
                        _VisitButton(key: Key('visit-store-${store.id}')),
                      ]),
                    ]),
                  ),
                  if (showLogo)
                    Positioned(
                      left: 14,
                      top: -30,
                      child: _Logo(source: logo, size: _logoSize),
                    ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Visit store: a pill as wide as its words (the whole card is the tap
/// target; this says what the tap does).
class _VisitButton extends StatelessWidget {
  const _VisitButton({super.key});

  @override
  Widget build(BuildContext context) => Container(
        height: 38,
        padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
          borderRadius: BorderRadius.circular(19),
          boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.35), blurRadius: 12,
              offset: const Offset(0, 3))],
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.storefront_rounded, color: Colors.white, size: 17),
          SizedBox(width: 7),
          Text('Visit store', style: TextStyle(color: Colors.white,
              fontWeight: FontWeight.w800, fontSize: 13.5)),
          SizedBox(width: 3),
          Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 16),
        ]),
      );
}

/// The store's logo in a ring of BROKA's gradient.
class _Logo extends StatelessWidget {
  const _Logo({required this.source, required this.size});
  final String source;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(colors: BrokaColors.brandGradient),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 10)],
        ),
        child: Container(
          decoration: const BoxDecoration(shape: BoxShape.circle, color: BrokaColors.bgMid),
          clipBehavior: Clip.antiAlias,
          child: StoreMediaImage(
            dataUri: source,
            fit: BoxFit.cover,
            placeholderBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.color, this.dot});
  final String label;
  final Color color;
  final Color? dot;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(maxWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.18)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot != null) ...[
            Container(width: 7, height: 7, decoration: BoxDecoration(color: dot,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: dot!, blurRadius: 5)])),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.28)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 11.5,
              fontWeight: FontWeight.w700)),
        ]),
      );
}
