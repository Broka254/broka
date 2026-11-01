// Direct-chat and Zeno reliability: replies, cached identity, merge.
//
// Pure unit tests (no pumps): each fails on the old implementation, where
// ChatMessage had no reply fields, the cache had no header helper, and the
// Zeno screen replaced its transcript with a greeting on an empty answer.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/models/models.dart';
import 'package:broka/screens/negotiate_screen.dart' show mergeZenoThreads;
import 'package:broka/screens/negotiation_screen.dart' show ChatMessage;
import 'package:broka/services/counterparty_profile_cache.dart';

void main() {
  group('quote-reply labels', () {
    test('deleted original renders safely', () {
      expect(
        ChatMessage.replyLabel(const {'deleted': true, 'label': 'Gone'}),
        'Message deleted',
      );
    });

    test('media originals are labelled, never leaked', () {
      expect(
        ChatMessage.replyLabel(
            const {'msg_type': 'image', 'deleted': false}),
        'Photo',
      );
      expect(
        ChatMessage.replyLabel(
            const {'msg_type': 'voice', 'deleted': false}),
        'Voice message',
      );
    });

    test('long text is clipped', () {
      final label = ChatMessage.replyLabel(
          {'preview': 'x' * 200, 'deleted': false});
      expect(label.length, lessThanOrEqualTo(81));
      expect(label.endsWith('…'), isTrue);
    });

    test('missing preview falls back without crashing', () {
      expect(ChatMessage.replyLabel(null), 'Message');
    });
  });

  group('reply metadata survives the offline cache', () {
    test('ChatMessage round-trips reply fields through JSON', () {
      const original = ChatMessage(
        role: 'buyer',
        content: 'Is it available?',
        id: 'm1',
      );
      const reply = ChatMessage(
        role: 'seller',
        content: 'Yes',
        id: 'm2',
        replyToMessageId: 'm1',
        replyPreview: {
          'message_id': 'm1',
          'sender_role': 'buyer',
          'msg_type': 'text',
          'preview': 'Is it available?',
          'deleted': false,
        },
      );
      final restored = ChatMessage.fromJson(reply.toJson());
      expect(restored.replyToMessageId, 'm1');
      expect(restored.replyPreview?['preview'], 'Is it available?');
      expect(restored.replyPreview?['deleted'], isFalse);
      expect(original.replyToMessageId, isNull);
    });

    test('Message round-trips reply fields through JSON', () {
      const m = Message(
        role: 'seller',
        content: 'Yes',
        id: 'm2',
        replyToMessageId: 'm1',
        replyPreview: {
          'message_id': 'm1',
          'sender_role': 'buyer',
          'preview': 'Is it available?',
        },
      );
      final restored = Message.fromJson(m.toJson());
      expect(restored.replyToMessageId, 'm1');
      expect(restored.replyPreview?['preview'], 'Is it available?');
    });
  });

  group('cached counterparty identity', () {
    test('header from cache keeps identity but never shows stale online',
        () async {
      SharedPreferences.setMockInitialValues({});
      const profile = CounterpartyProfile(
        userId: 'seller-9',
        name: 'Arnold',
        photo: 'aGVsbG8=',
        lastSeenLabel: 'Last seen yesterday',
      );
      await CounterpartyProfileCache.save('buyer-1', profile);
      final loaded =
          await CounterpartyProfileCache.load('buyer-1', 'seller-9');
      expect(loaded?.name, 'Arnold');
      final header = CounterpartyProfileCache.headerFromCache(loaded!);
      expect(header['name'], 'Arnold');
      expect(header['profile_photo'], 'aGVsbG8=');
      // The honesty rule: cached presence is never current.
      expect(header['is_online'], isFalse);
    });

    test('different viewer/counterparty pairs do not share a cache slot',
        () async {
      SharedPreferences.setMockInitialValues({});
      await CounterpartyProfileCache.save(
          'buyer-1',
          const CounterpartyProfile(userId: 'seller-9', name: 'Arnold'));
      final other =
          await CounterpartyProfileCache.load('buyer-2', 'seller-9');
      expect(other, isNull);
    });
  });

  group('Zeno history reconciliation', () {
    test('empty server answer preserves the local transcript', () {
      const local = [
        Message(role: 'broker', content: 'Hello', id: 'g1'),
        Message(role: 'buyer', content: 'Hi Zeno', id: 'u1', viaAi: true),
      ];
      final merged = mergeZenoThreads(const [], local);
      expect(merged.map((m) => m.id), ['g1', 'u1']);
    });

    test('overlapping server and cache rows appear once', () {
      const cached = [
        Message(role: 'broker', content: 'Hello', id: 'g1'),
        Message(role: 'buyer', content: 'Hi Zeno', id: 'u1', viaAi: true),
      ];
      const server = [
        Message(role: 'broker', content: 'Hello', id: 'g1'),
        Message(role: 'buyer', content: 'Hi Zeno', id: 'u1', viaAi: true),
        Message(role: 'broker', content: 'Tell me more', id: 'g2'),
      ];
      final merged = mergeZenoThreads(server, cached);
      expect(merged.map((m) => m.id).toList(), ['g1', 'u1', 'g2']);
    });

    test('unsent local bubbles survive the merge', () {
      const server = [
        Message(role: 'broker', content: 'Hello', id: 'g1'),
      ];
      const local = [
        Message(role: 'broker', content: 'Hello', id: 'g1'),
        Message(role: 'buyer', content: 'typing…'),
      ];
      final merged = mergeZenoThreads(server, local);
      expect(merged.length, 2);
      expect(merged.last.content, 'typing…');
    });

    test('two empty threads stay empty so the caller can greet', () {
      expect(mergeZenoThreads(const [], const []), isEmpty);
    });
  });
}
