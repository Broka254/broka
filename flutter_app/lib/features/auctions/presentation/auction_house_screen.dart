// lib/features/auctions/presentation/auction_house_screen.dart
// Live Now / Ending Soon / Upcoming / Completed (Design Journal Volume 6,
// Ch.6/Ch.27, external spec Section 19). Auction has no image data (the
// backend summary is Listing + auction_meta, not the full listing photos),
// so this uses dedicated text-based auction cards rather than ProductCard.
//
// Honest gap: nothing anywhere in this codebase ever transitions
// AuctionMeta.status to "ended" (no scheduled job closes auctions past
// their auction_date) - so the Completed tab calls the right endpoint and
// will render correctly, but stays empty until that job exists, which is
// outside what Volume 6 defines. "Ending Soon" isn't a status value at
// all - it's live auctions sorted by soonest auction_date, computed here.
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../data/repositories/auctions_repository.dart';
import '../domain/models/auction.dart';

class AuctionHouseScreen extends StatefulWidget {
  const AuctionHouseScreen({super.key});
  @override
  State<AuctionHouseScreen> createState() => _AuctionHouseScreenState();
}

class _AuctionHouseScreenState extends State<AuctionHouseScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  static const _tabs = ['Live Now', 'Ending Soon', 'Upcoming', 'Completed'];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
        title: const Text('Auction House',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold)),
        bottom: TabBar(
          controller: _tabCtrl,
          isScrollable: true,
          indicatorColor: BrokaColors.gold,
          labelColor: BrokaColors.gold,
          unselectedLabelColor: BrokaColors.textMid,
          tabs: _tabs.map((t) => Tab(text: t)).toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          _AuctionGrid(status: 'live'),
          _AuctionGrid(status: 'live', endingSoonSort: true),
          _AuctionGrid(status: 'upcoming'),
          _AuctionGrid(status: 'ended'),
        ],
      ),
    );
  }
}

class _AuctionGrid extends StatefulWidget {
  final String status;
  final bool endingSoonSort;
  const _AuctionGrid({required this.status, this.endingSoonSort = false});

  @override
  State<_AuctionGrid> createState() => _AuctionGridState();
}

class _AuctionGridState extends State<_AuctionGrid> with AutomaticKeepAliveClientMixin {
  List<Auction> _auctions = [];
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

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
    final result = await auctionsRepository.list(status: widget.status);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _auctions = widget.endingSoonSort ? _sortByEndingSoon(data) : data;
        _loading = false;
      }),
      onFailure: (msg, __) => setState(() {
        _error = msg;
        _loading = false;
      }),
    );
  }

  List<Auction> _sortByEndingSoon(List<Auction> auctions) {
    final withDate = auctions.where((a) => a.auctionDate != null).toList()
      ..sort((a, b) => a.auctionDate!.compareTo(b.auctionDate!));
    return withDate;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
    if (_auctions.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        color: BrokaColors.gold,
        child: ListView(children: const [
          SizedBox(height: 120),
          Center(child: Text('No auctions here yet', style: TextStyle(color: BrokaColors.textMid))),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.82),
        itemCount: _auctions.length,
        itemBuilder: (_, i) => _AuctionCard(auction: _auctions[i]),
      ),
    );
  }
}

class _AuctionCard extends StatelessWidget {
  final Auction auction;
  const _AuctionCard({required this.auction});

  String _timeLeft() {
    if (auction.auctionDate == null) return '--:--';
    final diff = auction.auctionDate!.difference(DateTime.now().toUtc());
    if (diff.isNegative) return 'Ended';
    if (diff.inDays > 0) return '${diff.inDays}d ${diff.inHours % 24}h';
    if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}m';
    return '${diff.inMinutes}m';
  }

  String _fmtKes(num? v) {
    if (v == null) return 'No bids yet';
    if (v >= 1000000) return 'KES ${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return 'KES ${(v / 1000).toStringAsFixed(0)}K';
    return 'KES ${v.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(auction.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w600, fontSize: 13)),
        const Spacer(),
        Row(children: [
          const Icon(Icons.timer_outlined, size: 12, color: BrokaColors.danger),
          const SizedBox(width: 3),
          Text(_timeLeft(), style: const TextStyle(color: BrokaColors.danger, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        Text(_fmtKes(auction.currentBid),
            style: const TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.bold, fontSize: 14)),
        Text('${auction.bidCount} bid${auction.bidCount == 1 ? '' : 's'}',
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.gold,
              padding: const EdgeInsets.symmetric(vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pushNamed(context, '/auction', arguments: auction.id),
            child: const Text('Place Bid',
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ),
      ]),
    );
  }
}
