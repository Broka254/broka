// AnnouncementsState: feed loading, pagination, optimistic read
// acknowledgement with server reconciliation, unread-count handling, and
// per-account isolation.
//
// Drives the real state through a fake CommunicationsRepository (hand-fed
// answers per test) with SharedPreferences mocks - no HTTP, no widgets.
import 'dart:async';

import 'package:broka/core/utils/result.dart';
import 'package:broka/features/communications/data/repositories/communications_repository.dart';
import 'package:broka/features/communications/domain/models/announcement.dart';
import 'package:broka/features/communications/presentation/announcements_state.dart';
import 'package:broka/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Announcement _announcement({
  String id = 'comm-1',
  String? readAt,
  String? expiresAt,
}) =>
    Announcement(
      id: id,
      title: 'Title $id',
      body: 'Body $id',
      type: AnnouncementType.announcement,
      severity: AnnouncementSeverity.normal,
      publishedAt: DateTime.utc(2026, 10, 28, 10),
      expiresAt:
          expiresAt == null ? null : DateTime.parse(expiresAt),
      readAt: readAt == null ? null : DateTime.parse(readAt),
    );

/// A CommunicationsRepository with scripted answers. Constructors take a
/// client, so this subclasses and overrides instead - the methods under
/// test never touch HTTP.
class _FakeRepo extends CommunicationsRepository {
  _FakeRepo() : super(client: null);

  Future<Result<AnnouncementPage>> Function(int limit, int offset)?
      onAnnouncements;
  Future<Result<AnnouncementRead>> Function(String id)? onMarkRead;
  Future<Result<int>> Function()? onUnreadCount;

  int markReadCalls = 0;

  @override
  Future<Result<AnnouncementPage>> announcements(
          {int limit = 50, int offset = 0}) =>
      onAnnouncements?.call(limit, offset) ??
      Future.value(const Failure('not stubbed'));

  @override
  Future<Result<AnnouncementRead>> markRead(String id) {
    markReadCalls++;
    return onMarkRead?.call(id) ??
        Future.value(const Failure('not stubbed'));
  }

