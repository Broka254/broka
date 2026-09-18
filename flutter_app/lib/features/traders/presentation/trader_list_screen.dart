// lib/features/traders/presentation/trader_list_screen.dart
// Wide, 1-column trader cards (Design Journal Volume 6, Ch.5/Ch.26,
// external spec Section 22). This is a dedicated list rather than
// ProductGridView with a different card: ProductGridView is a fixed
// 2-column grid used by four other phases (home feed, category zones,
// trending, traders' own "Goods" tab), so giving it a 1-column list mode
// just for this one screen would mean adding a layout toggle to a shared
// component for a single caller. Duplicating the ~20 lines of pagination
// logic here is the smaller, safer change.
//
// Destination-alignment pass (2026-09-18): restyled onto the same system as
// Home and the Category Zones - ConstellationBackground, one CustomScrollView
// with the shared collapsing header, a 16px content edge, and the destination
// registry's own blue identity instead of a flat AppBar that shared nothing
// with the rail pill that opens it. `embedded` still returns a bare body with
// no Scaffold, unchanged, for a caller that wants to host the list itself.
import 'package:flutter/material.dart';
import 'dart:convert';
import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../discovery/domain/destination_visual.dart';
import '../data/repositories/traders_repository.dart';
import '../domain/models/trader.dart';
import 'trader_profile_screen.dart';

class TraderListScreen extends StatefulWidget {
  final String? categoryId;
  // When true, renders just the list body (no Scaffold/AppBar) so
  // home_screen.dart's Goods/Traders toggle can embed it directly inside
  // its own Scaffold. Defaults to false for standalone push navigation
  // (e.g. a future "see all traders in this category" link).
  final bool embedded;
  const TraderListScreen({super.key, this.categoryId, this.embedded = false});

  @override
  State<TraderListScreen> createState() => _TraderListScreenState();
}

class _TraderListScreenState extends State<TraderListScreen> {
  final List<Trader> _traders = [];
  bool _loading = true;
  String? _error;

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
    final result = await tradersRepository.list(
      categoryId: widget.categoryId,
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _traders
          ..clear()
          ..addAll(data);
        _loading = false;
      }),
      onFailure: (msg, __) => setState(() {
        _error = msg;
        _loading = false;
      }),
    );
  }

  static const _visual = DestinationVisuals.traders;

  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _buildEmbedded();
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

  /// The pre-existing embedded mode: just the list, for a caller that brings
  /// its own Scaffold and scroll view. Kept working exactly as before.
  Widget _buildEmbedded() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
    }
    if (_error != null || _traders.isEmpty) {
      return Center(child: _stateCard());
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _traders.length,
        itemBuilder: (_, i) => _card(i),
      ),
    );
  }

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
    if (_error != null || _traders.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: _stateCard()),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => _card(i),
            childCount: _traders.length,
          ),
        ),
      ),
    ];
  }

  Widget _stateCard() => _error != null
      ? BrokaEmptyState(
          emoji: '📡',
          gradient: _visual.gradient,
          headline: "Couldn't load traders",
          body: _error!,
          action: OutlinedButton(onPressed: _load, child: const Text('Retry')),
        )
      : BrokaEmptyState(
          emoji: _visual.emoji,
          gradient: _visual.gradient,
          headline: _visual.emptyHeadline,
          body: _visual.emptyBody,
        );

  Widget _card(int i) => _TraderCard(
        trader: _traders[i],
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => TraderProfileScreen(traderId: _traders[i].id))),
      );
}

class _TraderCard extends StatelessWidget {
  final Trader trader;
  final VoidCallback onTap;
  const _TraderCard({required this.trader, required this.onTap});

  @override
  Widget build(BuildContext context) {
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
          CircleAvatar(
            radius: 26,
            backgroundColor: BrokaColors.gold.withOpacity(0.15),
            backgroundImage: (trader.profilePhoto?.isNotEmpty ?? false)
                ? MemoryImage(base64Decode(trader.profilePhoto!))
                : null,
            child: (trader.profilePhoto?.isNotEmpty ?? false)
                ? null
                : Text(
                    trader.businessName.isNotEmpty ? trader.businessName[0].toUpperCase() : '?',
                    style: const TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.bold, fontSize: 20),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(trader.businessName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 15)),
                ),
                if (trader.isVerified) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.verified, size: 15, color: Color(0xFF4DD6A5)),
                ],
              ]),
              // Added (redesign-guide audit): specialization/location -
              // Design v2 §30 lists both as trader-card elements; the data
              // now reaches this model but the card never rendered it.
              if (trader.specializations?.isNotEmpty ?? false) ...[
                const SizedBox(height: 3),
                Text(
                  'Specializes in ${trader.specializations!.first.name}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.neonBlue, fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ],
              if (trader.locationName != null || trader.distanceKm != null) ...[
                const SizedBox(height: 3),
                Row(children: [
                  Icon(Icons.location_on_outlined,
                      size: 12, color: Colors.white.withOpacity(0.42)),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      [
                        if (trader.locationName != null) trader.locationName!,
                        if (trader.distanceKm != null) '${trader.distanceKm!.toStringAsFixed(1)} km away',
                      ].join(' · '),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.48), fontSize: 11),
                    ),
                  ),
                ]),
              ],
              const SizedBox(height: 5),
              // Wrap, not Row (destination-alignment pass, 2026-09-18): three
              // fixed-width stats in a Row overflowed the card by 125px on a
              // 390dp phone once a trader had two-digit counts, and by more
              // at 320dp - a Row has no way to give the space back. Wrapping
              // lets the third stat drop to a second line on a narrow card
              // instead. textLow was also below the legibility floor for two
              // of the three; these are secondary, not invisible.
              Wrap(
                spacing: 12,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.star_rounded, size: 14, color: BrokaColors.gold),
                    const SizedBox(width: 3),
                    Text(trader.rating.toStringAsFixed(1),
                        style: const TextStyle(
                            color: BrokaColors.textMid,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ]),
                  Text('${trader.completedDeals} deals',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.45), fontSize: 12)),
                  Text('${trader.listingCount} listings',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.45), fontSize: 12)),
                ],
              ),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: BrokaColors.textLow),
        ]),
      ),
    );
  }
}
