// lib/features/trending/presentation/trending_screen.dart
// Thin scaffold: app bar + dense grid fed by the trending repository
// (Design Journal Volume 6, Ch.25).
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../widgets/product_grid_view.dart';
import '../../../core/utils/result.dart';
import '../data/repositories/trending_repository.dart';
import '../../listings/domain/models/listing.dart';

class TrendingScreen extends StatelessWidget {
  const TrendingScreen({super.key});

  Future<List<dynamic>> _fetchPage(int page) async {
    final result = await trendingRepository.getTrending(page: page);
    return result.fold<List<BrokaListing>>(
      onSuccess: (data) => data,
      onFailure: (_, __) => <BrokaListing>[],
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
        title: const Text('Trending',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold)),
      ),
      body: ProductGridView(
        fetchPage: _fetchPage,
        onTapItem: (item) => Navigator.pushNamed(
          context,
          '/product',
          arguments: {'listingId': (item as BrokaListing).id},
        ),
        onViewStore: (storeId, storeSlug) =>
            Navigator.pushNamed(context, '/store-view', arguments: {'storeId': storeId}),
        emptyStateBuilder: (_) => const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('🔥', style: TextStyle(fontSize: 48)),
            SizedBox(height: 12),
            Text('Nothing trending yet', style: TextStyle(color: BrokaColors.textMid)),
          ]),
        ),
      ),
    );
  }
}
