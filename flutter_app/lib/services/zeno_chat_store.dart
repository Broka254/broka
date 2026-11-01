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
// account signed in on the same phone never sees it. Questions about a
// listing are a third, and remember which listing: coming back to the same
// one picks the conversation up, opening Zeno from another starts afresh.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

/// New client-side turn ids. Timestamp plus randomness: unique across
/// retries (each attempt gets its own), stable within one attempt so the
/// server can recognise a replay.
String newClientTurnId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rand = _turnRandom.nextInt(1 << 32);
  return 't${now.toRadixString(36)}${rand.toRadixString(36)}';
}

final _turnRandom = math.Random();

/// One bubble and anything attached to it (the Buying Agent's listings).
class ZenoStoredTurn {
  const ZenoStoredTurn({
    required this.role,
    required this.content,
    this.matches = const [],
    this.clientTurnId,
  });

  /// 'user' or 'broker' - Message.role's values.
  final String role;
  final String content;
  final List<Map<String, dynamic>> matches;

  /// The id the server stored this turn under. Survives the local save so
  /// a second device syncing the same queued turn is a no-op, and a restore
  /// can tell "already on the server" from "typed while offline".
  final String? clientTurnId;

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (matches.isNotEmpty) 'matches': matches.map(_slim).toList(),
        if (clientTurnId != null) 'client_turn_id': clientTurnId,
      };

  factory ZenoStoredTurn.fromJson(Map<String, dynamic> j) => ZenoStoredTurn(
        role: j['role'] as String? ?? 'broker',
        content: j['content'] as String? ?? '',
        matches: [
          for (final m in (j['matches'] as List? ?? const []))
            if (m is Map) m.cast<String, dynamic>(),
        ],
        clientTurnId: j['client_turn_id'] as String?,
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
    this.aboutListing,
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

  /// The id of the listing this conversation is about, if it is one.
  final String? aboutListing;

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
        if (aboutListing != null) 'about_listing': aboutListing,
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
        aboutListing: j['about_listing'] as String?,
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
        aboutListing: convo.aboutListing,
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

  /// Merge the server's durable turns with the local cache, then upload
  /// anything typed while offline. Matching is by client turn id first and
  /// role+content second, so a turn synced earlier is recognised even after
  /// the app restarted - the union can never duplicate it, and a longer
  /// server transcript is never truncated by a shorter local one: server
  /// turns keep their order, local-only turns append after them.
  /// Returns the merged conversation, or the local one when the server
  /// can't be reached or has nothing and the cache is also empty.
  static Future<ZenoConversation?> restoreFromServer(
    String mode, {
    String? listingId,
  }) async {
    final local = await load(mode);
    final effectiveListing = listingId ?? local?.aboutListing;
    List<Map<String, dynamic>> remote;
    try {
      remote = await ApiService.getAssistantConversation(
          mode: mode, listingId: effectiveListing);
    } catch (_) {
      return local;
    }
    if (remote.isEmpty) {
      // Nothing durable yet: push the local transcript up so a second
      // device sees it, then keep showing the local copy.
      if (local != null && !local.isEmpty) {
        unawaited(_uploadMissing(mode, effectiveListing, local,
            [for (var i = 0; i < local.turns.length; i++) i], const {}));
      }
      return local;
    }
    final remoteIds = <String>{
      for (final t in remote)
        if ((t['client_turn_id']?.toString() ?? '').isNotEmpty)
          t['client_turn_id'].toString(),
    };
    final remoteTexts = <String>{
      for (final t in remote) "${t['role']}|${(t['content'] ?? '').toString()}",
    };
    final turns = <ZenoStoredTurn>[
      for (final t in remote)
        ZenoStoredTurn(
          role: t['role'] == 'user' ? 'user' : 'broker',
          content: (t['content'] ?? '').toString(),
          clientTurnId: (t['client_turn_id']?.toString() ?? '').isEmpty
              ? null
              : t['client_turn_id'].toString(),
        ),
    ];
    final missing = <int>[];
    if (local != null) {
      for (final t in local.turns) {
        final id = t.clientTurnId;
        // Either key proves the server already holds this turn: a stored
        // client id from an earlier sync, or the same role+content (an
        // older save that predates ids, or a reply whose server copy got a
        // different id). Only a turn matching neither is genuinely missing.
        if (id != null && id.isNotEmpty && remoteIds.contains(id)) continue;
        if (remoteTexts.contains('${t.role == 'user' ? 'user' : 'assistant'}|${t.content}')) {
          continue;
        }
        turns.add(t);
        missing.add(turns.length - 1);
      }
    }
    if (turns.isEmpty) return local;
    // Trim oldest first; missing indices shift with the trim.
    final drop = turns.length > maxTurns ? turns.length - maxTurns : 0;
    final visible = drop > 0 ? turns.sublist(drop) : turns;
    final missingVisible = [
      for (final m in missing) m - drop,
    ].where((m) => m >= 0).toList();
    final merged = ZenoConversation(
      turns: visible,
      history: [
        for (final t in visible)
          {'role': t.role == 'user' ? 'user' : 'assistant', 'content': t.content},
      ],
      slots: local?.slots ?? const {},
      questionsAsked: local?.questionsAsked ?? 0,
      lastVerdict: local?.lastVerdict,
      watching: local?.watching ?? false,
      negotiationOpened: local?.negotiationOpened ?? {},
      aboutListing: effectiveListing,
      savedAt: DateTime.now().toUtc(),
    );
    await save(mode, merged);
    if (missingVisible.isNotEmpty) {
      // Typed while offline: the server never saw these. Best-effort, with
      // the stored client ids, so a half-finished earlier sync can't dup.
      unawaited(_uploadMissing(mode, effectiveListing, merged, missingVisible, remoteIds));
    }
    return merged;
  }

  /// Best-effort upload of local-only turns. Each carries its stored client
  /// id (minting one when an old save predates ids), so retries and second
  /// devices converge instead of duplicating. Minted ids are written back
  /// into the saved conversation: without that, every restore would upload
  /// the same turn again under a fresh id.
  static Future<void> _uploadMissing(
    String mode,
    String? listingId,
    ZenoConversation merged,
    List<int> missing,
    Set<String> alreadyThere,
  ) async {
    var changed = false;
    for (final i in missing.take(50)) {
      final t = merged.turns[i];
      final id = (t.clientTurnId?.isNotEmpty == true)
          ? t.clientTurnId!
          : newClientTurnId();
      if (alreadyThere.contains(id)) continue;
      try {
        final ok = await ApiService.appendAssistantTurn(
          mode: mode,
          listingId: listingId,
          role: t.role == 'user' ? 'user' : 'assistant',
          content: t.content,
          clientTurnId: id,
        );
        if (!ok) return; // offline again: the next restore retries the rest
        if (t.clientTurnId != id) {
          merged.turns[i] = ZenoStoredTurn(
            role: t.role,
            content: t.content,
            matches: t.matches,
            clientTurnId: id,
          );
          changed = true;
        }
      } catch (_) {
        return; // offline again: the next restore retries the rest
      }
    }
    if (changed) await save(mode, merged);
  }

  /// Best-effort sync of one turn to the server. Local save always happens
  /// first (callers do that); a failed sync keeps the local copy.
  static Future<void> syncTurn(
    String mode, {
    String? listingId,
    required String role,
    required String content,
    String? clientTurnId,
  }) async {
    try {
      await ApiService.appendAssistantTurn(
        mode: mode,
        listingId: listingId,
        role: role,
        content: content,
        clientTurnId: clientTurnId,
      );
    } catch (_) {}
  }
}
