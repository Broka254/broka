// The communications repository: GET /communications, POST .../read and
// GET /communications/unread-count (backend/api/domains/service_communications/router.py).
//
// Model parsing (including unknown type/severity values from a newer
// backend), read/unread mapping, API success/empty/malformed responses,
// auth and network failures, read-acknowledgement success and failure,
// and unread-count parsing - through package:http's MockClient injected
// into a private ApiClient, the unit-test seam session_renewal_test.dart
// documents.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/communications/data/repositories/communications_repository.dart';
import 'package:broka/features/communications/domain/models/announcement.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, int status) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

Map<String, dynamic> _announcementJson({
  String id = 'comm-1',
  String title = 'Maintenance tonight',
  String body = 'We will be down from 2am to 3am.',
  String type = 'maintenance',
  String severity = 'high',
  String? deepLink,
  String? publishedAt = '2026-10-28T10:00:00Z',
  String? expiresAt,
  String? readAt,
}) =>
    {
      'id': id,
      'title': title,
      'body': body,
      'communication_type': type,
      'severity': severity,
      'deep_link': deepLink,
      'published_at': publishedAt,
      'expires_at': expiresAt,
      'read_at': readAt,
      'is_read': readAt != null,
    };

Map<String, dynamic> _pageJson(List<Object?> items,
        {int? total, int limit = 50, int offset = 0}) =>
    {
      'items': items,
      'total': total ?? items.length,
      'limit': limit,
      'offset': offset,
    };

