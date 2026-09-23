// BROKA - Auction screen.
//
// The backend owns the auction. This screen renders what it is told and
// asks it to do things; it does not decide whether an auction is open, what
// the next valid bid is, or whether a bid was any good.
//
// That is a real change, not a restatement. Before, this screen validated
// bids itself against the top of the leaderboard (`amount <= _topBid`),
// which is not the rule the backend uses; it ran a countdown from the
// device's own clock and treated reaching zero as the auction being over;
// and - worst of the three - when the bid API failed it inserted the bid
// into the leaderboard anyway, so a bid the server REJECTED appeared to the
// bidder to have been accepted, at the top, as theirs.
//
// The countdown that remains is decoration. When the server says an auction
// has ended, this screen treats it as ended immediately, whatever the timer
// is showing.
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import '../core/network/auction_ws_client.dart';
import '../core/utils/result.dart';
import '../features/auctions/data/repositories/auctions_repository.dart';
import '../features/auctions/domain/models/auction.dart' as auction_model;
import '../widgets/zeno_avatar.dart';

class AuctionScreen extends StatefulWidget {
  // Real auction to display. Falls back to a hardcoded demo listing when
  // absent, matching what this screen already did unconditionally before
  // this edit - so the bare '/auction' route registration in main.dart
  // (no arguments) keeps working exactly as it did.
  final String? listingId;
  const AuctionScreen({super.key, this.listingId});
  @override
  State<AuctionScreen> createState() => _AuctionScreenState();
}

class _AuctionScreenState extends State<AuctionScreen> {
  final _bidCtrl = TextEditingController();
  int _secondsLeft = 14 * 60 + 32;
  int _totalCountdownSeconds = 14 * 60 + 32; // for the progress bar denominator
  Timer? _timer;
  Timer? _refreshTimer;
  List<Bid> _bids = [];
  bool _loadingBids = true;
  bool _placingBid = false;
  String? _bidError;
  static const _demoListingId = 'd3';

  auction_model.Auction? _auction; // real data, when widget.listingId is set
  AuctionWsClient? _wsClient;

  /// Offset between the server's clock and this device's, measured from the
  /// `server_time` the auction payload carries. A phone with a wrong clock
  /// would otherwise show a confidently wrong countdown on something people
  /// are spending money against.
  Duration _clockSkew = Duration.zero;

  bool get _isReal => widget.listingId != null;
  bool get _biddingOpen => _auction?.isLive ?? !_isReal;

  String get _targetListingId => widget.listingId ?? _demoListingId;

  final _demoBids = const [
    Bid(rank: 1, bidderName: 'Peter Otieno',  amount: 85000, timeAgo: '2m ago'),
    Bid(rank: 2, bidderName: 'Grace Wanjiru', amount: 80000, timeAgo: '5m ago'),
    Bid(rank: 3, bidderName: 'David Njoroge', amount: 78000, timeAgo: '8m ago'),
    Bid(rank: 4, bidderName: 'Amina Hassan',  amount: 75000, timeAgo: '12m ago'),
    Bid(rank: 5, bidderName: 'John Mwangi',   amount: 70000, timeAgo: '18m ago'),
  ];

