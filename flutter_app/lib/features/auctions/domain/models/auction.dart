// lib/features/auctions/domain/models/auction.dart
//
// The auction as the SERVER sees it. Every field here is read from the
// backend; none of it is derived locally, and in particular nothing in the
// app decides whether an auction is open or what the next valid bid is.
// That was the old shape's real problem: the client knew `auctionDate` and
// a current bid, so it computed "is it still running" and "is this bid high
// enough" itself - two pieces of business logic living in a place that
// cannot enforce them, drifting from a backend that had no such rules at
// all.
class Auction {
  final String id;
  final String name;

  /// "upcoming" | "live" | "ended", decided by the backend from its own
  /// clock. This is the only thing that says whether bidding is open. A
  /// local countdown reaching zero does NOT make an auction ended, and a
  /// countdown with time left does not make it live.
  final String status;

  final double? currentBid;
  final int bidCount;
  final double minBidIncrement;

  /// What the next bid must be at least. Computed by the backend from the
  /// same function that enforces it, so the number shown and the number
  /// required cannot disagree.
  final double? minNextBid;
  final double? startingPrice;

  final DateTime? startsAt;
  final DateTime? endsAt;

  /// The server's own time when this snapshot was taken, and the seconds it
  /// said were left. Used to drive the countdown from the SERVER's clock
  /// rather than the device's - a phone with a wrong clock would otherwise
  /// show a wrong countdown, and on a marketplace that is the sort of thing
  /// people believe.
  final DateTime? serverTime;
  final int? secondsRemaining;

  /// Whether the seller set a reserve, and whether bidding has cleared it.
  /// The reserve AMOUNT is deliberately never sent to a client - see
  /// lifecycle.public_state on the backend.
  final bool hasReserve;
  final bool reserveMet;

  /// Set once the auction closes: "won" | "no_bids" | "reserve_not_met" |
  /// "unpaid".
  final String? outcome;
  final String? winnerId;
  final String? winnerName;
  final double? winningAmount;

  /// The Deal the win created, and when payment is due by. Present only for
  /// a won auction - this is what turns "You won!" into something the buyer
  /// can act on.
  final String? dealId;
  final DateTime? paymentDeadline;

  final int? targetBidders;
  final String? locationName;
  final List<AuctionBid>? bidHistory;

  const Auction({
    required this.id,
    required this.name,
    required this.status,
    required this.bidCount,
    required this.minBidIncrement,
    this.currentBid,
    this.minNextBid,
    this.startingPrice,
    this.startsAt,
    this.endsAt,
    this.serverTime,
    this.secondsRemaining,
    this.hasReserve = false,
    this.reserveMet = true,
    this.outcome,
    this.winnerId,
    this.winnerName,
    this.winningAmount,
    this.dealId,
    this.paymentDeadline,
    this.targetBidders,
    this.locationName,
    this.bidHistory,
  });

  bool get isLive => status == 'live';
  bool get isUpcoming => status == 'upcoming';
  bool get isEnded => status == 'ended';
  bool get soldToSomeone => outcome == 'won' && winnerId != null;

  /// True when this viewer won and still owes payment.
  bool paymentDueFrom(String? viewerId) =>
      soldToSomeone && viewerId != null && winnerId == viewerId && dealId != null;

  static DateTime? _dt(dynamic v) =>
      v == null ? null : DateTime.tryParse(v as String);

