// What Zeno, the assistant, can do in the app - the app's side of the
// closed vocabulary in backend/api/domains/zeno_assistant/intents.py.
//
// Parsing is defensive in the same way the server's cleaning is: an action
// type this build doesn't know (a newer server), a NAVIGATE to a screen it
// has no route for, a CALL with nobody to call - each parses to null, and
// Zeno's reply is shown on its own. Unknown means "do nothing", never
// "guess".

/// One of the user's own conversations, as the server resolved "Jane" to it
/// (zeno_assistant/contacts.py). The ids are the user's own thread's - the
/// same ones their inbox shows.
class ZenoContact {
  const ZenoContact({
    required this.listingId,
    required this.listingName,
    required this.peerId,
    required this.peerName,
    required this.role,
    required this.buyerId,
  });

  final String listingId;
  final String listingName;
  final String peerId;
  final String peerName;

  /// The user's own side of the thread: "buyer" or "seller".
  final String role;
  final String buyerId;

  String get firstName {
    final n = peerName.trim();
    return n.isEmpty ? 'them' : n.split(RegExp(r'\s+')).first;
  }

  static ZenoContact? fromJson(Object? json) {
    if (json is! Map) return null;
    String? s(String k) => json[k] is String && (json[k] as String).isNotEmpty ? json[k] as String : null;
    final listingId = s('listing_id');
    final peerId = s('peer_id');
    final buyerId = s('buyer_id');
    final role = s('role');
    if (listingId == null || peerId == null || buyerId == null) return null;
    if (role != 'buyer' && role != 'seller') return null;
    return ZenoContact(
      listingId: listingId,
      listingName: s('listing_name') ?? '',
      peerId: peerId,
      peerName: s('peer_name') ?? '',
      role: role!,
      buyerId: buyerId,
    );
  }
}

enum ZenoActionType { navigate, search, findForMe, call, openChat }

/// Screen ids Zeno may open, with how Zeno names them. The routes live in
/// ZenoActionRunner; the list mirrors intents.DESTINATIONS.
const kZenoDestinations = <String, String>{
  'home': 'Home',
  'inbox': 'Inbox',
  'sell': 'Sell',
  'menu': 'Menu',
  'profile': 'Profile',
  'settings': 'Settings',
  'search': 'Search',
  'buying_agent': 'Buying Agent',
  'seller_dashboard': 'Seller dashboard',
  'deal_history': 'Your deals',
  'verify': 'Verification',
  'market_insights': 'Market insights',
  'how_broka_works': 'How BROKA works',
};

class ZenoAction {
  const ZenoAction({
    required this.type,
    this.destination,
    this.query,
    this.contactText,
    this.video = false,
    this.target,
    this.choices = const [],
    this.requiresConfirmation = false,
  });

  final ZenoActionType type;

  /// NAVIGATE: a key of [kZenoDestinations].
  final String? destination;

  /// SEARCH and FIND_FOR_ME.
  final String? query;

  /// CALL and OPEN_CHAT: who, as the user said it.
  final String? contactText;

  /// CALL: video rather than voice.
  final bool video;

  /// CALL and OPEN_CHAT: who it resolved to...
  final ZenoContact? target;

  /// ...or, when it fits more than one person, who it might be.
  final List<ZenoContact> choices;

  final bool requiresConfirmation;

  /// Happens on its own once Zeno has said so: opening a screen, a search,
  /// a chat. A call never does - it rings someone's phone - and neither does
  /// anything that still needs the user to say which person they meant.
  bool get runsByItself => type != ZenoActionType.call && choices.isEmpty && !requiresConfirmation;

  /// Picks one of [choices].
  ZenoAction choose(ZenoContact c) => ZenoAction(
        type: type,
        contactText: contactText,
        video: video,
        target: c,
        requiresConfirmation: type == ZenoActionType.call,
      );

  static ZenoAction? fromJson(Object? json) {
    if (json is! Map) return null;
    final type = switch (json['type']) {
      'NAVIGATE' => ZenoActionType.navigate,
      'SEARCH' => ZenoActionType.search,
      'FIND_FOR_ME' => ZenoActionType.findForMe,
      'CALL' => ZenoActionType.call,
      'OPEN_CHAT' => ZenoActionType.openChat,
      _ => null,
    };
    if (type == null) return null;

    String? text(String k) {
      final v = json[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    switch (type) {
      case ZenoActionType.navigate:
        final d = text('destination');
        if (d == null || !kZenoDestinations.containsKey(d)) return null;
        return ZenoAction(type: type, destination: d);
      case ZenoActionType.search:
      case ZenoActionType.findForMe:
        final q = text('query');
        return q == null ? null : ZenoAction(type: type, query: q);
      case ZenoActionType.call:
      case ZenoActionType.openChat:
        final target = ZenoContact.fromJson(json['target']);
        final choices = [
          for (final c in (json['choices'] as List? ?? const []))
            if (ZenoContact.fromJson(c) case final contact?) contact,
        ];
        if (target == null && choices.isEmpty) return null;
        return ZenoAction(
          type: type,
          contactText: text('contact'),
          video: json['call_type'] == 'video',
          target: target,
          choices: target == null ? choices : const [],
          // A call always asks first, whatever the server said.
          requiresConfirmation: type == ZenoActionType.call || json['requires_confirmation'] == true,
        );
    }
  }
}

/// One of Zeno's turns: what it says, and what it would do.
class ZenoTurnResult {
  const ZenoTurnResult({required this.reply, this.action});

  final String reply;
  final ZenoAction? action;

  factory ZenoTurnResult.fromJson(Map<String, dynamic> json) => ZenoTurnResult(
        reply: (json['reply'] as String? ?? '').trim(),
        action: ZenoAction.fromJson(json['action']),
      );
}
