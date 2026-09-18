// lib/features/auctions/presentation/auction_house_screen.dart
// Live Now / Ending Soon / Upcoming / Completed (Design Journal Volume 6,
// Ch.6/Ch.27, external spec Section 19). Auction has no image data (the
// backend summary is Listing + auction_meta, not the full listing photos),
// so this uses dedicated text-based auction cards rather than ProductCard.
//
// Honest gap: nothing anywhere in this codebase ever transitions
// AuctionMeta.status to "ended" (no scheduled job closes auctions past
// their auction_date) - so the Completed filter calls the right endpoint and
// will render correctly, but stays empty until that job exists, which is
// outside what Volume 6 defines. "Ending Soon" isn't a status value at
// all - it's live auctions sorted by soonest end, computed here.
//
// Destination-alignment pass (2026-09-18). Two changes beyond the restyle:
//
//  * The four TabBar tabs are now a horizontal chip rail, the same control
//    the Category Zone uses for subcategories. A TabBarView gives each tab
//    its own vertical scrollable, which meant this screen could not have the
//    collapsing header the rest of the app has: the header would have had to
//    sit outside the scroll, fixed, which is the exact thing Home moved away
//    from. Same four filters, same repository calls, one scroll owner. The
//    per-tab keep-alive goes with it, so switching filters refetches - which
//    is the right default for auction data anyway.
//  * _fmtKes abbreviated to "KES 1.5M" / "KES 30K". Prices stopped being
//    abbreviated app-wide two passes ago; this file was missed because it
//    formats its own money rather than going through BrokaListing. A bid is
//    the single number a bidder needs exactly right.
import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../../../utils/price_format.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../discovery/domain/destination_visual.dart';
import '../data/repositories/auctions_repository.dart';
import '../domain/models/auction.dart';

/// One entry in the status rail: what to call it, what to ask the backend
/// for, and whether to re-sort the result by soonest end.
class _AuctionFilter {
  final String label;
  final String status;
  final bool endingSoonSort;
  const _AuctionFilter(this.label, this.status, {this.endingSoonSort = false});
}

class AuctionHouseScreen extends StatefulWidget {
  const AuctionHouseScreen({super.key});
  @override
  State<AuctionHouseScreen> createState() => _AuctionHouseScreenState();
}

class _AuctionHouseScreenState extends State<AuctionHouseScreen> {
  static const _visual = DestinationVisuals.auctions;
  static const _filters = [
    _AuctionFilter('Live Now', 'live'),
    _AuctionFilter('Ending Soon', 'live', endingSoonSort: true),
    _AuctionFilter('Upcoming', 'upcoming'),
    _AuctionFilter('Completed', 'ended'),
  ];

  final _scrollController = ScrollController();

  int _selected = 0;
  List<Auction> _auctions = [];
  bool _loading = true;
  String? _error;

