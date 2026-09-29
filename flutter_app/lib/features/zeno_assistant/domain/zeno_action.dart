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

enum ZenoActionType { navigate, search, findForMe, call, openChat, guide }

/// One step of a guide, and the screen where it is done, if there is one.
class ZenoGuideStep {
  const ZenoGuideStep({required this.title, this.detail = '', this.destination});

  final String title;
  final String detail;

  /// A key of [kZenoDestinations]; null for a step with nowhere to go.
  final String? destination;
}

/// "How do I open a store?", answered: steps built on the server from the
/// user's own account (zeno_assistant/guides.py), each with a button to
/// the screen where it is done. Nothing in it is the model's.
class ZenoGuide {
  const ZenoGuide({required this.id, required this.title, this.intro = '', required this.steps});

  final String id;
  final String title;
  final String intro;
  final List<ZenoGuideStep> steps;

  static ZenoGuide? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final title = json['title'];
    if (id is! String || title is! String || title.trim().isEmpty) return null;
    final steps = <ZenoGuideStep>[
      for (final s in (json['steps'] as List? ?? const []))
        if (s is Map && s['title'] is String && (s['title'] as String).trim().isNotEmpty)
          ZenoGuideStep(
            title: (s['title'] as String).trim(),
            detail: s['detail'] is String ? (s['detail'] as String).trim() : '',
            // A screen this build has no route for is a step without a
            // button, not a button that does nothing.
            destination: kZenoDestinations.containsKey(s['destination']) ? s['destination'] as String : null,
          ),
    ];
    if (steps.isEmpty) return null;
    return ZenoGuide(id: id, title: title.trim(), intro: json['intro'] is String ? (json['intro'] as String).trim() : '', steps: steps);
  }
}

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
  'store_setup': 'Store setup',
  'my_store': 'Your store',
  'start_selling': 'Start selling',
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
    this.guide,
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

  /// GUIDE: the steps.
  final ZenoGuide? guide;

  /// Happens on its own once Zeno has said so: opening a screen, a search,
  /// a chat. A call never does - it rings someone's phone - and neither does
  /// anything that still needs the user to say which person they meant.
  /// A guide is read, not run: its steps go somewhere when the user taps
  /// them. Nor does a search Zeno offers about a listing ([isOffer]).
  bool get runsByItself =>
      type != ZenoActionType.call && type != ZenoActionType.guide && choices.isEmpty && !requiresConfirmation;

  /// A search Zeno offers and waits on: "this one has 4GB - want me to look
  /// for 8GB laptops?", with a button.
  bool get isOffer =>
      requiresConfirmation && (type == ZenoActionType.search || type == ZenoActionType.findForMe);

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
      'GUIDE' => ZenoActionType.guide,
      _ => null,
    };
    if (type == null) return null;

    String? text(String k) {
      final v = json[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    switch (type) {
      case ZenoActionType.guide:
        final guide = ZenoGuide.fromJson(json['guide_content']);
        return guide == null ? null : ZenoAction(type: type, guide: guide);
      case ZenoActionType.navigate:
        final d = text('destination');
        if (d == null || !kZenoDestinations.containsKey(d)) return null;
        return ZenoAction(type: type, destination: d);
      case ZenoActionType.search:
      case ZenoActionType.findForMe:
        final q = text('query');
        // Offered rather than run when Zeno came up with it while answering
        // about a listing (zeno_assistant/service.py): the buyer taps it.
        return q == null
            ? null
            : ZenoAction(type: type, query: q, requiresConfirmation: json['requires_confirmation'] == true);
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
