// How Zeno asks "should I SMS you when a buyer shows up?" on the sell
// wizard's last step.
//
// The same sentence on every listing reads as a form field wearing a robot
// costume; a seller who lists every week stops reading it. So there are
// several phrasings and several greetings, chosen at random each time -
// and never the question the seller saw on their previous listing.
//
// Every phrasing asks the same thing, and none promises more than the SMS
// does: a text when a buyer has messaged about the listing and the seller
// hasn't replied (the availability nudge, api/core/workers.py - once per
// buyer, never at night; the answer cards spell that out).
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class ZenoSmsPrompts {
  ZenoSmsPrompts._();

  /// `{greet}` is a greeting, `{item}` the listing ("Dry maize" in quotes,
  /// or "your listing"), `{Item}` the same at the start of a sentence.
  static const questions = <String>[
    "{greet} 👋 I'll look after buyers for {item}. When one shows up and you haven't replied yet, should I send you an SMS?",
    "{greet} {Item} is almost live. If a buyer messages while you're away from the app, want me to text you?",
    "{greet} Quick one before we go live: should I SMS you when someone asks about {item} and you haven't answered yet?",
    "{greet} I'll keep an eye out for buyers of {item}. Shall I drop you a text if one reaches out while you're offline?",
    "{greet} Buyers don't like waiting ⏳ If one asks about {item} and you haven't seen it, can I text you?",
    "{greet} Want a heads-up by SMS when a buyer shows interest in {item} and you haven't replied?",
    "{greet} Last thing before you go live! If a buyer contacts you about {item} and gets no reply, should I send you a text?",
    "{greet} I can nudge you with an SMS whenever a buyer is waiting on you about {item}. Should I?",
    "{greet} So you never miss a sale 💰 If a buyer messages about {item} and you're not around, may I text your phone?",
    "{greet} I'll be in the chat with buyers for {item}. If one is waiting on your reply, should I send you a quick SMS?",
  ];

  static const _greetings = ['Hi', 'Hey', 'Habari', 'Sasa', 'Hello'];

  static const _lastKey = 'zeno_sms_prompt_last';

  /// A question for [itemName] (null or empty: "your listing"), greeting
  /// [sellerName] by first name when there is one. Never the question the
  /// seller was asked last time; which one it was is remembered on the
  /// phone. [random] is for tests.
  static Future<String> next({String? sellerName, String? itemName, Random? random}) async {
    final rnd = random ?? Random();
    int? last;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      last = prefs.getInt(_lastKey);
    } catch (_) {}
    var index = rnd.nextInt(questions.length);
    if (index == last) index = (index + 1 + rnd.nextInt(questions.length - 1)) % questions.length;
    try {
      await prefs?.setInt(_lastKey, index);
    } catch (_) {}
    return compose(index, rnd.nextInt(_greetings.length),
        sellerName: sellerName, itemName: itemName);
  }

  static String compose(int question, int greeting, {String? sellerName, String? itemName}) {
    final first = (sellerName ?? '').trim().split(RegExp(r'\s+')).first;
    final greet = first.isEmpty
        ? '${_greetings[greeting % _greetings.length]}!'
        : '${_greetings[greeting % _greetings.length]} $first!';
    final name = (itemName ?? '').trim();
    final item = name.isEmpty ? 'your listing' : '"$name"';
    final capital = name.isEmpty ? 'Your listing' : item;
    return questions[question % questions.length]
        .replaceAll('{greet}', greet)
        .replaceAll('{Item}', capital)
        .replaceAll('{item}', item);
  }
}
