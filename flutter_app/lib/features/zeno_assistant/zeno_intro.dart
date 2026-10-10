// Zeno introducing itself to a new user - as a conversation (2026-10-10).
//
// The first thing a new account saw used to be a splash screen: Zeno's orb,
// a paragraph, four chips and "Show me around" / "Maybe later". It said what
// Zeno does; it did not show it, and it asked for nothing. This is Zeno
// talking with the user instead - bubbles that arrive after Zeno has
// thought about them, replies to tap - and it goes somewhere: how BROKA
// works, what Zeno can do, the Buying Agent at work (hunting and
// recommending), the watch that never sleeps - and then the case for
// Premium, which is what unlocks most of it. It ends wherever the user
// takes it: the plans, a real hunt with the Buying Agent, the tour of the
// app, or "maybe later".
//
// Scripted, like the tour (zeno_tour.dart): every line is here, so it costs
// no model call, reads the same on the hundredth sign-up as the first, and
// says only what BROKA does today (PRICING.md has what each plan holds; the
// prices themselves are read from GET /pricing/plans by the card that shows
// them, never typed into the app). Zeno introduces itself as the user's
// personal intelligent assistant - not a broker.
//
// This file is the conversation's state; zeno_intro_chat.dart draws it.
// ZenoTour runs it as the tour's welcome phase, so it is offered, held and
// ended exactly as the welcome was.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'zeno_tour.dart' show ZenoTourScript;

/// Where the introduction leads.
enum ZenoIntroOutcome {
  /// The plans.
  premium,

  /// A real hunt with the Buying Agent, for what the user said.
  tryAgent,

  /// The tour of the app's screens.
  tour,

  /// Not now.
  later,
}

/// What Zeno shows under a line, beyond words.
enum ZenoIntroCard {
  /// What Zeno can do, tile by tile.
  powers,

  /// The Buying Agent's radar at work.
  hunt,

  /// What Premium unlocks, and what it costs.
  premium,
}

/// A reply the user can tap.
@immutable
class ZenoIntroReply {
  const ZenoIntroReply(this.label, {this.next, this.outcome, this.then, this.primary = false});

  final String label;

  /// The beat it leads to.
  final String? next;

  /// Or where the conversation ends.
  final ZenoIntroOutcome? outcome;

  /// What Zeno says before it goes there.
  final String? then;

  /// Lit in Zeno's gradient: where Zeno would take the conversation.
  final bool primary;
}

/// One exchange: what Zeno says, then what the user can say back.
@immutable
class ZenoIntroBeat {
  const ZenoIntroBeat({
    required this.id,
    required this.lines,
    this.card,
    this.replies = const [],
    this.asks = false,
  });

  final String id;
  final List<String> lines;

  /// Shown with the last line.
  final ZenoIntroCard? card;
  final List<ZenoIntroReply> replies;

  /// Waits for something typed - what the user would love to buy.
  final bool asks;
}

/// A bubble in the conversation.
@immutable
class ZenoIntroMessage {
  const ZenoIntroMessage.zeno(this.text, {this.card}) : fromZeno = true;
  const ZenoIntroMessage.user(this.text)
      : fromZeno = false,
        card = null;

  final String text;
  final bool fromZeno;
  final ZenoIntroCard? card;
}

/// Every line of the introduction, in the user's language, and the words on
/// its cards.
@immutable
class ZenoIntroScript {
  const ZenoIntroScript({
    required this.language,
    required this.first,
    required this.beats,
    required this.powers,
    required this.huntCaptions,
    required this.premiumTitle,
    required this.premiumUnlocks,
    required this.freeNote,
    required this.askHint,
  });

  /// The BROKA language key the lines are written in.
  final String language;

  /// The beat it opens with.
  final String first;
  final Map<String, ZenoIntroBeat> beats;

  /// The powers card: (title, one line) each.
  final List<(String, String)> powers;

  /// What the hunt card's radar says it is doing, in turn.
  final List<String> huntCaptions;
  final String premiumTitle;
  final List<String> premiumUnlocks;
  final String freeNote;

  /// The placeholder of the "what would you love to buy?" field.
  final String askHint;

  /// Ideas for that answer, as chips - the tour's demo ideas.
  List<(String, String)> get ideas => ZenoTourScript.demoIdeas;

  /// Zeno's first line.
  String get opening => beats[first]!.lines.first;

  /// "From KES 199 a month - about KES 7 a day", from the cheapest plan.
  String priceLine(String plan, int monthly) {
    final daily = (monthly / 30).ceil();
    return language == 'swahili'
        ? '$plan kuanzia KES $monthly kwa mwezi - karibu KES $daily kwa siku'
        : '$plan from KES $monthly a month - about KES $daily a day';
  }