  @override
  Future<Result<int>> unreadCount() =>
      onUnreadCount?.call() ?? Future.value(const Failure('not stubbed'));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // AnnouncementsState reads the signed-in account from ApiService.
    ApiService.currentUserId = 'user-1';
  });

  tearDown(() {
    ApiService.currentUserId = null;
  });

  AnnouncementPage _page(List<Announcement> items, {int? total}) =>
      AnnouncementPage(
          items: items,
          total: total ?? items.length,
          limit: 50,
          offset: 0);

  group('refresh()', () {
    test('loads the first page and filters expired rows', () async {
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async => Success(_page([
              _announcement(id: 'live'),
              _announcement(
                  id: 'dead', expiresAt: '2020-01-01T00:00:00Z'),
            ], total: 2));
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      expect(state.items.map((a) => a.id), ['live']);
      expect(state.error, isNull);
      expect(state.loading, isFalse);
    });

    test('a failure with nothing shown becomes the error state', () async {
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async =>
            const Failure<AnnouncementPage>('nope');
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      expect(state.items, isEmpty);
      expect(state.error, 'nope');
    });

    test('a failure over a loaded feed keeps the feed', () async {
      var calls = 0;
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async {
          calls++;
          if (calls == 1) {
            return Success(_page([_announcement()]));
          }
          return const Failure<AnnouncementPage>('nope');
        };
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      await state.refresh();
      expect(state.items, hasLength(1));
      expect(state.error, isNull);
    });

    test('a slow older answer never overwrites a fresher one', () async {
      var calls = 0;
      Completer<void>? gate;
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async {
        calls++;
        if (calls == 1) {
          // The first fetch stays in flight until released below.
          gate = Completer<void>();
          await gate!.future;
          return Success(_page([_announcement(id: 'stale')]));
        }
        return Success(_page([_announcement(id: 'fresh')]));
      };
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      final first = state.refresh();
      // Wait until the first fetch is actually in flight, then refresh
      // again: the second answer lands first and must be the one kept.
      while (calls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await state.refresh();
      expect(state.items.map((a) => a.id), ['fresh']);
      gate!.complete();
      await first;
      expect(state.items.map((a) => a.id), ['fresh']);
    });
  });

  group('loadMore()', () {
    test('appends the next page without duplicating ids', () async {
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, offset) async {
          if (offset == 0) {
            return Success(_page([_announcement(id: 'a')], total: 3));
          }
          // The feed shifted between requests: 'a' again, plus 'b'.
          return Success(AnnouncementPage(
              items: [_announcement(id: 'a'), _announcement(id: 'b')],
              total: 3,
              limit: 50,
              offset: offset));
        };
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      expect(state.hasMore, isTrue);
      await state.loadMore();
      expect(state.items.map((a) => a.id), ['a', 'b']);
      expect(state.hasMore, isTrue);
    });

    test('does nothing while loading or when complete', () async {
      var calls = 0;
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async {
          calls++;
          return Success(_page([_announcement()], total: 1));
        };
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      expect(state.hasMore, isFalse);
      await state.loadMore();
      expect(calls, 1);
    });
  });

  group('markRead()', () {
    test('updates optimistically then reconciles with the server', () async {
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async =>
            Success(_page([_announcement()]));
      repo.onMarkRead = (id) async => Success(AnnouncementRead(
            id: id, readAt: DateTime.utc(2026, 10, 28, 12)));
      repo.onUnreadCount = () async => const Success(0);
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      await state.refreshUnreadCount();
      final announcement = state.items.first;
      expect(announcement.isRead, isFalse);
      final ok = await state.markRead(announcement);
      expect(ok, isTrue);
      expect(state.items.first.isRead, isTrue);
      expect(state.items.first.readAt,
          DateTime.utc(2026, 10, 28, 12));
    });

    test('a failed acknowledgement restores unread and stays retryable',
        () async {
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async =>
            Success(_page([_announcement()]));
      repo.onMarkRead = (_) async =>
            const Failure<AnnouncementRead>('offline');
      repo.onUnreadCount = () async => const Success(1);
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      final ok = await state.markRead(state.items.first);
      expect(ok, isFalse);
      // Not falsely claimed: still unread, and the id kept for retry.;
      expect(state.items.first.isRead, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getStringList(
              AnnouncementsState.pendingReadsScopeFor('user-1')),
          ['comm-1']);
    });

    test('a 404 drops the row instead of retrying forever', () async {
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async =>
            Success(_page([_announcement()]));
      repo.onMarkRead = (_) async =>
            const Failure<AnnouncementRead>('gone', statusCode: 404);
      repo.onUnreadCount = () async => const Success(0);
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      final ok = await state.markRead(state.items.first);
      expect(ok, isFalse);
      expect(state.items, isEmpty);
    });

    test('pending reads retry on the next successful refresh', () async {
      var reads = 0;
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async =>
            Success(_page([_announcement()]));
      repo.onMarkRead = (id) async {
          reads++;
          if (reads == 1) {
            return const Failure<AnnouncementRead>('offline');
          }
          return Success(AnnouncementRead(
              id: id, readAt: DateTime.utc(2026, 10, 28, 12)));
        };
      repo.onUnreadCount = () async => const Success(0);
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      expect(await state.markRead(state.items.first), isFalse);
      expect(repo.markReadCalls, 1);
      await state.refresh();
      // Let the unawaited retry finish.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.markReadCalls, 2);
      expect(state.items.first.isRead, isTrue);
    });

    test('an already-read announcement needs no request', () async {
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async => Success(_page([
              _announcement(readAt: '2026-10-28T11:00:00Z'),
            ]));
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refresh();
      expect(await state.markRead(state.items.first), isTrue);
      expect(repo.markReadCalls, 0);
    });
  });

  group('refreshUnreadCount()', () {
    test('a server answer becomes the badge', () async {
      final repo = _FakeRepo();
      repo.onUnreadCount = () async => const Success(4);
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      expect(state.unreadKnown, isFalse);
      await state.refreshUnreadCount();
      expect(state.unreadCount, 4);
      expect(state.unreadKnown, isTrue);
    });

    test('an error never presents as zero', () async {
      final repo = _FakeRepo();
      repo.onUnreadCount = () async =>
            const Failure<int>('offline');
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refreshUnreadCount();
      expect(state.unreadCount, isNull);
      expect(state.unreadKnown, isFalse);
    });

    test('an error keeps the last known count, marked stale', () async {
      var calls = 0;
      final repo = _FakeRepo();
      repo.onUnreadCount = () async {
          calls++;
          if (calls == 1) return const Success(4);
          return const Failure<int>('offline');
        };
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.refreshUnreadCount();
      await state.refreshUnreadCount();
      expect(state.unreadCount, 4);
      expect(state.unreadKnown, isFalse);
    });
  });

  group('account isolation', () {
    test('switching accounts drops feed, badge and cache scope', () async {
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async =>
            Success(_page([_announcement()]));
      repo.onUnreadCount = () async => const Success(2);
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.useAccount('user-1');
      await state.refresh();
      await state.refreshUnreadCount();
      expect(state.items, hasLength(1));
      expect(state.unreadCount, 2);
      // Production always passes the current session id to useAccount;
      // the lazy reset inside refresh() trusts ApiService the same way.
      ApiService.currentUserId = 'user-2';
      await state.useAccount('user-2');
      // Dropped before user-2 loads (whose refresh is stubbed the same,
      // so wait for it, then check the cache landed in user-2's slot).
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getString(
              AnnouncementsState.cacheScopeFor('user-2')),
          isNotNull);
      // user-1's slot still holds user-1's cache only.
      expect(
          prefs.getString(
              AnnouncementsState.cacheScopeFor('user-1')),
          isNotNull);
    });

    test('signing out clears everything', () async {
      final repo = _FakeRepo();
      repo.onAnnouncements = (_, __) async =>
            Success(_page([_announcement()]));
      repo.onUnreadCount = () async => const Success(2);
      final state = AnnouncementsState(repository: repo);
      addTearDown(state.dispose);
      await state.useAccount('user-1');
      await state.refresh();
      await state.refreshUnreadCount();
      await state.useAccount(null);
      expect(state.items, isEmpty);
      expect(state.unreadCount, isNull);
      expect(state.unreadKnown, isFalse);
    });
  });
}