  _AuctionFilter get _filter => _filters[_selected];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final filter = _filter;
    final result = await auctionsRepository.list(status: filter.status);
    if (!mounted) return;
    // A slow request for a filter the user has since moved off must not land
    // on top of the one they are now looking at.
    if (!identical(filter, _filter)) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _auctions = filter.endingSoonSort ? _sortByEndingSoon(data) : data;
        _loading = false;
      }),
      onFailure: (msg, __) => setState(() {
        _error = msg;
        _loading = false;
      }),
    );
  }

  // endsAt, not the old single auctionDate: the auction's real closing time
  // now comes from auction_meta, which is also what the backend closes on.
  List<Auction> _sortByEndingSoon(List<Auction> auctions) {
    final withDate = auctions.where((a) => a.endsAt != null).toList()
      ..sort((a, b) => a.endsAt!.compareTo(b.endsAt!));
    return withDate;
  }

  void _select(int index) {
    if (index == _selected) return;
    setState(() {
      _selected = index;
      _auctions = [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final narrow = media.size.width < 360;
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
                      narrow: narrow,
                      textScale:
                          media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                    ),
                  ),
                  SliverToBoxAdapter(child: _statusRail(narrow)),
                  ..._bodySlivers(narrow),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusRail(bool narrow) => SizedBox(
        height: 46,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          // 12 here + each chip's own 4px margin puts the first chip's edge
          // at 16, the same content edge as the header and the grid.
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          itemCount: _filters.length,
          itemBuilder: (_, i) => _chip(_filters[i].label, i == _selected,
              () => _select(i), narrow),
        ),
      );

  Widget _chip(String label, bool selected, VoidCallback onTap, bool narrow) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              gradient:
                  selected ? LinearGradient(colors: _visual.gradient) : null,
              color: selected ? null : BrokaColors.bgCard.withOpacity(0.86),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: selected ? Colors.transparent : BrokaColors.border),
              boxShadow: selected
                  ? [BoxShadow(
                      color: _visual.gradient.first.withOpacity(0.38),
                      blurRadius: 12)]
                  : null,
            ),
            child: Center(
              widthFactor: 1,
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? Colors.white : BrokaColors.textMid,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: narrow ? 12 : 12.5,
                  )),
            ),
          ),
        ),
      );

  List<Widget> _bodySlivers(bool narrow) {
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
              headline: "Couldn't load auctions",
              body: _error!,
              action: OutlinedButton(
                  onPressed: _load, child: const Text('Retry')),
            ),
          ),
        ),
      ];
    }
    if (_auctions.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: BrokaEmptyState(
              emoji: _visual.emoji,
              gradient: _visual.gradient,
              headline: _visual.emptyHeadline,
              body: '${_filter.label} · ${_visual.emptyBody}',
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            // Taller tiles on a narrow phone, same reasoning as
            // ProductGridView: a fixed ratio makes the text block eat the
            // card as the screen shrinks.
            childAspectRatio: narrow ? 0.70 : 0.78,
          ),
          delegate: SliverChildBuilderDelegate(
            (_, i) => _AuctionCard(
                auction: _auctions[i],
                gradient: _visual.gradient,
                narrow: narrow),
            childCount: _auctions.length,
          ),
        ),
      ),
    ];
  }
}

class _AuctionCard extends StatelessWidget {
  final Auction auction;
  final List<Color> gradient;
  final bool narrow;
  const _AuctionCard(
      {required this.auction, required this.gradient, required this.narrow});

  String _timeLeft() {
    // The STATUS decides whether it has ended, not this countdown. A card
    // whose local clock still shows time left on an auction the server has
    // closed must say "Ended" - that disagreement is exactly what the
    // backend is authoritative about.
    if (auction.isEnded) return 'Ended';
    if (auction.endsAt == null) return '--:--';
    final diff = auction.endsAt!.difference(DateTime.now().toUtc());
    if (diff.isNegative) return 'Ended';
    if (diff.inDays > 0) return '${diff.inDays}d ${diff.inHours % 24}h';
    if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}m';
    return '${diff.inMinutes}m';
  }

  /// Exact, digit-grouped, never abbreviated - see the file header.
  String _bidText() =>
      auction.currentBid == null ? 'No bids yet' : formatKes(auction.currentBid!);

  @override
  Widget build(BuildContext context) {
    final ended = auction.isEnded;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: BrokaColors.cardGradient,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(auction.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                height: 1.22,
                fontSize: narrow ? 12.5 : 13.5)),
        const Spacer(),
        Row(children: [
          Icon(ended ? Icons.lock_clock_rounded : Icons.timer_outlined,
              size: 12,
              color: ended ? BrokaColors.textMid : BrokaColors.danger),
          const SizedBox(width: 4),
          Flexible(
            child: Text(_timeLeft(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: ended ? BrokaColors.textMid : BrokaColors.danger,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 6),
        // Full amounts are wider than the abbreviated ones this replaced, so
        // the bid scales down to fit rather than truncating - a cut-off bid
        // would be worse than a smaller one.
        SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(_bidText(),
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                    color: BrokaColors.gold,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                    fontSize: narrow ? 15 : 16.5)),
          ),
        ),
        Text('${auction.bidCount} bid${auction.bidCount == 1 ? '' : 's'}',
            style: TextStyle(
                color: Colors.white.withOpacity(0.45), fontSize: 11)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 30,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                gradient: LinearGradient(
                    colors: ended
                        ? [BrokaColors.bgMid, BrokaColors.bgMid]
                        : gradient),
                border: ended
                    ? Border.all(color: BrokaColors.border)
                    : null,
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () => Navigator.pushNamed(context, '/auction',
                    arguments: auction.id),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(ended ? 'View Result' : 'Place Bid',
                          style: TextStyle(
                              color: ended ? BrokaColors.textMid : Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 11.5)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
