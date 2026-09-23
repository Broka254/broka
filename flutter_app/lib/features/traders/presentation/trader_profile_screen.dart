// lib/features/traders/presentation/trader_profile_screen.dart
// Header / reputation / top-categories / all-products (Design Journal
// Volume 6, Ch.5/Ch.26, external spec Section 23). No "about" / bio
// section: User has no bio field anywhere in the schema, and inventing
// UI for data that can't be populated would just show blank space.
import 'package:flutter/material.dart';
import 'dart:convert';
import '../../../main.dart';
import '../../../widgets/product_grid_view.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/traders_repository.dart';
import '../domain/models/trader.dart';

class TraderProfileScreen extends StatefulWidget {
  final String traderId;
  const TraderProfileScreen({super.key, required this.traderId});

  @override
  State<TraderProfileScreen> createState() => _TraderProfileScreenState();
}

class _TraderProfileScreenState extends State<TraderProfileScreen> {
  Trader? _trader;
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
    final result = await tradersRepository.get(
      widget.traderId,
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _trader = data;
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
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
        title: Text(_trader?.businessName ?? 'Trader',
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold)),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
    if (_error != null || _trader == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_rounded, color: BrokaColors.textLow, size: 48),
          const SizedBox(height: 12),
          Text(_error ?? 'Trader not found', style: const TextStyle(color: BrokaColors.textMid)),
          const SizedBox(height: 8),
          TextButton(onPressed: _load, child: const Text('Retry', style: TextStyle(color: BrokaColors.gold))),
        ]),
      );
    }
    final trader = _trader!;
    return ListView(
      children: [
        _buildHeader(trader),
        _buildReputation(trader),
        if (trader.specializations != null && trader.specializations!.isNotEmpty)
          _buildTopCategories(trader),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('All Products',
              style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold, fontSize: 16)),
        ),
        SizedBox(
          height: 520,
          child: ProductGridView(
            fetchPage: (page) async {
              final result = await listingsRepository.getListings(
                sellerId: trader.id,
                limit: 20,
                offset: page * 20,
              );
              return result.fold<List<BrokaListing>>(
                onSuccess: (data) => data,
                onFailure: (_, __) => <BrokaListing>[],
              );
            },
            onTapItem: (item) => Navigator.pushNamed(context, '/product',
                arguments: {'listingId': (item as BrokaListing).id}),
            onViewStore: (storeId, storeSlug) => Navigator.pushNamed(
                context, '/store-view', arguments: {'storeId': storeId}),
            emptyStateBuilder: (_) => const Center(
              child: Text('No listings yet', style: TextStyle(color: BrokaColors.textMid)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(Trader trader) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: BrokaColors.gold.withOpacity(0.15),
            backgroundImage: (trader.profilePhoto?.isNotEmpty ?? false)
                ? MemoryImage(base64Decode(trader.profilePhoto!))
                : null,
            child: (trader.profilePhoto?.isNotEmpty ?? false)
                ? null
                : Text(
                    trader.businessName.isNotEmpty ? trader.businessName[0].toUpperCase() : '?',
                    style: const TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.bold, fontSize: 30),
                  ),
          ),
          const SizedBox(height: 12),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(trader.businessName,
                style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold, fontSize: 20)),
            if (trader.isVerified) ...[
              const SizedBox(width: 6),
              const Icon(Icons.verified, size: 18, color: Color(0xFF4DD6A5)),
            ],
          ]),
          // Added (redesign-guide audit): Design v2 §30's trader-card
          // element list includes location/distance - TradersService
          // previously never returned either.
          if (trader.locationName != null || trader.distanceKm != null) ...[
            const SizedBox(height: 6),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.location_on_outlined, size: 13, color: BrokaColors.textLow),
              const SizedBox(width: 3),
              Text(
                [
                  if (trader.locationName != null) trader.locationName!,
                  if (trader.distanceKm != null) '${trader.distanceKm!.toStringAsFixed(1)} km away',
                ].join(' · '),
                style: const TextStyle(color: BrokaColors.textLow, fontSize: 12),
              ),
            ]),
          ],
        ]),
      );

  Widget _buildReputation(Trader trader) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _statColumn(trader.rating.toStringAsFixed(1), 'Rating', Icons.star_rounded, BrokaColors.gold),
          _statColumn('${trader.completedDeals}', 'Deals Done', Icons.handshake_rounded, const Color(0xFF4DD6A5)),
          _statColumn('${trader.listingCount}', 'Listings', Icons.storefront_rounded, BrokaColors.neonPink),
        ]),
      );

  Widget _statColumn(String value, String label, IconData icon, Color color) => Column(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold, fontSize: 16)),
        Text(label, style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
      ]);

  Widget _buildTopCategories(Trader trader) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Top Categories',
              style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: trader.specializations!
                .map((s) => Chip(
                      label: Text(s.name),
                      backgroundColor: BrokaColors.bgCard,
                      labelStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 12),
                      side: const BorderSide(color: BrokaColors.border),
                    ))
                .toList(),
          ),
        ]),
      );
}
