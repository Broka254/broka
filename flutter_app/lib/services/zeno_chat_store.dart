// Zeno conversations, kept on the phone.
//
// Zeno's chat lived only in the screen's memory: close the app - or just go
// back to Home - and the conversation was gone, along with everything the
// Buying Agent had gathered (what you want, your budget, how many questions
// it had asked). Now each conversation is saved after every turn and comes
// back the next time Zeno opens, for 30 days after its last message.
//
// One conversation per account and per mode (the market assistant and the
// Buying Agent are different conversations), keyed by user id so another
// account signed in on the same phone never sees it.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

/// One bubble and anything attached to it (the Buying Agent's listings).
class ZenoStoredTurn {
  const ZenoStoredTurn({required this.role, required this.content, this.matches = const []});

  /// 'user' or 'broker' - Message.role's values.
  final String role;
  final String content;
  final List<Map<String, dynamic>> matches;

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (matches.isNotEmpty) 'matches': matches.map(_slim).toList(),
      };

  factory ZenoStoredTurn.fromJson(Map<String, dynamic> j) => ZenoStoredTurn(
        role: j['role'] as String? ?? 'broker',
        content: j['content'] as String? ?? '',
        matches: [
          for (final m in (j['matches'] as List? ?? const []))
            if (m is Map) m.cast<String, dynamic>(),
        ],
      );

  /// A listing as the card needs it, without inline images: a legacy photo
  /// is base64 and can run to megabytes, and SharedPreferences keeps every
  /// value in memory for the life of the app. Cards fall back to the
  /// listing's stored image URLs, which are kept.
  static Map<String, dynamic> _slim(Map<String, dynamic> listing) => {
        for (final e in listing.entries)
          if (!(e.value is String && (e.value as String).length > 4096)) e.key: e.value,
      };
}

class ZenoConversation {
  const ZenoConversation({
    required this.turns,
    required this.history,
    this.slots = const {},
    this.questionsAsked = 0,
    this.lastVerdict,
    this.watching = false,
    this.negotiationOpened = const {},
    required this.savedAt,
  });

  final List<ZenoStoredTurn> turns;

  /// What is sent to the server as context: {role: user|assistant, content}.
  final List<Map<String, String>> history;

  // Buying Agent state - what Zeno has gathered and where it got to.
  final Map<String, dynamic> slots;
  final int questionsAsked;
  final String? lastVerdict;
  final bool watching;
  final Set<String> negotiationOpened;

  final DateTime savedAt;

  /// Nothing but Zeno's greeting.
  bool get isEmpty => !turns.any((t) => t.role == 'user');

  Map<String, dynamic> toJson() => {
        'saved_at': savedAt.toUtc().toIso8601String(),
        'turns': turns.map((t) => t.toJson()).toList(),
        'history': history,
        'slots': slots,
        'questions_asked': questionsAsked,
        if (lastVerdict != null) 'last_verdict': lastVerdict,
        'watching': watching,
        'negotiation_opened': negotiationOpened.toList(),
      };

  factory ZenoConversation.fromJson(Map<String, dynamic> j) => ZenoConversation(
        savedAt: DateTime.tryParse(j['saved_at'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        turns: [
          for (final t in (j['turns'] as List? ?? const []))
            if (t is Map) ZenoStoredTurn.fromJson(t.cast<String, dynamic>()),
        ],
        history: [
          for (final h in (j['history'] as List? ?? const []))
            if (h is Map)
              {
                'role': h['role']?.toString() ?? 'user',
                'content': h['content']?.toString() ?? '',
              },
        ],
        slots: (j['slots'] as Map?)?.cast<String, dynamic>() ?? const {},
        questionsAsked: (j['questions_asked'] as num?)?.toInt() ?? 0,
        lastVerdict: j['last_verdict'] as String?,
        watching: j['watching'] as bool? ?? false,
        negotiationOpened: {
          for (final id in (j['negotiation_opened'] as List? ?? const [])) id.toString(),
        },
      );
}

class ZenoChatStore {
  ZenoChatStore._();

  /// A conversation left this long is not picked up again - the Buying
  /// Agent's budget and specs from a month ago are not what someone opening
  /// Zeno today is asking about.
  static const keepFor = Duration(days: 30);

  /// Bubbles kept per conversation. The server only ever reads the recent
  /// ones (see ZenoScreen._recentHistory); this bounds what the phone holds.
  static const maxTurns = 200;

  static String _key(String mode) =>
      'zeno_chat_v1:${ApiService.currentUserId ?? 'guest'}:$mode';

  /// The saved conversation for [mode], or null when there is none, it is
  /// too old, or it can't be read.
  static Future<ZenoConversation?> load(String mode, {DateTime? now}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(mode));
      if (raw == null || raw.isEmpty) return null;
      final convo = ZenoConversation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final age = (now ?? DateTime.now()).toUtc().difference(convo.savedAt);
      if (age > keepFor || convo.turns.isEmpty) {
        await prefs.remove(_key(mode));
        return null;
      }
      return convo;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String mode, ZenoConversation convo) async {
    try {
      final turns = convo.turns.length > maxTurns
          ? convo.turns.sublist(convo.turns.length - maxTurns)
          : convo.turns;
      final history = convo.history.length > maxTurns
          ? convo.history.sublist(convo.history.length - maxTurns)
          : convo.history;
      final trimmed = ZenoConversation(
        turns: turns,
        history: history,
        slots: convo.slots,
        questionsAsked: convo.questionsAsked,
        lastVerdict: convo.lastVerdict,
        watching: convo.watching,
        negotiationOpened: convo.negotiationOpened,
        savedAt: convo.savedAt,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(mode), jsonEncode(trimmed.toJson()));
    } catch (_) {}
  }

  static Future<void> clear(String mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(mode));
    } catch (_) {}
  }
}
