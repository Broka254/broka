// BROKA - Domain Models (MatchResult, Message, Bid)
// NOTE: Listing model lives in listing.dart
import 'listing.dart';

// ── MatchResult ───────────────────────────────────────────────────────────────

class MatchResult {
  final String buyerId;
  final String buyerName;
  final double score;
  final double distanceKm;
  final double priceGap;

  const MatchResult({
    required this.buyerId,
    required this.buyerName,
    required this.score,
    required this.distanceKm,
    required this.priceGap,
  });

  factory MatchResult.fromJson(Map<String, dynamic> j) => MatchResult(
        buyerId:    j['buyer_id']     as String,
        buyerName:  j['buyer_name']   as String,
        score:      (j['score']       as num).toDouble(),
        distanceKm: (j['distance_km'] as num).toDouble(),
        priceGap:   (j['price_gap']   as num).toDouble(),
      );

  String get initials =>
      buyerName.trim().split(' ').map((w) => w.isEmpty ? '' : w[0]).take(2).join().toUpperCase();
}

// ── Message ───────────────────────────────────────────────────────────────────

class Message {
  final String role;    // "seller" | "buyer" | "broker"
  final String content;
  final int?   dealProbability; // 0-100, from broker sentiment analysis
  // viaAi: true when this message was sent through the AI broker route.
  // Used to filter AI-mode messages out of the direct-chat view.
  final bool   viaAi;
  final String id;
  final String msgType;     // "text" | "voice" | "image" | "call"
  final String? mediaUrl;
  final int?    durationSecs;
  final String? callType;   // "audio" | "video" - set when msgType == "call"
  final DateTime? createdAt;
  final bool timerOffer;
  // True only when this broker reply is the sender agreeing to switch to
  // direct chat right after Zeno offered it - the screen navigates to
  // /direct-chat when it sees this, so users who don't know that screen
  // exists can just say "yes" instead of finding a header button.
  final bool suggestDirectChat;

  /// Structured action Zeno is OFFERING — never one it has taken.
  ///
  /// Shape: {action, label, parameters, requires_confirmation, draft_text}.
  /// `action` is one of SWITCH_TO_DIRECT_CHAT | START_AUDIO_CALL |
  /// START_VIDEO_CALL | DRAFT_SMS. Null when Zeno isn't proposing anything.
  ///
  /// The client MUST render this as something the user taps, never act on
  /// it automatically: the other party's messages are in Zeno's context,
  /// so auto-execution would let one party trigger a call or an SMS on the
  /// other party's device by typing an instruction. See the backend's
  /// api/core/negotiation_actions.py.
  ///
  /// `suggestDirectChat` above is the older single-purpose flag, still
  /// populated from the same decision so the two can never disagree.
  final Map<String, dynamic>? zenoAction;
  // True when this message opened the thread on the buyer's behalf via a
  // standing Buy-Agent request, not the buyer's own initiative - renders
  // a disclosure label above the bubble (Design Journal Volume 6, Ch.22).
  final bool isAgentInitiated;
  // On the viewer's own direct-chat messages: the id their app gave the
  // message before sending it, so the chat can match the copy it already
  // shows (backend NegotiationMessage.client_msg_id).
  final String? clientMsgId;

  const Message({
    required this.role,
    required this.content,
    this.dealProbability,
    this.viaAi = false,
    this.id = '',
    this.msgType = 'text',
    this.mediaUrl,
    this.durationSecs,
    this.callType,
    this.createdAt,
    this.timerOffer = false,
    this.suggestDirectChat = false,
    this.zenoAction,
    this.isAgentInitiated = false,
    this.clientMsgId,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    role:            j['role']             as String,
    content:         j['content']          as String,
    dealProbability: j['deal_probability'] as int?,
    viaAi:           (j['via_ai']          as bool?) ?? false,
    id:              j['id']               as String? ?? '',
    timerOffer:      (j['timer_offer']     as bool?) ?? false,
    msgType:         j['msg_type']         as String? ?? 'text',
    mediaUrl:        j['media_url']        as String?,
    durationSecs:    j['duration_secs']    as int?,
    callType:        j['call_type']        as String?,
    suggestDirectChat: (j['suggest_direct_chat'] as bool?) ?? false,
    zenoAction: (j['zeno_action'] as Map?)?.cast<String, dynamic>(),
    isAgentInitiated: (j['is_agent_initiated'] as bool?) ?? false,
    clientMsgId:     j['client_msg_id']    as String?,
    createdAt:       j['created_at'] != null
        ? DateTime.tryParse(j['created_at'] as String)
        : null,
  );

  bool get isBroker => role == 'broker';
  bool get isSeller => role == 'seller';
  bool get isBuyer  => role == 'buyer';

  /// Mirrors fromJson's field names so a round-trip through local on-device
  /// storage (LocalChatStore) reproduces the same message.
  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    'deal_probability': dealProbability,
    'via_ai': viaAi,
    'id': id,
    'timer_offer': timerOffer,
    'msg_type': msgType,
    'media_url': mediaUrl,
    'duration_secs': durationSecs,
    'call_type': callType,
    'created_at': createdAt?.toIso8601String(),
    'client_msg_id': clientMsgId,
  };
}

// ── Shopping Advisor (Design Journal Volume 6, Ch.29) ───────────────────────
// A plain Message can't carry both the AI's reply text and the shortlist
// it was ranking, so this is a small dedicated response type rather than
// overloading Message with an optional shortlist field only this one
// caller would ever populate.
class ShoppingAdvisorResult {
  final Message reply;
  final List<Listing> shortlist;
  ShoppingAdvisorResult({required this.reply, required this.shortlist});

  factory ShoppingAdvisorResult.fromJson(Map<String, dynamic> j) => ShoppingAdvisorResult(
    reply: Message.fromJson({'role': j['role'] ?? 'advisor', 'content': j['content'] ?? ''}),
    shortlist: (j['shortlist'] as List? ?? [])
        .map((e) => Listing.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

// ── Bid ───────────────────────────────────────────────────────────────────────

class Bid {
  final int    rank;
  final String bidderName;
  final double amount;
  final String timeAgo;

  const Bid({
    required this.rank,
    required this.bidderName,
    required this.amount,
    required this.timeAgo,
  });

  factory Bid.fromJson(Map<String, dynamic> j) => Bid(
        rank:       (j['rank']        as num).toInt(),
        bidderName: j['bidder_name']  as String,
        amount:     (j['amount']      as num).toDouble(),
        timeAgo:    j['time_ago']     as String,
      );

  String get formattedAmount => fmt(amount);

  static String fmt(double v) =>
      'KES ${v.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';}
