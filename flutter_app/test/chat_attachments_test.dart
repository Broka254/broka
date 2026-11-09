// The direct chat's composer, photos and documents (2026-11-09).
//
// The composer was a single pill with its icons inside the text line; it
// is now a card - the message on top, labelled shortcuts (Photos,
// Document) and the round buttons (attach, microphone, send) under it.
// Photos went one at a time and documents not at all: several photos now
// go at once, each its own message, and a document is sent, shown and
// opened. A photo sits in a frame of the bubble's own colour with its time
// on it, as on WhatsApp.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/chat_media_vault.dart';
import 'package:broka/services/local_chat_store.dart';
import 'package:broka/widgets/aspect_image.dart';
import 'package:broka/widgets/chat_parts.dart';
import 'package:broka/widgets/message_receipt.dart';

import 'support/fake_api.dart';

String _iso(DateTime t) => t.toUtc().toIso8601String();

Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(30, 120, 200));
  return Uint8List.fromList(img.encodePng(image));
}

/// The gallery, handing back the photos a test chose.
class _Gallery extends ImagePickerPlatform {
  _Gallery(this.files);
  final List<File> files;
  MultiImagePickerOptions? asked;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    asked = options;
    return [for (final f in files) XFile(f.path)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const documents = MethodChannel('com.broka.app/documents');
  late List<MethodCall> documentCalls;
  late List<Object?> picked;
  late Directory tmp;
  // This file's own "app documents" folder: other test files share the
  // system temp folder's outbox, and one of them empties it.
  final appDocs = Directory.systemTemp.createTempSync('chat_attachments_docs');
  // Message ids of this run, so nothing a previous run left behind on
  // disk passes for a document kept on the phone.
  final run = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() {
    installFakeApi();
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'com.llfbandit.record/messages',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    // The outbox, the photo vault and kept documents live under the app's
    // documents folder.
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => appDocs.path);
  });

  tearDownAll(() {
    try {
      appDocs.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'buyer-1';
    ApiService.currentUserName = 'Amina Wanjiru';
    clearFakeRequests();
    tmp = Directory.systemTemp.createTempSync('chat_attachments');
    documentCalls = [];
    picked = const [];
    messenger.setMockMethodCallHandler(documents, (call) async {
      documentCalls.add(call);
      if (call.method == 'pick') return picked;
      if (call.method == 'open') return 'opened';
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(documents, null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

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

  /// pumpAndSettle never returns (the constellation animates).
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Photos and documents are real files: their reads and writes only move
  /// outside the test's fake clock. Real waits, then frames, until through.
  Future<void> settleIo(WidgetTester tester, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  void serve(List<Map<String, dynamic>> history, {Object? Function(Uri)? also}) {
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') return history;
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return also?.call(uri);
    });
  }

  List<FakeRequest> uploads() => [
        for (final r in fakeRequests)
          if (r.method == 'POST' && r.uri.path == '/media/upload') r,
      ];

  /// A form field of a multipart upload, as the server reads it.
  bool hasField(FakeRequest r, String name, String value) =>
      r.body.contains('name="$name"\r\n\r\n$value\r\n');

  group('the composer', () {
    testWidgets('is a card: the message on top, the shortcuts under it', (tester) async {
      serve([]);
      await tester.pumpWidget(chat());
      await settle(tester);

      final card = find.byType(ChatComposerCard);
      expect(card, findsOneWidget);
      Finder inCard(Finder f) => find.descendant(of: card, matching: f);
      expect(inCard(find.byKey(const Key('direct-chat-composer'))), findsOneWidget);
      expect(inCard(find.byKey(const Key('composer-photos'))), findsOneWidget);
      expect(inCard(find.byKey(const Key('composer-document'))), findsOneWidget);
      expect(inCard(find.byTooltip('Attach')), findsOneWidget);
      expect(inCard(find.byTooltip('Record a voice note')), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);
      expect(find.text('Document'), findsOneWidget);

      // Under the text, not squeezed into its line.
      final field = tester.getRect(find.byKey(const Key('direct-chat-composer')));
      expect(tester.getRect(find.byKey(const Key('composer-photos'))).top,
          greaterThanOrEqualTo(field.bottom - 1));
      expect(tester.getRect(find.byTooltip('Attach')).top,
          greaterThanOrEqualTo(field.bottom - 1));

      // Something to send: the send button takes the microphone's place.
      await tester.enterText(find.byKey(const Key('direct-chat-composer')), 'Bado iko?');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('Record a voice note'), findsNothing);
      expect(tester.widget<ChatSendButton>(find.byType(ChatSendButton)).visible, isTrue);
    });

    testWidgets('"+" offers the camera, photos and a document', (tester) async {
      serve([]);
      await tester.pumpWidget(chat());
      await settle(tester);
      await tester.tap(find.byTooltip('Attach'));
      await settle(tester);
      expect(find.text('Take a photo'), findsOneWidget);
      expect(find.text('Choose photos'), findsOneWidget);
      expect(find.text('Send a document'), findsOneWidget);
    });
  });

  group('photos', () {
    testWidgets('several go at once, each its own message, the caption on the first',
        (tester) async {
      final files = <File>[];
      await tester.runAsync(() async {
        for (var i = 0; i < 3; i++) {
          final f = File('${tmp.path}/pick_$i.png');
          await f.writeAsBytes(_png(40 + i, 30));
          files.add(f);
        }
      });
      final gallery = _Gallery(files);
      ImagePickerPlatform.instance = gallery;
      var n = 0;
      serve([], also: (uri) {
        if (uri.path != '/media/upload') return null;
        n++;
        return {
          'id': 'photo-$n',
          'role': 'buyer',
          'msg_type': 'image',
          'media_url': 'data:image/png;base64,${base64Encode(_png(8, 6))}',
          'created_at': _iso(DateTime.now()),
        };
      });
      await tester.pumpWidget(chat());
      await settle(tester);

      await tester.tap(find.byKey(const Key('composer-photos')));
      await settleIo(tester, rounds: 6);
      expect(gallery.asked?.limit, 10,
          reason: 'the picker is asked for at most what one send takes');
      expect(find.text('3 photos'), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-thumb-2')), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, 'Add a caption to the first photo (optional)'),
          'Front, back and the box');
      await tester.tap(find.byKey(const Key('photos-send')));
      await settleIo(tester, rounds: 60);

      final sent = uploads();
      expect(sent, hasLength(3), reason: 'one upload per photo');
      for (final r in sent) {
        expect(hasField(r, 'content_type', 'image'), isTrue);
      }
      expect(hasField(sent.first, 'caption', 'Front, back and the box'), isTrue);
      expect(sent.skip(1).any((r) => r.body.contains('name="caption"')), isFalse);
      expect(find.byKey(const Key('photo-frame')), findsNWidgets(3));
      expect(find.text('Not sent'), findsNothing);
    });
  });

  group('documents', () {
    testWidgets('a document is sent, shown, and opened from the copy kept here',
        (tester) async {
      late File pdf;
      await tester.runAsync(() async {
        pdf = File('${tmp.path}/Quote.pdf');
        await pdf.writeAsBytes(utf8.encode('%PDF-1.4 quote'));
      });
      picked = [
        {'name': 'Quote.pdf', 'path': pdf.path, 'size': 14, 'mime': 'application/pdf'},
      ];
      serve([], also: (uri) {
        if (uri.path != '/media/upload') return null;
        return {
          'id': 'doc-1-$run',
          'role': 'buyer',
          'msg_type': 'file',
          'media_url': '/media/chat-files/f1',
          'file_name': 'Quote.pdf',
          'file_size': 14,
          'file_mime': 'application/pdf',
          'created_at': _iso(DateTime.now()),
        };
      });
      await tester.pumpWidget(chat());
      await settleIo(tester, rounds: 4);

      await tester.tap(find.byKey(const Key('composer-document')));
      await settleIo(tester, rounds: 6);
      expect(documentCalls.single.method, 'pick');
      expect(find.text('Quote.pdf'), findsOneWidget, reason: 'named before it goes');
      expect(find.text('PDF · 14 B'), findsOneWidget);
      await tester.tap(find.byKey(const Key('documents-send')));
      await settleIo(tester, rounds: 40);

      final sent = uploads().single;
      expect(hasField(sent, 'content_type', 'file'), isTrue);
      expect(sent.body, contains('filename="Quote.pdf"'));
      final bubble = find.byKey(const Key('file-bubble'));
      expect(bubble, findsOneWidget);
      expect(find.descendant(of: bubble, matching: find.text('Quote.pdf')), findsOneWidget);

      await tester.tap(bubble);
      await settleIo(tester, rounds: 10);
      final open = documentCalls.where((c) => c.method == 'open').single;
      expect((open.arguments as Map)['path'] as String, endsWith('Quote.pdf'));
      expect((open.arguments as Map)['mime'], 'application/pdf');
      expect(fakeRequests.where((r) => r.uri.path.startsWith('/media/chat-files/')), isEmpty,
          reason: "the sender's own copy - no download");
    });

    testWidgets("one received is downloaded with this phone's sign-in, then opened",
        (tester) async {
      serve([
        {
          'role': 'seller',
          'content': 'The price list',
          'msg_type': 'file',
          'media_url': '/media/chat-files/f9',
          'file_name': 'Prices.xlsx',
          'file_size': 2048,
          'file_mime': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          'id': 'doc-9-$run',
          'created_at': _iso(DateTime.now().subtract(const Duration(minutes: 3))),
        },
      ], also: (uri) => uri.path == '/media/chat-files/f9' ? 'spreadsheet bytes' : null);
      await tester.pumpWidget(chat());
      await settleIo(tester, rounds: 4);

      final bubble = find.byKey(const Key('file-bubble'));
      expect(find.descendant(of: bubble, matching: find.text('Prices.xlsx')), findsOneWidget);
      expect(find.descendant(of: bubble, matching: find.text('Excel · 2 KB')), findsOneWidget);
      expect(find.descendant(of: bubble, matching: find.text('The price list')), findsOneWidget);
      expect(find.descendant(of: bubble, matching: find.byIcon(Icons.download_rounded)),
          findsOneWidget);

      await tester.tap(find.descendant(of: bubble, matching: find.text('Prices.xlsx')));
      await settleIo(tester, rounds: 20);
      expect(fakeRequests.where((r) => r.method == 'GET' && r.uri.path == '/media/chat-files/f9'),
          hasLength(1));
      final open = documentCalls.where((c) => c.method == 'open').single;
      expect((open.arguments as Map)['path'] as String, endsWith('Prices.xlsx'));
      // Kept: next time it opens from the phone.
      expect(find.descendant(of: bubble, matching: find.byIcon(Icons.open_in_new_rounded)),
          findsOneWidget);
    });
  });

  group('the photo frame', () {
    testWidgets("is the bubble's own colour, with the time and the caption inside",
        (tester) async {
      final at = DateTime.now().subtract(const Duration(minutes: 5));
      serve([
        {
          'role': 'seller',
          'content': 'Is this the one?',
          'msg_type': 'image',
          'media_url': 'data:image/png;base64,${base64Encode(_png(90, 160))}',
          'id': 'p1',
          'created_at': _iso(at),
        },
        {
          'role': 'buyer',
          'content': '',
          'msg_type': 'image',
          'media_url': 'data:image/png;base64,${base64Encode(_png(160, 90))}',
          'id': 'p2',
          'created_at': _iso(at.add(const Duration(minutes: 1))),
        },
      ]);
      await tester.pumpWidget(chat());
      await settle(tester);

      final frames = find.byKey(const Key('photo-frame'));
      expect(frames, findsNWidgets(2));
      final theirs = tester.widget<Container>(frames.first).decoration as BoxDecoration;
      final mine = tester.widget<Container>(frames.last).decoration as BoxDecoration;
      expect(theirs.gradient, isNull);
      expect(theirs.color, isNotNull, reason: "their card's colour");
      expect(mine.gradient, isNotNull, reason: 'my bubble gradient around my photo');
      expect(find.descendant(of: frames.first, matching: find.text('Is this the one?')),
          findsOneWidget, reason: 'the caption inside the frame');
      for (final i in [0, 1]) {
        expect(find.descendant(of: frames.at(i), matching: find.byKey(const Key('photo-meta-overlay'))),
            findsOneWidget);
      }
      // Every photo the frame's width, whatever its shape.
      for (final a in tester.widgetList<AspectImage>(find.byType(AspectImage))) {
        expect(a.fillWidth, isTrue);
      }
    });

    testWidgets('photos and documents fit a 320dp phone at a large text size',
        (tester) async {
      tester.view.physicalSize = const Size(320 * 2, 640 * 2);
      tester.view.devicePixelRatio = 2.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final at = DateTime.now().subtract(const Duration(minutes: 5));
      serve([
        {
          'role': 'seller',
          'content': 'The full price list, with delivery',
          'msg_type': 'file',
          'media_url': '/media/chat-files/f1',
          'file_name': 'Price list for November with delivery charges included.xlsx',
          'file_size': 734003,
          'id': 'd1',
          'created_at': _iso(at),
        },
        {
          'role': 'buyer',
          'content': 'And this one, from the side, with the charger and the box it came in',
          'msg_type': 'image',
          'media_url': 'data:image/png;base64,${base64Encode(_png(40, 90))}',
          'id': 'p1',
          'created_at': _iso(at.add(const Duration(minutes: 1))),
        },
      ]);
      await tester.pumpWidget(chat());
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('file-bubble')), findsOneWidget);
    });
  });

  group('photos that did not go, and photos taken back', () {
    testWidgets('a photo that did not go says so on it - it does not spin',
        (tester) async {
      await LocalChatStore.save('direct_listing-1_buyer-1', [
        {
          'role': 'buyer',
          'content': '',
          'msg_type': 'image',
          'media_url': 'data:image/png;base64,${base64Encode(_png(8, 8))}',
          'client_msg_id': 'unsent-$run',
          'created_at': _iso(DateTime.now().subtract(const Duration(minutes: 1))),
          'failed': true,
        },
      ]);
      serve([]);
      await tester.pumpWidget(chat());
      await settle(tester);

      final frame = find.byKey(const Key('photo-frame'));
      expect(frame, findsOneWidget);
      // The mark across the photo: it used to show the upload ring, as if
      // still on its way.
      expect(
          find.descendant(
              of: frame,
              matching: find.byWidgetPredicate((w) =>
                  w is Icon && w.icon == Icons.error_outline_rounded && w.size == 30)),
          findsOneWidget);
      expect(find.descendant(of: frame, matching: find.text('Not sent')), findsOneWidget);
    });

    testWidgets('a PNG left unsent by an earlier run goes again as a PNG', (tester) async {
      final clientId = 'png-$run';
      await tester.runAsync(() async {
        final outbox = Directory('${appDocs.path}/chat_outbox');
        await outbox.create(recursive: true);
        await File('${outbox.path}/$clientId.png').writeAsBytes(_png(12, 9));
        // A sidecar as builds before documents wrote it: no type in it.
        await File('${outbox.path}/$clientId.json').writeAsString(jsonEncode({
          'reply_to_message_id': null,
          'caption': null,
          'listing_id': 'listing-1',
          'store_id': null,
          'buyer_id': 'buyer-1',
        }));
      });
      await LocalChatStore.save('direct_listing-1_buyer-1', [
        {
          'role': 'buyer',
          'content': '',
          'msg_type': 'image',
          'media_url': 'data:image/png;base64,${base64Encode(_png(12, 9))}',
          'client_msg_id': clientId,
          'created_at': _iso(DateTime.now().subtract(const Duration(minutes: 1))),
          'failed': true,
        },
      ]);
      serve([], also: (uri) => uri.path == '/media/upload'
          ? {
              'id': 'srv-$clientId',
              'role': 'buyer',
              'msg_type': 'image',
              'media_url': 'data:image/png;base64,${base64Encode(_png(4, 4))}',
              'client_msg_id': clientId,
              'created_at': _iso(DateTime.now()),
            }
          : null);
      await tester.pumpWidget(chat());
      await settleIo(tester, rounds: 6);

      await tester.tap(find.byKey(const Key('unsent-bubble')));
      await settle(tester);
      await tester.tap(find.text('Try again'));
      await settleIo(tester, rounds: 20);

      final sent = uploads().single;
      expect(sent.body, contains('filename="image.png"'));
      expect(sent.body, contains('content-type: image/png'),
          reason: 'it was resent labelled "image/jpeg"');
    });

    testWidgets('unsending my photo takes it off this phone too', (tester) async {
      final id = 'mine-$run';
      await tester.runAsync(() async {
        await ChatMediaVault.storeBytes(messageId: id, bytes: _png(10, 10), ext: 'png');
      });
      expect(ChatMediaVault.fileForSync(messageId: id), isNotNull);
      final at = DateTime.now().subtract(const Duration(minutes: 2));
      serve([
        {
          'role': 'buyer',
          'content': '',
          'msg_type': 'image',
          'media_url': 'data:image/png;base64,${base64Encode(_png(10, 10))}',
          'id': id,
          'created_at': _iso(at),
        },
      ], also: (uri) => uri.path == '/negotiate/message/$id'
          ? {
              'message': {
                'id': id,
                'role': 'buyer',
                'content': '',
                'msg_type': 'deleted',
                'deleted': true,
                'created_at': _iso(at),
              },
            }
          : null);
      await tester.pumpWidget(chat());
      // Let the history's own writes (the photo kept for offline) finish
      // first, so they can't land after the unsend's removal.
      await settleIo(tester, rounds: 8);

      await tester.longPress(find.byKey(const Key('photo-frame')));
      await settle(tester);
      await tester.tap(find.text('Unsend'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Unsend'));
      await settleIo(tester, rounds: 10);

      expect(find.text('You deleted this message'), findsOneWidget);
      expect(ChatMediaVault.fileForSync(messageId: id), isNull,
          reason: 'the copy kept for offline viewing went with it');
    });
  });

  group('replies', () {
    testWidgets('replying to a reply quotes the reply, not what it answered', (tester) async {
      final at = DateTime.now().subtract(const Duration(minutes: 5));
      serve([
        {'role': 'buyer', 'content': 'Is it still available?', 'id': 'm1', 'created_at': _iso(at)},
        {
          'role': 'seller',
          'content': 'Yes, come today',
          'id': 'm2',
          'created_at': _iso(at.add(const Duration(minutes: 1))),
          'reply_to_message_id': 'm1',
          'reply_preview': {
            'message_id': 'm1',
            'sender_role': 'buyer',
            'msg_type': 'text',
            'preview': 'Is it still available?',
            'deleted': false,
          },
        },
      ]);
      await tester.pumpWidget(chat());
      await settle(tester);

      await tester.longPress(find.text('Yes, come today'));
      await settle(tester);
      await tester.tap(find.text('Reply'));
      await settle(tester);

      final preview = find.byKey(const Key('composer-reply-preview'));
      expect(find.descendant(of: preview, matching: find.text('Yes, come today')), findsOneWidget);
      expect(find.descendant(of: preview, matching: find.text('Is it still available?')),
          findsNothing);
    });
  });

  group('receipts', () {
    test('a send queued behind others reads "Sending", however long it waits', () {
      final long = DateTime.now().subtract(const Duration(minutes: 3));
      expect(
          receiptFor(sentAt: long, counterpartDeliveredAt: null, counterpartReadAt: null,
              pending: true, inFlight: true),
          MessageReceipt.sending);
      // Not queued, not answered, minutes old: it did not go.
      expect(
          receiptFor(sentAt: long, counterpartDeliveredAt: null, counterpartReadAt: null,
              pending: true),
          MessageReceipt.failed);
      // A failure reported is a failure, queued or not.
      expect(
          receiptFor(sentAt: long, counterpartDeliveredAt: null, counterpartReadAt: null,
              pending: true, inFlight: true, failed: true),
          MessageReceipt.failed);
    });

    testWidgets('on a photo the ticks stand alone; "Not sent" keeps its words', (tester) async {
      Future<void> show(MessageReceipt r) => tester.pumpWidget(MaterialApp(
          home: Scaffold(body: MessageReceiptIcon(receipt: r, light: true, compact: true))));
      await show(MessageReceipt.read);
      expect(find.text('Seen'), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
      expect(find.bySemanticsLabel('Seen'), findsWidgets);
      await show(MessageReceipt.failed);
      expect(find.text('Not sent'), findsOneWidget);
    });
  });
}