  /// Swahili for Swahili and Sheng speakers; English otherwise.
  static ZenoIntroScript forUser({String? firstName, String language = 'english'}) {
    final name = firstName?.trim() ?? '';
    final swahili = language == 'swahili' || language == 'sheng';
    String n(String withName, String without) => name.isEmpty ? without : withName.replaceAll('{name}', name);
    if (swahili) return _swahili(n);
    return _english(n);
  }

  static ZenoIntroScript _english(String Function(String, String) n) {
    const later = ZenoIntroReply('Maybe later', outcome: ZenoIntroOutcome.later);
    const tryIt = ZenoIntroReply('Let me try it', next: 'try');
    return ZenoIntroScript(
      language: 'english',
      first: 'hello',
      beats: {
        'hello': ZenoIntroBeat(id: 'hello', lines: [
          n("Hi {name}! 👋 I'm Zeno - your personal intelligent assistant.",
              "Hi! 👋 I'm Zeno - your personal intelligent assistant."),
          'BROKA is where Kenya buys and sells - phones, cars, homes, fashion, farm gear and more. '
              "I'm built into every corner of it, and I work for you.",
        ], replies: const [
          ZenoIntroReply('How does BROKA work?', next: 'how', primary: true),
          ZenoIntroReply('What can you do?', next: 'powers'),
          later,
        ]),
        'how': const ZenoIntroBeat(id: 'how', lines: [
          'Simple. Sellers post what they have, buyers find it - and you chat, call and agree a price, '
              'right here in BROKA.',
          "And you're never on your own: I'm in every deal, telling you whether a price is fair and "
              'flagging anything that looks off.',
        ], replies: [
          ZenoIntroReply('What can you do?', next: 'powers', primary: true),
          ZenoIntroReply("I'm here to sell", next: 'sell'),
        ]),
        'powers': const ZenoIntroBeat(id: 'powers', lines: [
          "Here's what I can do for you:",
        ], card: ZenoIntroCard.powers, replies: [
          ZenoIntroReply('Show me the Buying Agent', next: 'agent', primary: true),
          ZenoIntroReply('How does selling work?', next: 'sell'),
        ]),
        'sell': const ZenoIntroBeat(id: 'sell', lines: [
          "Selling? Snap one photo and I'll write the whole listing - the title, the specs buyers look "
              'for, a description that sells, even a price checked against the market.',
          'And when a buyer is waiting, I text you - even with the app closed - so you never lose a sale.',
        ], replies: [
          ZenoIntroReply('Show me the Buying Agent', next: 'agent', primary: true),
          ZenoIntroReply('What does it cost?', next: 'premium'),
        ]),
        'agent': const ZenoIntroBeat(id: 'agent', lines: [
          'Now my favourite trick 😎 - the Buying Agent.',
          'Tell me what you want the way you\'d tell a friend: "an iPhone 13 under 60K with a good '
              'battery". I ask a question or two, scan every listing on BROKA in seconds, and recommend '
              'the best deal - and I tell you honestly where each one falls short.',
        ], card: ZenoIntroCard.hunt, replies: [
          ZenoIntroReply("And if it isn't listed yet?", next: 'watch', primary: true),
          tryIt,
        ]),
        'watch': const ZenoIntroBeat(id: 'watch', lines: [
          'Then I keep watch. Day and night, every new listing is checked against what you asked for - '
              'and the moment one fits, you hear from me first.',
          "Everyone else is still scrolling. You're already talking to the seller. 😉",
        ], replies: [
          ZenoIntroReply('How do I get all this?', next: 'premium', primary: true),
          tryIt,
        ]),
        'premium': const ZenoIntroBeat(id: 'premium', lines: [
          "Here's the deal: chatting with me like this is free, always.",
          'Premium unlocks the rest of me - the watch that never sleeps, talking to me hands-free, '
              'listings written from your photos, a text the moment a buyer is waiting, and prices '
              'checked against the market.',
        ], card: ZenoIntroCard.premium, replies: [
          ZenoIntroReply('Unlock Premium ✨',
              outcome: ZenoIntroOutcome.premium, then: "Great choice - let's get you set up.", primary: true),
          ZenoIntroReply('Try the Buying Agent first', next: 'try'),
          ZenoIntroReply('Show me around the app', outcome: ZenoIntroOutcome.tour),
          later,
        ]),
        'try': const ZenoIntroBeat(id: 'try', lines: [
          "Go on then - tell me one thing you'd love to buy, and watch me hunt it down.",
        ], asks: true, replies: [
          ZenoIntroReply('Tell me about Premium', next: 'premium'),
          later,
        ]),
      },
      powers: const [
        ('Find anything', 'Describe it in your own words - I find it.'),
        ('Hunt & recommend', 'My Buying Agent scans all of BROKA and picks the best deal.'),
        ('Keep watch', "Not listed yet? I watch day and night and tell you first."),
        ('List from a photo', 'One photo, and I write the whole listing.'),
        ('Talk to me', 'Hands-free - I open screens, search and guide you.'),
        ('Fair prices', 'I tell you what a price is worth before you pay it.'),
      ],
      huntCaptions: const [
        'Reading your brief…',
        'Scanning every listing on BROKA…',
        'Ranking the closest matches…',
        'Recommending the best deal…',
      ],
      premiumTitle: 'BROKA Premium',
      premiumUnlocks: const [
        'Buying Agent watches that tell you first',
        'Voice mode - talk to Zeno hands-free',
        'Listings written from your photos',
        'A text the moment a buyer is waiting',
        'Prices checked against the market',
      ],
      freeNote: 'Chatting with Zeno stays free.',
      askHint: 'e.g. a phone under 20K',
    );
  }

