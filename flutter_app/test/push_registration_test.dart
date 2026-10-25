// Device-token registration lifecycle (2026-10-25).
//
// Reported: calls and messages usually reached a phone only while the app
// was open. FCM itself worked; the phone often had no CURRENT token on the
// account that was being called. The paths below had no retry and no
// diagnostics, and sign-out lost the token whenever the process had been
// restarted since it was registered.
//
//  * The token is per install, not per session: it is persisted so a
//    sign-out after a restart still takes this phone off the account.
//  * A failed registration is retried (15s / 1m / 5m / 15m), and an
//    already-registered token for the same account is not posted again on
//    every resume.
//  * A refreshed FCM token is registered through the same path, naming the
//    previous token so the server drops it.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ApiService's global apiClient keeps the http.Client from the first zone
  // it is used in (see session_renewal_test.dart), so swap the handler, not
  // the client.
  late Future<http.Response> Function(http.Request) handler;
  final mock = MockClient((req) => handler(req));

  Future<T> withClient<T>(Future<T> Function() body) =>
      http.runWithClient(body, () => mock);

  GlobalPollerService poller() => GlobalPollerService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'access-1',
      'user_id': 'seller-1',
    });
    ApiService.currentUserId = 'seller-1';
    ApiService.registeredPushToken = null;
    // The global apiClient is created lazily and keeps whichever http.Client
    // was in the zone at that moment (see session_renewal_test.dart). Touch
    // it inside the zone, or it would capture a real client before any test.
    await withClient(() async => apiClient.onUnauthorized = null);
    handler = (req) async {
      if (req.url.path.startsWith('/negotiate/inbox/')) {
        return _json(const <Object>[]);
      }
      if (req.url.path == '/calls/incoming') return _json({'has_call': false});
      return _json({'status': 'ok', 'push_enabled': true});
    };
    poller().firebaseReady = true;
    poller().fcmTokenProvider = () async => 'fcm-token-1';
    poller().pushTokenRegistrar =
        (token, {String tokenType = 'fcm', String? previousToken}) async {
      return true;
    };
    poller().pushRetryDelays = const [Duration(milliseconds: 5)];
  });

  tearDown(() {
    poller().stop();
    poller().firebaseReady = false;
    poller().fcmTokenProvider = null;
    poller().pushTokenRegistrar = null;
    poller().pushRetryDelays = const [
      Duration(seconds: 15),
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
    ];
    ApiService.currentUserId = null;
    ApiService.registeredPushToken = null;
    apiClient.onUnauthorized = null;
  });

  group('ApiService registration', () {
    test('sends the previous token and persists the accepted one', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'access-1',
        'user_id': 'seller-1',
        'registered_push_token': 'old-token',
      });
      ApiService.registeredPushToken = 'old-token';
      final bodies = <Map<String, dynamic>>[];
      handler = (req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return _json({'status': 'ok', 'push_enabled': true});
      };

      final enabled = await withClient(
          () => ApiService.registerFcmToken('new-token', previousToken: 'old-token'));

      expect(enabled, isTrue);
      expect(bodies.single['fcm_token'], 'new-token');
      expect(bodies.single['previous_token'], 'old-token');
      expect(ApiService.registeredPushToken, 'new-token');
      expect(
        (await SharedPreferences.getInstance())
            .getString('registered_push_token'),
        'new-token',
        reason: 'a restart must not lose the token sign-out needs',
      );
    });

    test('a failed registration returns null and keeps the previous token', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'access-1',
        'user_id': 'seller-1',
        'registered_push_token': 'previous-token',
      });
      ApiService.registeredPushToken = 'previous-token';
      handler = (req) async => _json({'detail': 'temporarily unavailable'}, 503);

      final enabled =
          await withClient(() => ApiService.registerPushToken('new-token'));

      expect(enabled, isNull, reason: 'the caller must be able to retry');
      expect(ApiService.registeredPushToken, 'previous-token');
      expect(
        (await SharedPreferences.getInstance())
            .getString('registered_push_token'),
        'previous-token',
      );
    });

    test('an expired session is renewed and the registration retried', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'expired',
        'refresh_token': 'refresh-1',
        'user_id': 'seller-1',
      });
      await apiClient.saveToken('expired');
      apiClient.onUnauthorized = () async {
        await apiClient.saveToken('fresh');
        return true;
      };
      handler = (req) async {
        if (req.headers['Authorization'] != 'Bearer fresh') {
          return _json({'detail': 'Invalid or expired token'}, 401);
        }
        return _json({'status': 'ok', 'push_enabled': true});
      };

      final enabled =
          await withClient(() => ApiService.registerPushToken('new-token'));

      expect(enabled, isTrue);
      expect(ApiService.registeredPushToken, 'new-token');
    });

    test('sign-out after a restart unregisters the persisted token', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'access-1',
        'refresh_token': 'refresh-1',
        'user_id': 'seller-1',
        'registered_push_token': 'persisted-token',
      });
      // A new process: the in-memory field starts null.
      ApiService.registeredPushToken = null;
      await ApiService.loadSavedSession();
      expect(ApiService.registeredPushToken, 'persisted-token');

      final unregistered = <String>[];
      handler = (req) async {
        if (req.url.path == '/calls/unregister-token') {
          unregistered.add(
              (jsonDecode(req.body) as Map)['fcm_token'] as String);
        }
        return _json({'status': 'ok'});
      };

      await withClient(() => ApiService.signOut());

      expect(unregistered, ['persisted-token']);
      expect(ApiService.registeredPushToken, isNull);
      expect(
        (await SharedPreferences.getInstance())
            .getString('registered_push_token'),
        isNull,
      );
    });
  });

  group('GlobalPollerService registration', () {
    test('registers once for the same token and account', () async {
      final registered = <String>[];
      poller().pushTokenRegistrar =
          (token, {String tokenType = 'fcm', String? previousToken}) async {
        registered.add(token);
        return true;
      };

      await withClient(() async {
        poller().start();
        await poller().ensurePushRegistration();
        await poller().ensurePushRegistration();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });

      expect(registered, ['fcm-token-1']);
      expect(poller().pushReady, isTrue);
    });

    test('retries a failed registration without waiting for a restart', () async {
      final attempts = <String>[];
      poller().pushTokenRegistrar =
          (token, {String tokenType = 'fcm', String? previousToken}) async {
        attempts.add(token);
        return attempts.length == 1 ? null : true;
      };

      await withClient(() async {
        poller().start();
        await poller().ensurePushRegistration();
        expect(poller().pushReady, isFalse);
        // setUp shortened the first retry delay to 5ms.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      expect(attempts, ['fcm-token-1', 'fcm-token-1']);
      expect(poller().pushReady, isTrue);
    });

    test('a refreshed token names the one it replaces', () async {
      final tokens = <String>[];
      final previous = <String?>[];
      poller().pushTokenRegistrar =
          (token, {String tokenType = 'fcm', String? previousToken}) async {
        tokens.add(token);
        previous.add(previousToken);
        // What ApiService.registerPushToken does on success.
        ApiService.registeredPushToken = token;
        return true;
      };

      await withClient(() async {
        poller().start();
        await poller().ensurePushRegistration();
        poller().handleFcmTokenRefresh('fcm-token-2');
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });

      expect(tokens, ['fcm-token-1', 'fcm-token-2']);
      expect(previous, [null, 'fcm-token-1']);
      expect(poller().pushReady, isTrue);
    });

    test('a different account on the same phone registers again', () async {
      final users = <String?>[];
      poller().pushTokenRegistrar =
          (token, {String tokenType = 'fcm', String? previousToken}) async {
        users.add(ApiService.currentUserId);
        return true;
      };

      await withClient(() async {
        poller().start();
        await poller().ensurePushRegistration();
        // Shared phone: the same device token now belongs to someone else.
        ApiService.currentUserId = 'buyer-2';
        await poller().ensurePushRegistration();
      });

      expect(users, ['seller-1', 'buyer-2']);
    });
  });
}
