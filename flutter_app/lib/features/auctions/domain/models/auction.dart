// lib/features/auctions/domain/models/auction.dart
class Auction {
  final String id;
  final String name;
  final String status; // "upcoming" | "live" | "ended" (server-defined string, not an enum)
  final double? currentBid;
  final int bidCount;
  final double minBidIncrement;
  final String? winnerId;
  final DateTime? auctionDate;
  final double? reservePrice;
  final int? targetBidders;
  final String? locationName;
  final List<AuctionBid>? bidHistory; // only present on the single-auction detail response

  Auction({
    required this.id,
    required this.name,
    required this.status,
    required this.bidCount,
    required this.minBidIncrement,
    this.currentBid,
    this.winnerId,
    this.auctionDate,
    this.reservePrice,
    this.targetBidders,
    this.locationName,
    this.bidHistory,
  });

  factory Auction.fromJson(Map<String, dynamic> json) => Auction(
        id: json['id'] as String,
        name: json['name'] as String,
        status: json['status'] as String,
        currentBid: (json['current_bid'] as num?)?.toDouble(),
        bidCount: (json['bid_count'] as num?)?.toInt() ?? 0,
        minBidIncrement: (json['min_bid_increment'] as num?)?.toDouble() ?? 500.0,
        winnerId: json['winner_id'] as String?,
        auctionDate: json['auction_date'] != null ? DateTime.tryParse(json['auction_date'] as String) : null,
        reservePrice: (json['reserve_price'] as num?)?.toDouble(),
        targetBidders: (json['target_bidders'] as num?)?.toInt(),
        locationName: json['location_name'] as String?,
        bidHistory: (json['bid_history'] as List?)
            ?.map((e) => AuctionBid.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class AuctionBid {
  final String bidderId;
  final double amount;
  AuctionBid({required this.bidderId, required this.amount});
  factory AuctionBid.fromJson(Map<String, dynamic> json) => AuctionBid(
        bidderId: json['bidder_id'] as String,
        amount: (json['amount'] as num).toDouble(),
      );
}
