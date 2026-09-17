// lib/features/traders/presentation/trader_list_screen.dart
// Wide, 1-column trader cards (Design Journal Volume 6, Ch.5/Ch.26,
// external spec Section 22). This is a dedicated list rather than
// ProductGridView with a different card: ProductGridView is a fixed
// 2-column grid used by four other phases (home feed, category zones,
// trending, traders' own "Goods" tab), so giving it a 1-column list mode
// just for this one screen would mean adding a layout toggle to a shared
// component for a single caller. Duplicating the ~20 lines of pagination
// logic here is the smaller, safer change.
import 'package:flutter/material.dart';
import 'dart:convert';
import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
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

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _buildBody();
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
        title: const Text('Traders',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold)),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
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
    if (_traders.isEmpty) {
      return const Center(
        child: Text('No traders yet', style: TextStyle(color: BrokaColors.textMid)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _traders.length,
        itemBuilder: (_, i) => _TraderCard(
          trader: _traders[i],
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => TraderProfileScreen(traderId: _traders[i].id))),
        ),
      ),
    );
  }
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
                  const Icon(Icons.location_on_outlined, size: 12, color: BrokaColors.textLow),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      [
                        if (trader.locationName != null) trader.locationName!,
                        if (trader.distanceKm != null) '${trader.distanceKm!.toStringAsFixed(1)} km away',
                      ].join(' · '),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textLow, fontSize: 11),
                    ),
                  ),
                ]),
              ],
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.star_rounded, size: 14, color: BrokaColors.gold),
                const SizedBox(width: 2),
                Text(trader.rating.toStringAsFixed(1),
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                const SizedBox(width: 10),
                Text('${trader.completedDeals} deals',
                    style: const TextStyle(color: BrokaColors.textLow, fontSize: 12)),
                const SizedBox(width: 10),
                Text('${trader.listingCount} listings',
                    style: const TextStyle(color: BrokaColors.textLow, fontSize: 12)),
              ]),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: BrokaColors.textLow),
        ]),
      ),
    );
  }
}