  static ZenoIntroScript _swahili(String Function(String, String) n) {
    const later = ZenoIntroReply('Baadaye', outcome: ZenoIntroOutcome.later);
    const tryIt = ZenoIntroReply('Wacha nijaribu', next: 'try');
    return ZenoIntroScript(
      language: 'swahili',
      first: 'hello',
      beats: {
        'hello': ZenoIntroBeat(id: 'hello', lines: [
          n('Habari {name}! 👋 Mimi ni Zeno - msaidizi wako binafsi mwenye akili.',
              'Habari! 👋 Mimi ni Zeno - msaidizi wako binafsi mwenye akili.'),
          'BROKA ni mahali Kenya inanunua na kuuza - simu, magari, nyumba, mitindo, vifaa vya shamba na '
              'mengine mengi. Niko kila kona yake, na ninakufanyia kazi wewe.',
        ], replies: const [
          ZenoIntroReply('BROKA inafanyaje kazi?', next: 'how', primary: true),
          ZenoIntroReply('Unaweza kufanya nini?', next: 'powers'),
          later,
        ]),
        'how': const ZenoIntroBeat(id: 'how', lines: [
          'Ni rahisi. Wauzaji wanaweka walicho nacho, wanunuzi wanakipata - kisha mnaongea, mnapigiana '
              'simu na kukubaliana bei, hapa hapa BROKA.',
          'Na hauko peke yako: niko kwenye kila dili, nikikuambia kama bei ni ya haki na kukuonya '
              'chochote kinachoonekana si sawa.',
        ], replies: [
          ZenoIntroReply('Unaweza kufanya nini?', next: 'powers', primary: true),
          ZenoIntroReply('Nimekuja kuuza', next: 'sell'),
        ]),
        'powers': const ZenoIntroBeat(id: 'powers', lines: [
          'Haya ndiyo ninayoweza kukufanyia:',
        ], card: ZenoIntroCard.powers, replies: [
          ZenoIntroReply('Nionyeshe Wakala wa Kununua', next: 'agent', primary: true),
          ZenoIntroReply('Kuuza kunafanyaje kazi?', next: 'sell'),
        ]),
        'sell': const ZenoIntroBeat(id: 'sell', lines: [
          'Unauza? Piga picha moja nami nitaandika tangazo lote - jina, vipimo wanunuzi wanavyotafuta, '
              'maelezo yanayouza, hata bei iliyolinganishwa na soko.',
          'Na mnunuzi akikusubiri, nakutumia SMS - hata app ikiwa imefungwa - usipoteze mauzo.',
        ], replies: [
          ZenoIntroReply('Nionyeshe Wakala wa Kununua', next: 'agent', primary: true),
          ZenoIntroReply('Inagharimu kiasi gani?', next: 'premium'),
        ]),
        'agent': const ZenoIntroBeat(id: 'agent', lines: [
          'Sasa ujanja wangu ninaoupenda zaidi 😎 - Wakala wa Kununua.',
          'Niambie unachotaka kama unavyomwambia rafiki: "iPhone 13 chini ya 60K yenye betri nzuri". '
              'Nakuuliza swali moja au mawili, nachunguza kila tangazo BROKA kwa sekunde, na kukupendekezea '
              'dili bora - na nakuambia ukweli kila moja inapopungukiwa.',
        ], card: ZenoIntroCard.hunt, replies: [
          ZenoIntroReply('Na kama bado haipo?', next: 'watch', primary: true),
          tryIt,
        ]),
        'watch': const ZenoIntroBeat(id: 'watch', lines: [
          'Basi naendelea kuangalia. Mchana na usiku, kila tangazo jipya linalinganishwa na ulichoomba - '
              'na likifaa tu, unasikia kutoka kwangu kwanza.',
          'Wengine bado wanatafuta. Wewe tayari unaongea na muuzaji. 😉',
        ], replies: [
          ZenoIntroReply('Nitapataje haya yote?', next: 'premium', primary: true),
          tryIt,
        ]),
        'premium': const ZenoIntroBeat(id: 'premium', lines: [
          'Ukweli ni huu: kuongea nami hivi ni bure, kila wakati.',
          'Premium inafungua uwezo wangu wote - ulinzi usiolala, kuongea nami kwa sauti, matangazo '
              'yanayoandikwa kutoka kwenye picha zako, SMS mnunuzi akikusubiri, na bei zilizolinganishwa '
              'na soko.',
        ], card: ZenoIntroCard.premium, replies: [
          ZenoIntroReply('Fungua Premium ✨',
              outcome: ZenoIntroOutcome.premium, then: 'Chaguo zuri - twende tukuandalie.', primary: true),
          ZenoIntroReply('Nijaribu Wakala kwanza', next: 'try'),
          ZenoIntroReply('Nitembeze kwenye app', outcome: ZenoIntroOutcome.tour),
          later,
        ]),
        'try': const ZenoIntroBeat(id: 'try', lines: [
          'Haya basi - niambie kitu kimoja ungependa kununua, uone nikikiwinda.',
        ], asks: true, replies: [
          ZenoIntroReply('Niambie kuhusu Premium', next: 'premium'),
          later,
        ]),
      },
      powers: const [
        ('Pata chochote', 'Kieleze kwa maneno yako - nitakipata.'),
        ('Winda na pendekeza', 'Wakala wangu anachunguza BROKA yote na kuchagua dili bora.'),
        ('Ninaangalia', 'Bado hakipo? Naangalia mchana na usiku, nakuambia kwanza.'),
        ('Tangaza kwa picha', 'Picha moja, nami naandika tangazo lote.'),
        ('Ongea nami', 'Bila kugusa - nafungua kurasa, natafuta na kukuongoza.'),
        ('Bei za haki', 'Nakuambia thamani ya bei kabla hujalipa.'),
      ],
      huntCaptions: const [
        'Nasoma unachotaka…',
        'Nachunguza kila tangazo BROKA…',
        'Napanga zinazokaribia zaidi…',
        'Nakupendekezea dili bora…',
      ],
      premiumTitle: 'BROKA Premium',
      premiumUnlocks: const [
        'Wakala anayeangalia na kukuambia kwanza',
        'Ongea na Zeno kwa sauti',
        'Matangazo yanayoandikwa kutoka kwenye picha zako',
        'SMS mnunuzi akikusubiri',
        'Bei zilizolinganishwa na soko',
      ],
      freeNote: 'Kuongea na Zeno kunabaki bure.',
      askHint: 'mf. simu chini ya 20K',
    );
  }
}

