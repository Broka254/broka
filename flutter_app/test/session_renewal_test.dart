// Session renewal across the app's two HTTP clients.
//
// Access tokens last 15 minutes. ApiService owns the refresh token; the
// feature repositories (escrow, disputes, auctions, stores, buy-agent, ...)
// go through the separate ApiClient. Two bugs sat between them:
//
//   * ApiService's refresh stored the new access token for itself only, so
//     ApiClient kept sending the expired one until the app restarted;
//   * ApiClient had no 401 handling at all, so it never asked for a renewal.
//
// The ApiClient tests drive a private instance through package:http's
// MockClient. The integration tests run inside http.runWithClient, which
// hands the same mock to ApiService's top-level http.post calls AND to the
// global `apiClient` when it is first created - so they exercise the real
// wiring main.dart sets up, not a stand-in for it.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  // One mock for every test that goes through the global apiClient: it keeps
  // whichever http.Client was in the zone when it was first used, so each
  // test swaps the handler rather than the client.
  late Future<http.Response> Function(http.Request) handler;
  final mock = MockClient((req) => handler(req));

  group('ApiClient on a 401', () {
    late List<String?> sentAuth;
    late ApiClient client;

    // saveToken persists through SharedPreferences.
    setUp(() => SharedPreferences.setMockInitialValues({}));

    ApiClient clientAnswering(int Function(String? auth) status) {
      sentAuth = [];
      return ApiClient(client: MockClient((req) async {
        final auth = req.headers['Authorization'];
        sentAuth.add(auth);
        final code = status(auth);
        return _json(code == 200 ? {'ok': true} : {'detail': 'nope'}, code);
      }));
    }

    test('renews the session and sends the request again with the new token', () async {
      client = clientAnswering((auth) => auth == 'Bearer fresh' ? 200 : 401);
      await client.saveToken('expired');
      var renewals = 0;
      client.onUnauthorized = () async {
        renewals++;
        await client.saveToken('fresh');
        return true;
      };

      expect(await client.get('/escrow/deals'), {'ok': true});
      expect(renewals, 1);
      expect(sentAuth, ['Bearer expired', 'Bearer fresh']);
    });

    test('a guest request is not treated as an expired session', () async {
      client = clientAnswering((_) => 401);
      var renewals = 0;
      client.onUnauthorized = () async {
        renewals++;
        return true;
      };

      await expectLater(
        client.get('/escrow/deals'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
      expect(renewals, 0);
      expect(sentAuth, [null]);
    });

    test('a failed renewal returns the 401 without a second attempt', () async {
      client = clientAnswering((_) => 401);
      await client.saveToken('expired');
      client.onUnauthorized = () async => false;

      await expectLater(
        client.post('/disputes/open', {}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
      expect(sentAuth, ['Bearer expired']);
    });

    test('a multipart request is rebuilt for the retry', () async {
      client = clientAnswering((auth) => auth == 'Bearer fresh' ? 200 : 401);
      await client.saveToken('expired');
      client.onUnauthorized = () async {
        await client.saveToken('fresh');
        return true;
      };

      expect(await client.postForm('/disputes/evidence', {'note': 'x'}), {'ok': true});
      expect(sentAuth, ['Bearer expired', 'Bearer fresh']);
    });
  });

  group('ApiService.renewSession with the global apiClient', () {

    late int refreshCalls;
    late List<String?> sentAuth;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'expired',
        'refresh_token': 'refresh-1',
        'user_id': 'user-1',
      });
      refreshCalls = 0;
      sentAuth = [];
      handler = (req) async {
        if (req.url.path == '/auth/token/refresh') {
          refreshCalls++;
          // Held open briefly so concurrent callers overlap with it.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _json({'access_token': 'fresh-$refreshCalls'}, 200);
        }
        final auth = req.headers['Authorization'];
        sentAuth.add(auth);
        if (auth == null || !auth.startsWith('Bearer fresh')) {
          return _json({'detail': 'Invalid or expired token'}, 401);
        }
        if (req.url.path == '/negotiate/chat') {
          return _json({'role': 'broker', 'content': 'Zeno here'}, 200);
        }
        return _json({'path': req.url.path}, 200);
      };
    });

    Future<T> inApp<T>(Future<T> Function() body) => http.runWithClient(() async {
          await ApiService.loadSavedSession();
          await apiClient.loadToken();
          apiClient.onUnauthorized = ApiService.renewSession;
          return body();
        }, () => mock);

    test('a refreshed token reaches the repositories, from one refresh', () async {
      final results = await inApp(() => Future.wait([
            apiClient.get('/deal/my-deals'),
            apiClient.get('/auctions/'),
            apiClient.get('/stores/mine'),
          ]));

      expect(results.map((r) => (r as Map)['path']),
          ['/deal/my-deals', '/auctions/', '/stores/mine']);
      expect(refreshCalls, 1, reason: 'concurrent 401s must share one renewal');
      // Every retry carried the renewed token, and it stuck: a later request
      // goes out with it directly instead of 401-ing again.
      expect(sentAuth.where((a) => a == 'Bearer fresh-1'), hasLength(3));
      sentAuth.clear();
      await inApp(() => apiClient.get('/deal/my-deals'));
      expect(sentAuth, ['Bearer fresh-1']);
    });

    test('Zeno chat renews an expired token instead of failing', () async {
      final reply = await inApp(() => ApiService.zenoChat(message: 'hi', history: const []));
      expect(reply, 'Zeno here');
      expect(refreshCalls, 1);
    });

    test('a refused Zeno request throws rather than returning an empty reply', () async {
      handler = (req) async => _json({'detail': 'Too many zeno_chat attempts.'}, 429);
      await expectLater(
        inApp(() => ApiService.zenoChat(message: 'hi', history: const [])),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('credentials kept on the phone', () {
    // The account password used to be kept in SharedPreferences, in plain
    // text, to log back in with when a refresh failed - and Android's
    // auto-backup copied it into the user's Google Drive. The refresh token
    // is now the only credential kept.
    late List<String> paths;

    setUp(() {
      paths = [];
      ApiService.onSessionEnded = null;
    });
    tearDown(() => ApiService.onSessionEnded = null);

    Future<T> inApp<T>(Future<T> Function() body) => http.runWithClient(() async {
          await ApiService.loadSavedSession();
          await apiClient.loadToken();
          apiClient.onUnauthorized = ApiService.renewSession;
          return body();
        }, () => mock);

    test('signing in never stores the password, and removes one an older build left', () async {
      SharedPreferences.setMockInitialValues({'user_password': 'hunter2', 'user_phone': '0712000000'});
      handler = (req) async {
        paths.add(req.url.path);
        return _json({
          'access_token': 'a1', 'refresh_token': 'r1', 'user_id': 'u1', 'name': 'Wanjiku',
        }, 200);
      };
      await inApp(() => ApiService.login(phone: '0712000000', password: 'hunter2'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('user_password'), isFalse);
      expect(prefs.getString('refresh_token'), 'r1');
    });

    test('signing up keeps the refresh token the server returns', () async {
      SharedPreferences.setMockInitialValues({});
      handler = (req) async => _json({
            'access_token': 'a1', 'refresh_token': 'r-signup', 'user_id': 'u1', 'name': 'Otieno',
          }, 201);
      await inApp(() => ApiService.register(
            phoneVerifyToken: 'pv', phone: '0712000001', name: 'Otieno', password: 'secret123',
            lat: -1.28, lng: 36.8,
          ));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), 'r-signup');
      expect(prefs.containsKey('user_password'), isFalse);
    });

    test('a refused refresh token ends the session once, without logging in again', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'expired', 'refresh_token': 'revoked', 'user_id': 'u1',
        'user_phone': '0712000000', 'user_password': 'hunter2',
      });
      handler = (req) async {
        paths.add(req.url.path);
        if (req.url.path == '/auth/token/refresh') {
          return _json({'detail': 'Refresh token has been revoked'}, 401);
        }
        return _json({'detail': 'Invalid or expired token'}, 401);
      };
      var ended = 0;
      ApiService.onSessionEnded = () => ended++;

      await inApp(() async {
        final results = await Future.wait([
          apiClient.get('/deal/my-deals').then((_) => 'ok', onError: (_) => 'failed'),
          apiClient.get('/auctions/').then((_) => 'ok', onError: (_) => 'failed'),
        ]);
        expect(results, ['failed', 'failed']);
      });

      expect(ended, 1);
      expect(paths.where((p) => p == '/auth/token/refresh'), hasLength(1));
      expect(paths, isNot(contains('/auth/login')));
      expect(ApiService.currentUserId, isNull);
      expect(ApiService.isLoggedIn, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), isNull);
      expect(prefs.containsKey('user_password'), isFalse);
    });

    test('no network during a refresh keeps the session', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'expired', 'refresh_token': 'r1', 'user_id': 'u1',
      });
      handler = (req) async {
        if (req.url.path == '/auth/token/refresh') {
          throw http.ClientException('Network is unreachable');
        }
        return _json({'detail': 'Invalid or expired token'}, 401);
      };
      var ended = 0;
      ApiService.onSessionEnded = () => ended++;

      await inApp(() async {
        await expectLater(apiClient.get('/deal/my-deals'), throwsA(isA<ApiException>()));
      });

      expect(ended, 0);
      expect(ApiService.currentUserId, 'u1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), 'r1');
    });

    test('a rotated refresh token is kept', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'expired', 'refresh_token': 'r-old', 'user_id': 'u1',
      });
      handler = (req) async {
        if (req.url.path == '/auth/token/refresh') {
          return _json({'access_token': 'fresh', 'refresh_token': 'r-new'}, 200);
        }
        final auth = req.headers['Authorization'];
        return auth == 'Bearer fresh' ? _json({'ok': true}, 200) : _json({'detail': 'expired'}, 401);
      };
      await inApp(() => apiClient.get('/deal/my-deals'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), 'r-new');
    });
  });
}
