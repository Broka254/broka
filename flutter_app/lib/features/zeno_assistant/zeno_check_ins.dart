// What Zeno says when the user has gone quiet in voice mode (2026-10-09).
//
// The microphone used to stop after a minute of silence without a word:
// the full voice view folded into the pill, and whatever the user said
// next went nowhere. A person on the other end of a call doesn't hang up
// on a pause - they check: "are you still there?". So Zeno does, twice,
// and only then says it is stepping back (zeno_session.dart, _onQuiet).
//
// The lines are written here, not by a model: a check-in has to arrive on
// time, cost nothing, and still work when every AI provider is down. They
// vary - the same sentence every time reads as a timer going off, which is
// what it is - never twice in a row, and use the user's first name some of
// the time, as a person would. Swahili and Sheng speakers hear Swahili;
// everyone else hears English, which BROKA's English voice reads.
import 'dart:math' as math;

/// What the silence follows.
enum ZenoQuietMoment {
  /// Voice mode is open and nothing has been said yet.
  nothingYet,

  /// Zeno's last reply asked something.
  afterQuestion,

  /// Zeno answered and said nothing more.
  afterReply,

  /// Zeno opened a screen and is docked over it: the user is reading.
  browsing,
}

/// One thing to say, and the voice to say it in.
class ZenoLine {
  const ZenoLine(this.text, this.language);

  final String text;

  /// The BROKA language key BrokaTts reads [text] in.
  final String language;
}

class ZenoCheckIns {
  ZenoCheckIns({math.Random? random}) : _random = random ?? math.Random();

  final math.Random _random;
  String? _last;

  /// Swahili lines for these; English for every other language, whose
  /// replies come from the model.
  static const _swahiliSpeakers = {'swahili', 'sheng'};

  // {name} lines are only used when the name is known.
  static const _en = <String, List<String>>{
    'nothingYet': [
      "I'm listening - what can I do for you?",
      "{name}, I'm all ears. Ask me anything, or tell me what you're looking for.",
      "Not sure where to start? Try \"find me a phone under 20K\".",
      'Take your time. I can find something for you, open a screen, or explain how BROKA works.',
    ],
    'afterQuestion': [
      "No rush - I'm still waiting on your answer.",
      '{name}, should I carry on?',
      'Want me to go ahead?',
      "Take your time. Just tell me when you've decided.",
    ],
    'afterReply': [
      'Anything else I can help with?',
      '{name}, should I continue, or is there something else?',
      'What would you like to do next?',
      "I'm still here if you need anything.",
    ],
    'browsing': [
      "Take your time looking around. I'm right here if you need me.",
      'Found anything you like, {name}? I can help you narrow it down.',
      'Just say the word if you want me to look for something else.',
    ],
    'stillThere': [
      'Hey, are you still there?',
      'Are you still there, {name}?',
      'Still with me? Just say the word.',
      "{name}? I'm here whenever you're ready.",
    ],
    'resting': [
      "I'll step back for now. Tap me whenever you need me.",
      "Okay {name}, I'll go quiet. Tap me when you're ready.",
      "I'll go quiet to save your data. Tap me to talk again.",
    ],
  };

  static const _sw = <String, List<String>>{
    'nothingYet': [
      'Nakusikiliza - nikusaidie na nini?',
      '{name}, niko tayari. Niulize chochote, au niambie unachotafuta.',
      'Chukua muda wako. Naweza kukutafutia kitu, kufungua ukurasa, au kukueleza BROKA inavyofanya kazi.',
    ],
    'afterQuestion': [
      'Hakuna haraka - bado nasubiri jibu lako.',
      '{name}, niendelee?',
      'Niendelee nalo?',
    ],
    'afterReply': [
      'Kuna kingine nikusaidie?',
      '{name}, niendelee, au kuna kitu kingine?',
      'Ungependa tufanye nini sasa?',
    ],
    'browsing': [
      'Chukua muda wako kuangalia. Niko hapa ukinihitaji.',
      '{name}, umeona kitu unachopenda? Naweza kukusaidia kuchagua.',
    ],
    'stillThere': [
      'Bado uko hapo?',
      'Bado uko hapo, {name}?',
      'Niko hapa ukiwa tayari.',
    ],
    'resting': [
      'Nitanyamaza kwa sasa. Niguse ukinihitaji.',
      'Sawa {name}, nitapumzika. Niguse ukiwa tayari.',
    ],
  };

  /// The [nudge]th check-in (0 first) after [moment]. The second one, in
  /// any moment, asks whether the user is still there.
  ZenoLine checkIn(ZenoQuietMoment moment,
          {required int nudge, String? firstName, String language = 'english'}) =>
      _pick(nudge == 0 ? moment.name : 'stillThere', firstName, language);

  /// What Zeno says as it stops listening.
  ZenoLine resting({String? firstName, String language = 'english'}) =>
      _pick('resting', firstName, language);

  ZenoLine _pick(String key, String? firstName, String language) {
    final swahili = _swahiliSpeakers.contains(language);
    final bank = (swahili ? _sw : _en)[key]!;
    final name = firstName?.trim() ?? '';
    final usable = [
      for (final l in bank)
        if (name.isNotEmpty || !l.contains('{name}')) l.replaceAll('{name}', name),
    ];
    final fresh = [for (final l in usable) if (l != _last) l];
    final options = fresh.isEmpty ? usable : fresh;
    final line = options[_random.nextInt(options.length)];
    _last = line;
    return ZenoLine(line, swahili ? 'swahili' : 'english');
  }

  /// The moment Zeno's last reply leaves the user in.
  static ZenoQuietMoment momentAfter(String? lastReply, {required bool docked}) {
    if (docked) return ZenoQuietMoment.browsing;
    final reply = lastReply?.trim() ?? '';
    if (reply.isEmpty) return ZenoQuietMoment.nothingYet;
    return reply.endsWith('?') ? ZenoQuietMoment.afterQuestion : ZenoQuietMoment.afterReply;
  }
}