/// The introduction as it runs: what has been said, whether Zeno is
/// thinking, and what the user can say back.
class ZenoIntro extends ChangeNotifier {
  ZenoIntro(
    this.script, {
    required this.say,
    required this.stopSaying,
    required this.onOutcome,
    this.pace = 1.0,
  });

  final ZenoIntroScript script;

  /// Reads Zeno's lines aloud; not waited on - the conversation moves at
  /// the pace of reading, and a voice that is muted or unavailable must
  /// not hold it up.
  final void Function(String text) say;
  final VoidCallback stopSaying;

  /// Where the user took it. [query] with tryAgent: what to hunt for.
  final void Function(ZenoIntroOutcome outcome, String? query) onOutcome;

  /// How long Zeno thinks and the user reads, as a multiple of the
  /// natural pace. Zero in tests that want every line at once.
  final double pace;

  final List<ZenoIntroMessage> _messages = [];
  final List<ZenoIntroMessage> _queue = [];
  List<ZenoIntroReply> _replies = const [];
  ZenoIntroBeat? _beat;
  bool _thinking = false;
  bool _done = false;
  int _epoch = 0;
  Timer? _timer;

  /// An ending waiting on Zeno's last line ("Great choice...").
  ({ZenoIntroOutcome outcome, String? query})? _ending;