  factory Auction.fromJson(Map<String, dynamic> json) => Auction(
        id: (json['id'] ?? json['listing_id']) as String,
        name: json['name'] as String? ?? 'Auction item',
        status: json['status'] as String? ?? 'upcoming',
        currentBid: (json['current_bid'] as num?)?.toDouble(),
        bidCount: (json['bid_count'] as num?)?.toInt() ?? 0,
        minBidIncrement: (json['min_bid_increment'] as num?)?.toDouble() ?? 500.0,
        minNextBid: (json['min_next_bid'] as num?)?.toDouble(),
        startingPrice: (json['starting_price'] as num?)?.toDouble(),
        startsAt: _dt(json['starts_at']),
        endsAt: _dt(json['ends_at']),
        serverTime: _dt(json['server_time']),
        secondsRemaining: (json['seconds_remaining'] as num?)?.toInt(),
        hasReserve: json['has_reserve'] == true,
        reserveMet: json['reserve_met'] != false,
        outcome: json['outcome'] as String?,
        winnerId: json['winner_id'] as String?,
        winnerName: json['winner_name'] as String?,
        winningAmount: (json['winning_amount'] as num?)?.toDouble(),
        dealId: json['deal_id'] as String?,
        paymentDeadline: _dt(json['payment_deadline']),
        targetBidders: (json['target_bidders'] as num?)?.toInt(),
        locationName: json['location_name'] as String?,
        bidHistory: (json['bid_history'] as List?)
            ?.map((e) => AuctionBid.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Applies a live WebSocket frame.
  ///
  /// The frame carries the auction's whole observable state, not a delta,
  /// so a client that missed one is corrected by the next rather than
  /// accumulating drift - which is what the old "currentBid: amount,
  /// bidCount: bidCount + 1" merge did on every dropped frame.
  Auction applyLiveUpdate(Map<String, dynamic> event) => Auction(
        id: id,
        name: name,
        status: event['status'] as String? ?? status,
        currentBid: (event['current_bid'] as num?)?.toDouble() ?? currentBid,
        bidCount: (event['bid_count'] as num?)?.toInt() ?? bidCount,
        minBidIncrement: minBidIncrement,
        minNextBid: (event['min_next_bid'] as num?)?.toDouble() ?? minNextBid,
        startingPrice: startingPrice,
        startsAt: startsAt,
        endsAt: endsAt,
        serverTime: _dt(event['server_time']) ?? serverTime,
        secondsRemaining: secondsRemaining,
        hasReserve: hasReserve,
        reserveMet: event['reserve_met'] as bool? ?? reserveMet,
        outcome: event['outcome'] as String? ?? outcome,
        winnerId: event['winner_id'] as String? ?? winnerId,
        winnerName: winnerName,
        winningAmount:
            (event['winning_amount'] as num?)?.toDouble() ?? winningAmount,
        dealId: dealId,
        paymentDeadline: paymentDeadline,
        targetBidders: targetBidders,
        locationName: locationName,
        bidHistory: bidHistory,
      );

  /// Marks the auction ended locally, for the one case where the client
  /// legitimately knows before its next fetch: the server rejected a bid
  /// with AUCTION_ENDED. This is not the client deciding - it is the client
  /// recording what the server just told it.
  Auction markEnded() => applyLiveUpdate(const {'status': 'ended'});
}

class AuctionBid {
  final String bidderId;
  final String bidderName;
  final double amount;
  final DateTime? createdAt;

  const AuctionBid({
    required this.bidderId,
    required this.amount,
    this.bidderName = 'Bidder',
    this.createdAt,
  });

  factory AuctionBid.fromJson(Map<String, dynamic> json) => AuctionBid(
        bidderId: json['bidder_id'] as String,
        bidderName: json['bidder_name'] as String? ?? 'Bidder',
        amount: (json['amount'] as num).toDouble(),
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'] as String)
            : null,
      );
}

/// A bid the backend refused, with the reason it gave.
///
/// The backend returns {"code": ..., "message": ...} precisely so the app
/// does not have to pattern-match English to know whether to refresh a
/// stale auction or just show the new minimum.
class BidRejection implements Exception {
  final String code;
  final String message;
  const BidRejection(this.code, this.message);

  bool get auctionIsOver => code == 'AUCTION_ENDED';
  bool get notStartedYet => code == 'AUCTION_NOT_STARTED';
  bool get tooLow => code == 'BID_TOO_LOW' || code == 'BID_CONFLICT';

  @override
  String toString() => message;
}
