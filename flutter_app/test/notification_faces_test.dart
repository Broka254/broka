// Faces on notifications (2026-10-08).
//
// Asked for: incoming calls, missed calls and messages show the selfie of
// the person calling or writing. The server sends their photo's URL with
// the push; the app's sweep has the inbox's photo, which can still be an
// inline base64 selfie. Either becomes the notification's large icon,
// round. A photo that can't be had in time is no face, never no
// notification - and an incoming call waits only briefly for one.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:broka/services/active_call.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_avatar.dart';
import 'package:broka/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _photoUrl = 'https://img.broka.test/img/ann/thumb.webp';

/// A [w]x[h] picture, one colour all over, as PNG.
Future<Uint8List> _png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFFE91E63));
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// The decoded size of [bytes], and whether its corner is see-through and
/// its middle is not - a round picture.
Future<({int width, int height, bool round})> _inspect(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  int alphaAt(int x, int y) => rgba.getUint8((y * image.width + x) * 4 + 3);
  return (
    width: image.width,
    height: image.height,
    round: alphaAt(0, 0) == 0 && alphaAt(image.width ~/ 2, image.height ~/ 2) == 255,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final shown = <Map<String, dynamic>>[];
  var active = <Map<String, Object?>>[];
  final requests = <http.Request>[];
  late Future<http.Response> Function(http.Request) route;
  final client = MockClient((req) {
    requests.add(req);
    return route(req);
  });
  late Uint8List photo;
  late Directory cache;

  Future<T> withClient<T>(Future<T> Function() body) =>
      http.runWithClient(body, () => client);

  Map<String, dynamic> android(Map<String, dynamic> shownCall) =>
      Map<String, dynamic>.from(shownCall['platformSpecifics'] as Map);

  setUpAll(() async {
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'com.broka.app/ringtone',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'show') {
        shown.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      if (call.method == 'getActiveNotifications') return active;
      return null;
    });
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
    photo = await _png(480, 640);
  });

  setUp(() {
    shown.clear();
    requests.clear();
    active = [];
    SharedPreferences.setMockInitialValues({});
    ActiveCall.instance.reset();
    ApiService.currentUserId = 'seller-1';
    NotificationAvatar.clearMemory();
    cache = Directory.systemTemp.createTempSync('avatars');
    NotificationAvatar.cacheDirectory = () async => cache;
    route = (req) async => req.url.toString() == _photoUrl
        ? http.Response.bytes(photo, 200, headers: {'content-type': 'image/png'})
        : http.Response('{}', 200, headers: {'content-type': 'application/json'});
  });

  tearDown(() {
    try {
      cache.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('a face', () {
    test('from a photo URL: round, small, and kept for next time', () async {
      final face = await withClient(() => NotificationAvatar.load(_photoUrl));
      expect(face, isNotNull);
      final seen = await _inspect(face!);
      expect((seen.width, seen.height), (NotificationAvatar.size, NotificationAvatar.size));
      expect(seen.round, isTrue);

      // A closed app's push isolate starts with nothing in memory: the
      // photo comes from disk, with no network at all.
      NotificationAvatar.clearMemory();
      route = (_) async => throw const SocketException('offline');
      final again = await withClient(() => NotificationAvatar.load(_photoUrl));
      expect(again, isNotNull);
      expect(requests.where((r) => r.url.toString() == _photoUrl), hasLength(1));
    });

    test('from an inline selfie, as the inbox still sends some', () async {
      final face = await NotificationAvatar.load(base64Encode(photo));
      expect(face, isNotNull);
      expect((await _inspect(face!)).round, isTrue);
    });

    test('an error page is no face', () async {
      route = (_) async => http.Response('<html>oops</html>', 200,
          headers: {'content-type': 'text/html'});
      expect(await withClient(() => NotificationAvatar.load(_photoUrl)), isNull);
      route = (_) async => http.Response('', 404);
      expect(await withClient(() => NotificationAvatar.load(_photoUrl)), isNull);
      expect(await NotificationAvatar.load(null), isNull);
      expect(await NotificationAvatar.load('  '), isNull);
    });
  });

  group('an incoming call', () {
    test("shows the caller's face", () async {
      await withClient(() => NotificationService.instance.showIncomingCall(
            roomId: 'room-1', callerName: 'Ann Buyer', listingName: 'Samsung A54',
            callerPhoto: _photoUrl));
      final icon = android(shown.single)['largeIcon'];
      expect(icon, isA<Uint8List>());
      expect((await _inspect(icon as Uint8List)).round, isTrue);
    });

    test('is not held up by a photo that is slow to come', () async {
      final never = Completer<http.Response>();
      route = (_) => never.future;
      final started = DateTime.now();
      await withClient(() => NotificationService.instance.showIncomingCall(
            roomId: 'room-2', callerName: 'Ann Buyer', listingName: 'Samsung A54',
            callerPhoto: _photoUrl));
      expect(DateTime.now().difference(started),
          lessThan(NotificationService.callFaceWait + const Duration(seconds: 1)));
      expect(shown, hasLength(1), reason: 'posted without the face');
      expect(android(shown.single)['largeIcon'], isNull);
    });

    test('without a photo, as before', () {
      final details = NotificationService.incomingCallDetails(
          ringing: true, ringFor: const Duration(seconds: 45));
      expect(details.android!.largeIcon, isNull);
      final face = Uint8List.fromList([1, 2, 3]);
      final withFace = NotificationService.incomingCallDetails(
          ringing: true, ringFor: const Duration(seconds: 45), face: face);
      expect((withFace.android!.largeIcon as ByteArrayAndroidBitmap).data, face);
    });
  });

  group('with the app in front', () {
    test("a message shows the sender's face", () async {
      await withClient(() => NotificationService.instance.handleForegroundFcmMessage({
            'type': 'new_message', 'listingId': 'listing-1', 'buyerId': 'buyer-1',
            'myRole': 'seller', 'messageId': 'm-1', 'senderName': 'Ann Buyer',
            'senderPhoto': _photoUrl, 'title': 'Ann Buyer · Samsung A54',
            'body': 'Last price?',
          }));
      expect(shown.single['title'], 'Ann Buyer · Samsung A54');
      expect(android(shown.single)['largeIcon'], isA<Uint8List>());
    });

    test("a missed call shows the caller's face", () async {
      await withClient(() => NotificationService.instance.handleForegroundFcmMessage({
            'type': 'missed_call', 'roomId': 'room-1', 'listingId': 'listing-1',
            'buyerId': 'buyer-1', 'myRole': 'seller', 'callerName': 'Ann Buyer',
            'callerPhoto': _photoUrl, 'listingName': 'Samsung A54',
          }));
      expect(shown.single['title'], 'Missed call from Ann Buyer');
      expect(android(shown.single)['largeIcon'], isA<Uint8List>());
    });

    test("the sweep's message shows the inbox's photo", () async {
      await NotificationService.instance.showNewMessage(
          fromName: 'Ann Buyer', preview: 'Hello', listingId: 'listing-1',
          buyerId: 'buyer-1', photo: base64Encode(photo));
      expect(android(shown.single)['largeIcon'], isA<Uint8List>());
    });
  });

  group('with the app closed', () {
    // Android draws a message push itself, faceless; it is drawn again
    // over it with the face, without a second sound.
    Map<String, dynamic> pushed() => {
          'type': 'new_message', 'listingId': 'listing-1', 'buyerId': 'buyer-1',
          'myRole': 'seller', 'messageId': 'm-1', 'senderName': 'Ann Buyer',
          'senderPhoto': _photoUrl, 'listingName': 'Samsung A54',
          'title': 'Ann Buyer · Samsung A54', 'body': '2 new messages · Last price?',
        };

    Map<String, Object?> drawn(Map<String, dynamic> push) => {
          'id': 0, 'tag': 'thread_listing-1_buyer-1', 'channelId': 'broka_messages',
          'title': push['title'], 'body': push['body'],
        };

    test("Android's message notification gets the sender's face", () async {
      active = [drawn(pushed())];
      await withClient(() => NotificationService.handleBackgroundMessage(pushed()));
      final redrawn = shown.single;
      expect(redrawn['id'], 0);
      expect(redrawn['title'], 'Ann Buyer · Samsung A54');
      expect(redrawn['body'], '2 new messages · Last price?');
      final details = android(redrawn);
      expect(details['tag'], 'thread_listing-1_buyer-1');
      expect(details['silent'], isTrue, reason: 'the push already made its sound');
      expect(details['largeIcon'], isA<Uint8List>());
      final payload = jsonDecode(redrawn['payload'] as String) as Map;
      expect(payload['type'], 'new_message');
      expect(payload['listingId'], 'listing-1');
    });

    test('not one the user already opened or swiped away', () async {
      active = [];
      await withClient(() => NotificationService.handleBackgroundMessage(pushed()));
      expect(shown, isEmpty);
    });

    test('never puts back an older message over a newer one', () async {
      // The next message's push was drawn while this one's photo loaded.
      active = [drawn({...pushed(), 'body': '3 new messages · Still there?'})];
      await withClient(() => NotificationService.handleBackgroundMessage(pushed()));
      expect(shown, isEmpty);
    });

    test("a missed call gets the caller's face", () async {
      active = [
        {'id': 0, 'tag': 'missed_listing-1_buyer-1', 'channelId': 'broka_messages',
         'title': 'Missed call from Ann Buyer', 'body': 'About: Samsung A54'},
      ];
      await withClient(() => NotificationService.handleBackgroundMessage({
            'type': 'missed_call', 'roomId': 'room-1', 'listingId': 'listing-1',
            'buyerId': 'buyer-1', 'myRole': 'seller', 'callerName': 'Ann Buyer',
            'callerPhoto': _photoUrl, 'listingName': 'Samsung A54',
            'title': 'Missed call from Ann Buyer', 'body': 'About: Samsung A54',
          }));
      final redrawn = shown.single;
      expect(redrawn['title'], 'Missed call from Ann Buyer');
      expect(android(redrawn)['largeIcon'], isA<Uint8List>());
      expect(android(redrawn)['silent'], isTrue);
    });

    test('an incoming call shows the face too', () async {
      await withClient(() => NotificationService.handleBackgroundMessage({
            'type': 'incoming_call', 'roomId': 'room-7', 'listingId': 'listing-1',
            'buyerId': 'buyer-1', 'callerName': 'Ann Buyer', 'callerPhoto': _photoUrl,
            'listingName': 'Samsung A54', 'callType': 'audio', 'callToken': 'ct',
          }));
      final call = shown.single;
      expect(call['title'], '📞 Incoming call from Ann Buyer');
      expect(android(call)['largeIcon'], isA<Uint8List>());
    });
  });
}