CommunicationsRepository _repo(
        Future<http.Response> Function(http.Request) handler) =>
    CommunicationsRepository(
        client: ApiClient(client: MockClient(handler)));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Announcement.fromJson', () {
    test('parses the full customer shape', () {
      final a = Announcement.fromJson(_announcementJson())!;
      expect(a.id, 'comm-1');
      expect(a.title, 'Maintenance tonight');
      expect(a.body, contains('2am'));
      expect(a.type, AnnouncementType.maintenance);
      expect(a.severity, AnnouncementSeverity.high);
      expect(a.isRead, isFalse);
      expect(a.publishedAt, isNotNull);
    });

    test('maps read_at to read, null to unread', () {
      expect(Announcement.fromJson(_announcementJson())!.isRead, isFalse);
      expect(
          Announcement.fromJson(
                  _announcementJson(readAt: '2026-10-28T11:00:00Z'))!
              .isRead,
          isTrue);
    });

    test('unknown type and severity from a newer backend still parse', () {
      final a = Announcement.fromJson(
          _announcementJson(type: 'webinar', severity: 'urgent'))!;
      expect(a.type, AnnouncementType.unknown);
      expect(a.severity, AnnouncementSeverity.normal);
    });

    test('rows without id, title or body are skipped, not fatal', () {
      expect(Announcement.fromJson(_announcementJson(id: '')), isNull);
      expect(
          Announcement.fromJson(_announcementJson(title: '  ')), isNull);
      expect(Announcement.fromJson(_announcementJson(body: '')), isNull);
    });

    test('expiry in the past reads as expired', () {
      final expired = Announcement.fromJson(
          _announcementJson(expiresAt: '2020-01-01T00:00:00Z'))!;
      expect(expired.isExpired, isTrue);
      final live = Announcement.fromJson(
          _announcementJson(expiresAt: '2030-01-01T00:00:00Z'))!;
      expect(live.isExpired, isFalse);
      expect(
          Announcement.fromJson(_announcementJson())!.isExpired, isFalse);
    });

    test('naive backend timestamps parse as UTC, not local', () {
      // parseBackendUtc: the backend serializes naive UTC without a suffix;
      // parsing must not shift by the device offset.
      final a = Announcement.fromJson(
          _announcementJson(publishedAt: '2026-10-28T10:00:00'))!;
      expect(a.publishedAt!.isUtc, isTrue);
      expect(a.publishedAt!.hour, 10);
    });
  });

  group('AnnouncementPage.fromJson', () {
    test('skips malformed rows but keeps the page', () {
      final page = AnnouncementPage.fromJson(_pageJson([
        _announcementJson(id: 'good'),
        {'id': '', 'title': '', 'body': ''},
        'not-a-map',
      ], total: 3));
      expect(page.items.map((a) => a.id), ['good']);
      expect(page.total, 3);
    });

    test('missing envelope fields fall back to the items at hand', () {
      final page = AnnouncementPage.fromJson(
          {'items': [_announcementJson()]});
      expect(page.items, hasLength(1));
      expect(page.total, 1);
      expect(page.offset, 0);
    });
  });

  group('announcements()', () {
    test('sends limit/offset and parses the page', () async {
      Uri? seen;
      final repo = _repo((req) async {
        seen = req.url;
        return _json(
            _pageJson([_announcementJson(), _announcementJson(id: 'comm-2')]),
            200);
      });
      final result =
          await repo.announcements(limit: 20, offset: 40);
      expect(result, isA<Success<AnnouncementPage>>());
      final page = (result as Success<AnnouncementPage>).data;
      expect(page.items.map((a) => a.id), ['comm-1', 'comm-2']);
      expect(seen!.queryParameters['limit'], '20');
      expect(seen!.queryParameters['offset'], '40');
    });

    test('an empty feed is success with no items, not an error', () async {
      final repo = _repo((_) async => _json(_pageJson([]), 200));
      final result = await repo.announcements();
      expect(result, isA<Success<AnnouncementPage>>());
      expect(
          (result as Success<AnnouncementPage>).data.items, isEmpty);
    });

    test('a non-map body is a generic failure, not a crash', () async {
      final repo = _repo((_) async => _json(['nope'], 200));
      final result = await repo.announcements();
      expect(result, isA<Failure<AnnouncementPage>>());
    });

    test('a 401 surfaces the status code for session handling', () async {
      final repo =
          _repo((_) async => _json({'detail': 'Not authenticated'}, 401));
      final result = await repo.announcements();
      expect(result, isA<Failure<AnnouncementPage>>());
      expect((result as Failure<AnnouncementPage>).statusCode, 401);
    });

    test('a network failure becomes the offline message', () async {
      final repo = _repo((_) async {
        throw http.ClientException('Failed host lookup');
      });
      final result = await repo.announcements();
      expect(result, isA<Failure<AnnouncementPage>>());
      expect((result as Failure<AnnouncementPage>).message,
          contains('internet connection'));
    });

    test('a 500 body is replaced with the generic message', () async {
      final repo = _repo(
          (_) async => _json({'detail': 'Internal Server Error'}, 500));
      final result = await repo.announcements();
      expect((result as Failure<AnnouncementPage>).message,
          'Something went wrong. Please try again.');
    });
  });

  group('markRead()', () {
    test('returns the server read timestamp on success', () async {
      final repo = _repo((req) async {
        expect(req.url.path, '/communications/comm-1/read');
        expect(req.method, 'POST');
        return _json({
          'id': 'comm-1',
          'is_read': true,
          'read_at': '2026-10-28T12:00:00Z'
        }, 200);
      });
      final result = await repo.markRead('comm-1');
      expect(result, isA<Success<AnnouncementRead>>());
      expect((result as Success<AnnouncementRead>).data.readAt, isNotNull);
    });

    test('a 404 keeps its status code so callers drop the row', () async {
      final repo = _repo((_) async =>
          _json({'detail': 'Announcement not found'}, 404));
      final result = await repo.markRead('gone');
      expect(result, isA<Failure<AnnouncementRead>>());
      expect((result as Failure<AnnouncementRead>).statusCode, 404);
    });

    test('a network failure is retryable and keeps no false read', () async {
      final repo = _repo((_) async {
        throw http.ClientException('Failed host lookup');
      });
      final result = await repo.markRead('comm-1');
      expect(result, isA<Failure<AnnouncementRead>>());
      expect((result as Failure<AnnouncementRead>).statusCode, isNull);
    });
  });

  group('unreadCount()', () {
    test('parses the server-backed count', () async {
      final repo =
          _repo((_) async => _json({'unread_count': 3}, 200));
      final result = await repo.unreadCount();
      expect(result, isA<Success<int>>());
      expect((result as Success<int>).data, 3);
    });

    test('a missing or negative count is a failure, never a zero', () async {
      final missing =
          _repo((_) async => _json({'unread_count': null}, 200));
      expect(await missing.unreadCount(), isA<Failure<int>>());
      final negative =
          _repo((_) async => _json({'unread_count': -1}, 200));
      expect(await negative.unreadCount(), isA<Failure<int>>());
    });

    test('a 401 surfaces the status code', () async {
      final repo =
          _repo((_) async => _json({'detail': 'Not authenticated'}, 401));
      final result = await repo.unreadCount();
      expect((result as Failure<int>).statusCode, 401);
    });
  });
}
