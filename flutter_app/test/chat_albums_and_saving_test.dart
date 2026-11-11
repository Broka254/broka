// Photos sent together, and keeping a photo (2026-11-11).
//
// Asked for: "I want images sent together to be grouped together in one
// frame just like in whatsapp. Also add the option of saving received
// images."
//
//  * Photos one person sent together are one album: one frame, two side by
//    side, three as one wide and two under it, four or more as a square of
//    four with "+N" on the last. Each is still its own message - tapped it
//    opens the viewer at that photo, held it offers that photo's options.
//  * Photos from before albums group by sender and time; a caption or a
//    quote of its own keeps a photo apart, so neither is hidden.
//  * The viewer swipes through an album and has Save; holding a photo has
//    "Save to phone". Both keep the photo in the phone's gallery.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/chat_gallery.dart';
import 'package:broka/widgets/message_receipt.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';

String _iso(DateTime t) => t.toUtc().toIso8601String();

Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(200, 90, 40));
  return Uint8List.fromList(img.encodePng(image));
}

ChatMessage _photo(String id, DateTime at,
        {String role = 'seller', String? album, String caption = '', String? replyTo}) =>
    ChatMessage(
      id: id,
      role: role,
      msgType: 'image',
      content: caption,
      mediaUrl: 'data:image/png;base64,AAAA',
      createdAt: at,
      albumId: album,
      replyToMessageId: replyTo,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final appDocs = Directory.systemTemp.createTempSync('chat_albums_docs');
  final gallery = <MethodCall>[];
  late Object? Function(MethodCall call) galleryAnswer;
  late Object? Function(MethodCall call) permissionAnswer;

  setUpAll(() {
    installFakeApi();
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'com.llfbandit.record/messages',
      'com.broka.app/documents',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => appDocs.path);
    messenger.setMockMethodCallHandler(ChatGallery.channel, (call) async {
      gallery.add(call);
      return galleryAnswer(call);
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (call) async => permissionAnswer(call));
  });

  tearDownAll(() {
    ChatGallery.debugUseChannel = null;
    try {
      appDocs.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'buyer-1';
    ApiService.currentUserName = 'Amina Wanjiru';
    clearFakeRequests();
    gallery.clear();
    ChatGallery.debugUseChannel = true;
    galleryAnswer = (_) => 'saved';
    permissionAnswer = (call) => call.method == 'requestPermissions'
        ? {for (final p in (call.arguments as List).cast<int>()) p: 1}
        : 1;
  });

  group('which photos are one album', () {
    final t = DateTime.utc(2026, 11, 11, 9);

    test('the same album id, from one person, is one row', () {
      final rows = groupPhotoAlbums([
        _photo('a', t, album: 'x', caption: 'Front and back'),
        _photo('b', t.add(const Duration(seconds: 40)), album: 'x'),
        _photo('c', t.add(const Duration(minutes: 9)), album: 'x'),
      ]);
      expect(rows.map((r) => r.map((m) => m.id).toList()), [
        ['a', 'b', 'c'],
      ], reason: 'a slow upload is still the same send');
    });

    test('two sends one after the other are two albums', () {
      final rows = groupPhotoAlbums([
        _photo('a', t, album: 'x'),
        _photo('b', t, album: 'x'),
        _photo('c', t.add(const Duration(seconds: 5)), album: 'y'),
        _photo('d', t.add(const Duration(seconds: 5)), album: 'y'),
      ]);
      expect(rows.map((r) => r.length), [2, 2]);
    });

    test('photos from before albums group by person and time', () {
      final rows = groupPhotoAlbums([
        _photo('a', t),
        _photo('b', t.add(const Duration(seconds: 30))),
        _photo('c', t.add(photoAlbumWindow + const Duration(minutes: 1))),
        _photo('d', t.add(const Duration(minutes: 4)), role: 'buyer'),
      ]);
      expect(rows.map((r) => r.map((m) => m.id).toList()), [
        ['a', 'b'],
        ['c'],
        ['d'],
      ]);
    });

    test('a photo with its own caption or quote stands alone; so does text between', () {
      final rows = groupPhotoAlbums([
        _photo('a', t, caption: 'The box'),
        _photo('b', t, caption: 'The charger'),
        _photo('c', t, replyTo: 'm1'),
        ChatMessage(id: 'm2', role: 'seller', content: 'Hii hapa', createdAt: t),
        _photo('d', t),
      ]);
      expect(rows.map((r) => r.length), [1, 1, 1, 1, 1]);
    });

    test("an album's state is its least far along photo's", () {
      expect(albumReceipt([MessageReceipt.read, MessageReceipt.delivered]),
          MessageReceipt.delivered);
      expect(albumReceipt([MessageReceipt.read, MessageReceipt.failed]),
          MessageReceipt.failed, reason: 'one that did not go says so for the album');
      expect(albumReceipt([MessageReceipt.read, MessageReceipt.read]), MessageReceipt.read);
      expect(albumReceipt([null, null]), isNull, reason: 'theirs carry no ticks');
    });
  });

  group('in the chat', () {
    Widget chat() => MaterialApp(
          onGenerateRoute: (_) => MaterialPageRoute(
            settings: RouteSettings(arguments: {
              'listing': Listing.fromJson({
                ...fakeListingJson(1),
                'listing_type': 'fixed',
                'status': 'active',
              }),
              'role': 'buyer',
            }),
            builder: (_) => const NegotiationScreen(animateBackground: false),
          ),
        );

    /// Frames only, never real time: the chat's voice-note player listens to
    /// audioplayers' event streams, which no test answers, and with real
    /// time let through their "no such plugin" replies land inside the test
    /// and fail it. Nothing here needs it - with no real file I/O the photo
    /// vault never opens, and a photo is saved from the bytes the chat has.
    Future<void> settle(WidgetTester tester) async {
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    void serve(List<Map<String, dynamic>> history) {
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') return history;
        if (p.endsWith('/read-status')) return <String, dynamic>{};
        return null;
      });
    }

    final photoBytes = _png(60, 40);
    Map<String, dynamic> received(String id, DateTime at,
            {String? album, String caption = ''}) =>
        {
          'role': 'seller',
          'content': caption,
          'msg_type': 'image',
          'media_url': 'data:image/png;base64,${base64Encode(photoBytes)}',
          'id': id,
          'created_at': _iso(at),
          if (album != null) 'album_id': album,
        };

    testWidgets('five photos sent together are one frame: four tiles, "+2", one caption',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final at = DateTime.now().subtract(const Duration(minutes: 10));
      serve([
        for (var i = 0; i < 5; i++)
          received('a$i', at.add(Duration(seconds: i)),
              album: 'alb-1', caption: i == 0 ? 'All five colours' : ''),
      ]);
      await tester.pumpWidget(chat());
      await settle(tester);

      final album = find.byKey(const Key('photo-album'));
      expect(album, findsOneWidget);
      expect(find.byKey(const Key('photo-frame')), findsNothing,
          reason: 'it was five frames, one under the other');
      for (var i = 0; i < 4; i++) {
        expect(find.byKey(ValueKey('album-photo-$i')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('album-photo-4')), findsNothing);
      expect(find.descendant(of: album, matching: find.text('+2')), findsOneWidget);
      expect(find.descendant(of: album, matching: find.text('All five colours')), findsOneWidget);
      expect(find.descendant(of: album, matching: find.byKey(const Key('photo-meta-overlay'))),
          findsOneWidget, reason: 'the time on its corner, as on one photo');

      // Each photo opens where it is, and the viewer swipes through them all.
      await tester.tap(find.byKey(const ValueKey('album-photo-1')));
      await settle(tester);
      expect(find.text('2 of 5'), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-save')));
      await settle(tester);
      final saved = gallery.single;
      expect(saved.method, 'saveImage');
      final bytes = (saved.arguments as Map)['bytes'] as Uint8List;
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'the photo itself');
      expect(find.text("Saved to your phone's gallery"), findsOneWidget);
    });

    testWidgets('holding a photo someone sent offers "Save to phone"', (tester) async {
      serve([received('p1', DateTime.now().subtract(const Duration(minutes: 3)))]);
      await tester.pumpWidget(chat());
      await settle(tester);

      await tester.longPress(find.byKey(const Key('photo-frame')));
      await settle(tester);
      expect(find.text('Save to phone'), findsOneWidget);
      await tester.tap(find.byKey(const Key('message-save-photo')));
      await settle(tester);
      expect(gallery.map((c) => c.method), ['saveImage']);
      expect(find.text("Saved to your phone's gallery"), findsOneWidget);
    });
  });

  group('saving to the gallery', () {
    final png = _png(4, 4);

    test('Android 10 and newer: straight in', () async {
      expect(await ChatGallery.saveImage(png, name: 'BROKA_1'), GallerySaveResult.saved);
      expect((gallery.single.arguments as Map)['name'], 'BROKA_1');
    });

    test('Android 9 and older ask for storage first', () async {
      var asked = 0;
      galleryAnswer = (_) => asked == 0 ? 'permission' : 'saved';
      permissionAnswer = (call) {
        if (call.method == 'requestPermissions') {
          asked++;
          return {for (final p in (call.arguments as List).cast<int>()) p: 1};
        }
        return 1;
      };
      expect(await ChatGallery.saveImage(png, name: 'BROKA_2'), GallerySaveResult.saved);
      expect(asked, 1);
      expect(gallery, hasLength(2), reason: 'saved once allowed');
    });

    test('refused storage says what to do', () async {
      galleryAnswer = (_) => 'permission';
      permissionAnswer = (call) => call.method == 'requestPermissions'
          ? {for (final p in (call.arguments as List).cast<int>()) p: 0}
          : 0;
      final result = await ChatGallery.saveImage(png, name: 'BROKA_3');
      expect(result, GallerySaveResult.permissionDenied);
      expect(ChatGallery.describe(result), contains('Settings'));
    });

    test('what a photo is, from its bytes', () {
      expect(ChatGallery.mimeOf(png), 'image/png');
      final webp = Uint8List.fromList([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]);
      expect(ChatGallery.mimeOf(webp), 'image/webp');
      expect(ChatGallery.mimeOf(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
      expect(ChatGallery.extensionOf(png), 'png');
    });
  });
}
