// BROKA — Store discovery (spec §12/§21, Phase 4)
// 1-column list, modeled directly on trader_list_screen.dart - same
// reasoning applies: ProductGridView is a fixed 2-column grid shared by
// four other screens, so a list layout for this one screen is a smaller,
// safer duplication than adding a layout mode to a shared component.
//
// No rating/completed-deals shown on a store card, unlike TraderCard -
// Store has no such field (spec §7/§19: never fabricate one), only a
// real listingCount.
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
              if (store.category != null) ...[
                const SizedBox(height: 3),
                Text(store.category!, maxLines: 1, overflow: TextOverflow.ellipsis,
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