  @override
  void initState() {
    super.initState();
    _loadLeaderboard();
    if (widget.listingId != null) {
      _loadAuction();
      _connectWs();
    } else {
      // Demo path, unchanged from before this edit.
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_secondsLeft > 0 && mounted) setState(() => _secondsLeft--);
      });
    }
    _refreshTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _loadLeaderboard());
  }

  Future<void> _loadAuction() async {
    final result = await auctionsRepository.get(_targetListingId);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) {
        setState(() {
          _auction = data;
          // Trust the server's clock over the phone's.
          if (data.serverTime != null) {
            _clockSkew = data.serverTime!.difference(DateTime.now().toUtc());
          }
        });
        _startRealCountdown(data);
      },
      onFailure: (_, __) {
        // Falls back to the demo countdown if the real auction can't be
        // fetched, rather than showing a frozen 00:00 timer.
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_secondsLeft > 0 && mounted) setState(() => _secondsLeft--);
        });
      },
    );
  }

  /// Purely visual. It counts down to the server's `ends_at` using the
  /// server's clock, and when it reaches zero it does NOT declare the
  /// auction over - it asks the server, which is the only thing that can
  /// answer. A countdown that closed the auction by itself would disagree
  /// with the backend the moment a clock drifted or a close was delayed.
  void _startRealCountdown(auction_model.Auction auction) {
    _timer?.cancel();
    final endsAt = auction.endsAt;
    if (endsAt == null) return;

    void tick() {
      if (!mounted) return;
      final now = DateTime.now().toUtc().add(_clockSkew);
      final remaining = endsAt.difference(now).inSeconds;
      setState(() => _secondsLeft = remaining < 0 ? 0 : remaining);
      if (remaining <= 0 && (_auction?.isLive ?? false)) {
        // Time is up by our reckoning. Confirm with the server rather than
        // assuming - and stop ticking either way.
        _timer?.cancel();
        _loadAuction();
      }
    }

    // Denominator for the progress bar: time from now to the auction end,
    // captured once so the bar actually empties over the real duration
    // instead of dividing by a constantly-changing number.
    final total = endsAt
        .difference(DateTime.now().toUtc().add(_clockSkew))
        .inSeconds;
    _totalCountdownSeconds = total < 1 ? 1 : total;
    tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void _connectWs() {
    final token = ApiService.authToken;
    if (token == null) return; // not logged in - no live updates, leaderboard polling still covers it
    _wsClient = AuctionWsClient(
      listingId: _targetListingId,
      token: token,
      onEvent: (event) {
        if (!mounted || _auction == null) return;
        final type = event['type'];
        if (type != 'bid_placed' && type != 'auction_closed') return;

        // The frame carries the auction's whole observable state, so this
        // replaces what we hold rather than incrementing it - a client that
        // missed a frame is corrected by the next one instead of drifting.
        setState(() => _auction = _auction!.applyLiveUpdate(event));

        if (type == 'auction_closed') {
          // The server has closed it. Stop the countdown immediately,
          // whatever it currently reads, and pull the full result (winner,
          // deal, payment deadline) which the frame does not carry.
          _timer?.cancel();
          setState(() => _secondsLeft = 0);
          _loadAuction();
        }
        _loadLeaderboard(); // refresh the full ranked list from the server
      },
    )..connect();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _refreshTimer?.cancel();
    _bidCtrl.dispose();
    _wsClient?.dispose();
    super.dispose();
  }

  Future<void> _loadLeaderboard() async {
    try {
      final b = await ApiService.getLeaderboard(_targetListingId);
      if (mounted) {
        setState(() {
        // fixed: cast List<dynamic> to List<Bid>
        _bids = b
            .map((e) => Bid.fromJson(e as Map<String, dynamic>))
            .toList();
        _loadingBids = false;
      });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
        _bids = widget.listingId != null ? [] : List<Bid>.from(_demoBids);
        _loadingBids = false;
      });
      }
    }
  }

  Future<void> _placeBid() async {
    final amount = double.tryParse(_bidCtrl.text.trim().replaceAll(',', ''));
    if (amount == null || amount <= 0) {
      setState(() => _bidError = 'Enter a valid amount');
      return;
    }
    // Deliberately NO increment/higher-than-current check here. The backend
    // owns that rule and enforces it under a lock; a second copy of it in
    // the client could only ever be a stale, differently-wrong version of
    // the same thing. The minimum IS shown to the user (see
    // _buildBidInput) - shown from the server's own number, not computed
    // here.
    setState(() { _placingBid = true; _bidError = null; });
    try {
      final res = await ApiService.placeBid(
          listingId: _targetListingId, amount: amount);
      _bidCtrl.clear();
      // Take the fresh state the bid response carries so the minimum and
      // the count update without waiting for a socket frame.
      if (mounted && _auction != null) {
        setState(() => _auction = _auction!.applyLiveUpdate({
              'current_bid': res['amount'],
              'bid_count': res['bid_count'],
              'min_next_bid': res['min_next_bid'],
              'status': res['status'],
              'reserve_met': res['reserve_met'],
            }));
      }
      await _loadLeaderboard();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Bid placed: ${Bid.fmt(amount)}')));
      }
    } on auction_model.BidRejection catch (e) {
      // The server said no. Show exactly why, and change nothing about the
      // leaderboard - this is where a rejected bid used to be drawn in as
      // though it had been accepted.
      if (!mounted) return;
      setState(() => _bidError = e.message);
      if (e.auctionIsOver) {
        // It ended while this screen still thought it was live. Believe the
        // server over the countdown, immediately.
        _timer?.cancel();
        setState(() {
          _secondsLeft = 0;
          if (_auction != null) _auction = _auction!.markEnded();
        });
        await _loadAuction();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _bidError =
            "Couldn't reach the auction just now — your bid was not placed.");
      }
    } finally {
      if (mounted) setState(() => _placingBid = false);
    }
  }

  /// What the next bid has to be, as the SERVER computed it.
  double? get _minNextBid => _auction?.minNextBid;

  String get _statusLabel => switch (_auction?.status) {
        'upcoming' => 'UPCOMING',
        'ended' => 'ENDED',
        _ => 'LIVE',
      };

  Color get _statusColor => switch (_auction?.status) {
        'upcoming' => BrokaColors.warning,
        'ended' => BrokaColors.textLow,
        _ => BrokaColors.danger,
      };

  String get _countdown {
    final m = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final s = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Color get _timerColor => _secondsLeft < 120
      ? BrokaColors.danger
      : _secondsLeft < 300
          ? BrokaColors.warning
          : BrokaColors.gold;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: BrokaColors.headerGradColors,
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: BrokaColors.bgCard,
                        border: Border.all(color: BrokaColors.border)),
                    child: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: BrokaColors.textMid, size: 16)),
                ),
                const SizedBox(width: 12),
                const Text('AUCTION', style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800,
                    color: BrokaColors.textHigh)),
                const Spacer(),
                // The badge says what the SERVER says, not what the
                // countdown implies. It used to be hardcoded to "LIVE",
                // which was wrong for every auction that had not started
                // and every one that was over.
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _statusColor.withOpacity(0.4)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 7, height: 7, decoration: BoxDecoration(
                        color: _statusColor, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(_statusLabel, style: TextStyle(color: _statusColor,
                        fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1)),
                  ]),
                ),
              ]),
            ),

            Expanded(child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                if (_auction?.isEnded ?? false) ...[
                  _buildOutcomeBanner(),
                  const SizedBox(height: 14),
                ],
                _buildAuctionCard(),
                const SizedBox(height: 14),
                // No bid box at all once bidding is closed - an input the
                // server would only reject is worse than no input.
                if (_biddingOpen) ...[
                  _buildBidInput(),
                  const SizedBox(height: 20),
                ],
                _buildLeaderboard(),
              ]),
            )),
          ]),
        ),
      ),
    );
  }

  Widget _buildAuctionCard() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: BrokaColors.cardGradColors,
        begin: Alignment.topLeft, end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BrokaColors.border),
      boxShadow: const [BrokaColors.glowGold],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_auction != null ? _auction!.name : '🏠 3-Bed Penthouse, Kileleshwa',
        style: const TextStyle(color: BrokaColors.textHigh,
            fontWeight: FontWeight.w700, fontSize: 16)),
      const SizedBox(height: 3),
      Row(children: [
        const Icon(Icons.location_on_outlined, size: 12, color: BrokaColors.textLow),
        const SizedBox(width: 3),
        Text(_auction?.locationName ?? 'Kileleshwa, Nairobi County',
          style: const TextStyle(color: BrokaColors.textLow, fontSize: 12)),
      ]),
      const SizedBox(height: 18),

      Row(children: [
        _metric(
          _auction?.currentBid != null
              ? Bid.fmt(_auction!.currentBid!)
              : (_isReal ? 'No bids yet' : Bid.fmt(10500000)),
          'CURRENT BID', BrokaColors.gold,
        ),
        _vDivider(),
        // The seller's reserve AMOUNT is never sent to a client and is
        // never shown. What a bidder needs - and is entitled to - is
        // whether the bidding has cleared it.
        _metric(
          !_isReal
              ? '—'
              : !(_auction?.hasReserve ?? false)
                  ? 'None'
                  : (_auction!.reserveMet ? 'Met' : 'Not met'),
          'RESERVE',
          !_isReal || !(_auction?.hasReserve ?? false)
              ? null
              : (_auction!.reserveMet ? BrokaColors.success : BrokaColors.warning),
        ),
        _vDivider(),
        _metric(
          _auction != null ? '${_auction!.bidCount}' : '8',
          'BIDS', BrokaColors.success,
        ),
      ]),
      if (_isReal && _minNextBid != null && _biddingOpen) ...[
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.trending_up_rounded, size: 13, color: BrokaColors.textLow),
          const SizedBox(width: 6),
          Text('Next bid must be at least ${Bid.fmt(_minNextBid!)}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        ]),
      ],
      const SizedBox(height: 18),
      Container(height: 1, color: BrokaColors.border),
      const SizedBox(height: 16),

      Row(children: [
        const Text('TIME REMAINING', style: TextStyle(color: BrokaColors.textLow,
            fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
        const Spacer(),
        ShaderMask(
          shaderCallback: (b) => LinearGradient(
            colors: [_timerColor, _timerColor.withOpacity(0.7)]).createShader(b),
          child: Text(_countdown, style: const TextStyle(
            color: Colors.white, fontSize: 30,
            fontWeight: FontWeight.w900, letterSpacing: 3)),
        ),
      ]),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: _secondsLeft / _totalCountdownSeconds,
          backgroundColor: BrokaColors.bgCard,
          valueColor: AlwaysStoppedAnimation(_timerColor),
          minHeight: 4,
        ),
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            BrokaColors.gold.withOpacity(0.10),
            BrokaColors.goldDim.withOpacity(0.05),
          ]),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.2)),
        ),
        // Derived from the auction's real state. This line used to be a
        // hardcoded string claiming a specific competitive bid and that the
        // reserve was met - on every auction, regardless of either.
        child: Row(children: [
          const ZenoAvatar(size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(_zenoHint(),
              style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 11, height: 1.4))),
        ]),
      ),
    ]),
  );

  /// Zeno's line, built from what the auction actually is.
  String _zenoHint() {
    final a = _auction;
    if (a == null) return 'AI Broker: bidding opens with the starting price.';
    if (a.isUpcoming) {
      return 'AI Broker: bidding hasn\'t opened yet — I\'ll keep this page live.';
    }
    if (a.isEnded) {
      return switch (a.outcome) {
        'won' => 'AI Broker: this auction sold to the highest bidder.',
        'reserve_not_met' =>
          'AI Broker: bidding ended below the seller\'s reserve, so it didn\'t sell.',
        'unpaid' =>
          'AI Broker: the winner didn\'t complete payment, so it\'s available again.',
        _ => 'AI Broker: this auction ended without any bids.',
      };
    }
    if (a.hasReserve && !a.reserveMet) {
      return 'AI Broker: the seller\'s reserve hasn\'t been met yet — '
          'this won\'t sell until it is.';
    }
    if (a.minNextBid != null) {
      return 'AI Broker: ${Bid.fmt(a.minNextBid!)} is the next valid bid.';
    }
    return 'AI Broker: place a bid to get into this auction.';
  }

  /// What happened, and what the viewer has to do about it.
  ///
  /// The brief's point exactly: a win that just says "You won!" and leaves
  /// the buyer to work out the rest is not a lifecycle. When this viewer is
  /// the winner, this is the hand-off into the existing Deal + E-Confirm
  /// payment flow, with the deadline stated.
  Widget _buildOutcomeBanner() {
    final a = _auction;
    if (a == null) return const SizedBox.shrink();

    final iWon = a.paymentDueFrom(ApiService.currentUserId);
    final (String title, String body, Color tint) = switch (a.outcome) {
      'won' when iWon => (
          '🎉 You won!',
          'You won ${a.name} for ${Bid.fmt(a.winningAmount ?? 0)}. '
              'Payment is required to complete it'
              '${a.paymentDeadline != null ? " by ${_fmtDeadline(a.paymentDeadline!)}" : ""}.',
          BrokaColors.success,
        ),
      'won' => (
          'Auction ended',
          'This auction has ended. '
              '${a.winnerName != null ? "${a.winnerName} won it" : "Another bidder won"}'
              '${a.winningAmount != null ? " for ${Bid.fmt(a.winningAmount!)}" : ""}.',
          BrokaColors.textLow,
        ),
      'reserve_not_met' => (
          'Ended — reserve not met',
          'Bidding ended below the seller\'s reserve price, so the item did not sell.',
          BrokaColors.warning,
        ),
      'unpaid' => (
          'Ended — payment not completed',
          'The winning bidder did not pay in time. The item may be listed again.',
          BrokaColors.warning,
        ),
      _ => (
          'Auction ended',
          'This auction ended with no bids.',
          BrokaColors.textLow,
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tint.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tint.withOpacity(0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(
            color: tint, fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(body, style: const TextStyle(
            color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
        if (iWon) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => _payForWin(a),
              style: ElevatedButton.styleFrom(
                backgroundColor: BrokaColors.gold,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: const Text('Pay now',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ]),
    );
  }

  /// Takes the winner into the SAME payment flow a negotiated deal uses:
  /// phone number -> fund the deal's escrow -> the E-Confirm payment
  /// screen. Deliberately not a separate auction payment path - the win
  /// already produced an ordinary Deal on the backend, so from here on it
  /// is an ordinary BROKA purchase.
  Future<void> _payForWin(auction_model.Auction auction) async {
    final dealId = auction.dealId;
    if (dealId == null) return;

    final phoneCtrl = TextEditingController(
        text: ApiService.currentUserPhone ?? '');
    String? error;
    bool busy = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: BrokaColors.bgCard,
          title: const Text('Pay for your win',
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              '${auction.name} — ${Bid.fmt(auction.winningAmount ?? 0)}. '
              'Your payment is held in escrow until you confirm the item arrived.',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: const InputDecoration(
                labelText: 'M-Pesa phone number',
                labelStyle: TextStyle(color: BrokaColors.textLow),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: const TextStyle(
                  color: BrokaColors.danger, fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('Not now',
                  style: TextStyle(color: BrokaColors.textMid)),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      final phone = phoneCtrl.text.trim();
                      if (phone.isEmpty) {
                        setDlg(() => error = 'Enter your phone number');
                        return;
                      }
                      setDlg(() { busy = true; error = null; });
                      try {
                        final funded = await ApiService.fundDealEscrow(
                            dealId: dealId, payerPhone: phone);
                        final total =
                            (funded['total_to_pay'] as num?)?.toDouble() ??
                                (auction.winningAmount ?? 0);
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        if (!mounted) return;
                        Navigator.pushNamed(context, '/escrow-payment',
                            arguments: {
                              'deal_id': dealId,
                              'amount': total,
                              'phone': phone,
                              'listing_name': auction.name,
                            });
                      } catch (e) {
                        setDlg(() {
                          busy = false;
                          error = e.toString().replaceAll('Exception: ', '');
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: BrokaColors.gold))
                  : const Text('Pay now',
                      style: TextStyle(color: BrokaColors.gold)),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtDeadline(DateTime deadline) {
    final local = deadline.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '${local.day}/${local.month} at $h:$m';
  }

  Widget _metric(String v, String l, Color? c) =>
    Expanded(child: Column(children: [
      Text(v, style: TextStyle(
        color: c ?? BrokaColors.textHigh,
        fontWeight: FontWeight.w800, fontSize: 14),
        textAlign: TextAlign.center),
      const SizedBox(height: 3),
      Text(l, style: const TextStyle(color: BrokaColors.textLow,
          fontSize: 9, letterSpacing: 0.8, fontWeight: FontWeight.w600),
          textAlign: TextAlign.center),
    ]));

  Widget _vDivider() => Container(
      width: 1, height: 32, color: BrokaColors.border,
      margin: const EdgeInsets.symmetric(horizontal: 8));

  Widget _buildBidInput() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: BrokaColors.cardGradColors),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('PLACE YOUR BID', style: TextStyle(color: BrokaColors.textLow,
          fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: TextField(
          controller: _bidCtrl,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: BrokaColors.gold,
              fontWeight: FontWeight.w800, fontSize: 16),
          decoration: InputDecoration(
            hintText: _minNextBid != null
                ? 'Min ${Bid.fmt(_minNextBid!)}'
                : 'Enter amount (KES)',
            prefixText: 'KES ',
            prefixStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 13),
          ),
        )),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: _placingBid ? null : _placeBid,
          child: Container(
            width: 80, height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.goldDim]),
              boxShadow: const [BrokaColors.glowGold],
            ),
            child: Center(child: _placingBid
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('BID', style: TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w900, letterSpacing: 1))),
          ),
        ),
      ]),
      if (_bidError != null) ...[
        const SizedBox(height: 8),
        Text(_bidError!, style: const TextStyle(
            color: BrokaColors.danger, fontSize: 12)),
      ],
    ]),
  );

  Widget _buildLeaderboard() => Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('BID LEADERBOARD', style: TextStyle(color: BrokaColors.textLow,
        fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
    const SizedBox(height: 10),
    if (_loadingBids)
      const Center(child: Padding(padding: EdgeInsets.all(24),
        child: CircularProgressIndicator(
            strokeWidth: 1.5, color: BrokaColors.gold)))
    else
      Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(children: List.generate(_bids.length, (i) {
          final b = _bids[i];
          final isTop = b.rank == 1;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: isTop ? LinearGradient(colors: [
                BrokaColors.gold.withOpacity(0.12),
                BrokaColors.goldDim.withOpacity(0.05),
              ]) : null,
              borderRadius: i == 0
                  ? const BorderRadius.vertical(top: Radius.circular(16))
                  : i == _bids.length - 1
                      ? const BorderRadius.vertical(bottom: Radius.circular(16))
                      : BorderRadius.zero,
              border: i < _bids.length - 1
                  ? const Border(bottom: BorderSide(color: BrokaColors.border))
                  : null,
            ),
            child: Row(children: [
              SizedBox(width: 32, child: Text('#${b.rank}', style: TextStyle(
                fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 0.5,
                color: isTop ? BrokaColors.gold : BrokaColors.textLow))),
              Text(b.bidderName, style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontWeight: FontWeight.w600, fontSize: 13)),
              const Spacer(),
              ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.neonBlue])
                    .createShader(r),
                child: Text(b.formattedAmount, style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800, fontSize: 13))),
              const SizedBox(width: 10),
              Text(b.timeAgo, style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 11)),
            ]),
          );
        })),
      ),
  ]);
}