  List<ZenoIntroMessage> get messages => List.unmodifiable(_messages);
  List<ZenoIntroReply> get replies => _replies;
  ZenoIntroBeat? get beat => _beat;
  bool get thinking => _thinking;
  bool get done => _done;

  /// Waiting for what the user would love to buy.
  bool get asking => !_done && !_thinking && _queue.isEmpty && (_beat?.asks ?? false);

  Duration _thinkFor(String line) =>
      Duration(milliseconds: ((500 + 9 * line.length).clamp(700, 1400) * pace).round());

  Duration _readFor(String line) =>
      Duration(milliseconds: ((300 + 45 * line.split(' ').length).clamp(700, 2800) * pace).round());

  void start() {
    if (_beat == null) _play(script.beats[script.first]!);
  }

  /// The user tapped [reply].
  void choose(ZenoIntroReply reply) {
    if (_done || !_replies.contains(reply)) return;
    stopSaying();
    _messages.add(ZenoIntroMessage.user(reply.label));
    _replies = const [];
    final outcome = reply.outcome;
    if (outcome != null) {
      _finish(outcome, null, then: reply.then);
      return;
    }
    final next = script.beats[reply.next];
    if (next == null) {
      notifyListeners();
      return;
    }
    _play(next);
  }

  /// "Yes" or "next", said: the reply Zeno would take.
  bool choosePrimary() {
    if (_replies.isEmpty) return false;
    choose(_replies.firstWhere((r) => r.primary, orElse: () => _replies.first));
    return true;
  }

  /// What the user would love to buy: the Buying Agent hunts it.
  bool submit(String query) {
    final q = query.trim();
    if (q.isEmpty || !asking) return false;
    stopSaying();
    _messages.add(ZenoIntroMessage.user(q));
    _finish(ZenoIntroOutcome.tryAgent, q);
    return true;
  }

  /// The app went to the background: everything this beat has to say is
  /// simply there when the user is back, and nothing more is said.
  void hold() {
    _timer?.cancel();
    stopSaying();
    _thinking = false;
    _messages.addAll(_queue);
    _queue.clear();
    final ending = _ending;
    if (ending != null) {
      _ending = null;
      onOutcome(ending.outcome, ending.query);
    } else if (!_done) {
      _replies = _beat?.replies ?? const [];
    }
    notifyListeners();
  }

  /// The conversation is over, wherever it was: nothing more is said.
  void stop() {
    _epoch++;
    _timer?.cancel();
    _ending = null;
    _done = true;
    _thinking = false;
    _replies = const [];
    stopSaying();
  }

  void _play(ZenoIntroBeat beat) {
    final epoch = ++_epoch;
    _timer?.cancel();
    _beat = beat;
    _replies = const [];
    _queue
      ..clear()
      ..addAll([
        for (var i = 0; i < beat.lines.length; i++)
          ZenoIntroMessage.zeno(beat.lines[i], card: i == beat.lines.length - 1 ? beat.card : null),
      ]);
    say(beat.lines.join(' '));
    _next(epoch);
  }

  /// Zeno thinks, says the next line, leaves it a moment to be read - and
  /// after the last one, offers the replies.
  void _next(int epoch) {
    if (epoch != _epoch) return;
    if (_queue.isEmpty) {
      _thinking = false;
      _replies = _beat?.replies ?? const [];
      notifyListeners();
      return;
    }
    final line = _queue.first;
    _thinking = true;
    notifyListeners();
    _timer = Timer(_thinkFor(line.text), () {
      if (epoch != _epoch) return;
      _queue.removeAt(0);
      _thinking = false;
      _messages.add(line);
      notifyListeners();
      _timer = Timer(_queue.isEmpty ? Duration.zero : _readFor(line.text), () => _next(epoch));
    });
  }

  void _finish(ZenoIntroOutcome outcome, String? query, {String? then}) {
    final epoch = ++_epoch;
    _timer?.cancel();
    _done = true;
    _replies = const [];
    if (then == null) {
      notifyListeners();
      onOutcome(outcome, query);
      return;
    }
    _ending = (outcome: outcome, query: query);
    _thinking = true;
    notifyListeners();
    _timer = Timer(_thinkFor(then), () {
      if (epoch != _epoch) return;
      _thinking = false;
      _messages.add(ZenoIntroMessage.zeno(then));
      notifyListeners();
      say(then);
      _timer = Timer(_thinkFor(then), () {
        if (epoch != _epoch || _ending == null) return;
        _ending = null;
        onOutcome(outcome, query);
      });
    });
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    super.dispose();
  }
}
