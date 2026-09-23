// Image uploads and image display (Online Stores phase 1).
//
// Photos used to be base64-encoded on the phone and sent all at once inside
// the create-listing request, so one weak connection lost the whole listing.
// Now each photo uploads by itself as soon as it's taken, and the listing is
// created with the returned ids. These tests cover that path end to end on
// the client, and the widget that displays whatever shape of image the
// backend sends (stored-image URLs, or base64 from not-yet-converted rows).
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/listings/domain/models/listing.dart';
import 'package:broka/models/listing_photo.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/services/photo_upload_tracker.dart';
import 'package:broka/widgets/broka_image.dart';
import 'package:broka/widgets/product_card.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _uploaded(String id) => {
      'id': id,
      'thumb': '/media/i/img/$id/thumb.webp',
      'medium': '/media/i/img/$id/medium.webp',
      'large': '/media/i/img/$id/large.webp',
      'width': 800,
      'height': 600,
      'purpose': 'listing_photo',
    };

// A 1x1 PNG, so "is this base64 an image" has a real answer.
const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

class _FakeUploader extends ImageUploadService {
  _FakeUploader(this.answer);

  /// Called once per upload attempt; return an id or throw.
  final Future<String> Function(String path) answer;
  final List<String> attempts = [];

  @override
  Future<UploadedImage> uploadFile(File file,
      {required String purpose, void Function(double fraction)? onProgress}) async {
    attempts.add(file.path);
    onProgress?.call(0.5);
    final id = await answer(file.path);
    return UploadedImage.fromJson(_uploaded(id));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ApiClient.uploadFile', () {
    test('sends the file and fields as multipart and reports progress to the end', () async {
      late http.Request seen;
      final client = ApiClient(client: MockClient((req) async {
        seen = req;
        return _json(_uploaded('a1'), 201);
      }));
      await client.saveToken('token');
      final progress = <int>[];
      int? total;

      final body = await client.uploadFile('/media/images',
          bytes: List<int>.filled(4000, 7), filename: 'photo.jpg',
          fields: {'purpose': 'listing_photo'},
          onProgress: (sent, t) {
            progress.add(sent);
            total = t;
          });

      expect((body as Map)['id'], 'a1');
      expect(seen.headers['content-type'], startsWith('multipart/form-data'));
      expect(seen.headers['Authorization'], 'Bearer token');
      final text = utf8.decode(seen.bodyBytes, allowMalformed: true);
      expect(text, contains('name="purpose"'));
      expect(text, contains('listing_photo'));
      expect(text, contains('name="file"; filename="photo.jpg"'));
      expect(text, contains('content-type: image/jpeg'));
      expect(progress, isNotEmpty);
      expect(progress.last, total);
    });

    test('an expired session is renewed and the upload rebuilt and resent', () async {
      final sent = <String?>[];
      final client = ApiClient(client: MockClient((req) async {
        sent.add(req.headers['Authorization']);
        return req.headers['Authorization'] == 'Bearer fresh'
            ? _json(_uploaded('a2'), 201)
            : _json({'detail': 'expired'}, 401);
      }));
      await client.saveToken('old');
      client.onUnauthorized = () async {
        await client.saveToken('fresh');
        return true;
      };
      final body = await client.uploadFile('/media/images',
          bytes: const [1, 2, 3], filename: 'a.png', fields: {'purpose': 'store_logo'});
      expect((body as Map)['id'], 'a2');
      expect(sent, ['Bearer old', 'Bearer fresh']);
    });
  });

  group('ImageUploadService', () {
    test('a server error is retried once', () async {
      var calls = 0;
      final service = ImageUploadService(client: ApiClient(client: MockClient((req) async {
        calls++;
        return calls == 1 ? _json({'detail': 'busy'}, 503) : _json(_uploaded('b1'), 201);
      })));
      final img = await service.uploadBytes(const [1, 2], purpose: ImagePurpose.listingPhoto);
      expect(img.id, 'b1');
      expect(calls, 2);
    });

    test('a refusal is not retried: the same bytes get the same answer', () async {
      var calls = 0;
      final service = ImageUploadService(client: ApiClient(client: MockClient((req) async {
        calls++;
        return _json({'detail': "That file isn't an image we can read."}, 422);
      })));
      await expectLater(
        service.uploadBytes(const [1, 2], purpose: ImagePurpose.listingPhoto),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 422)),
      );
      expect(calls, 1);
    });
  });

  group('PhotoUploadTracker', () {
    late Directory dir;
    late List<File> files;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('uploads');
      files = [
        for (var i = 0; i < 3; i++) await File('${dir.path}/p$i.jpg').writeAsBytes([i]),
      ];
    });
    tearDown(() => dir.delete(recursive: true));

    test('uploads start on their own and publishing gets the ids in order', () async {
      final fake = _FakeUploader((path) async => 'id-${path.split('/').last}');
      final tracker = PhotoUploadTracker(service: fake);
      for (final f in files.reversed) {
        tracker.start(f);
      }
      final ids = await tracker.idsFor(files);
      expect(ids, ['id-p0.jpg', 'id-p1.jpg', 'id-p2.jpg']);
      expect(tracker.stateFor(files[0])!.status, PhotoUploadStatus.done);
      // Already uploaded: asking again uploads nothing more.
      await tracker.idsFor(files);
      expect(fake.attempts, hasLength(3));
    });

    test('a failed upload is retried when publishing', () async {
      var failNext = true;
      final fake = _FakeUploader((path) async {
        if (failNext) {
          failNext = false;
          throw const SocketException('offline');
        }
        return 'ok';
      });
      final tracker = PhotoUploadTracker(service: fake);
      tracker.start(files[0]);
      await pumpEventQueue();
      expect(tracker.stateFor(files[0])!.status, PhotoUploadStatus.failed);
      expect(await tracker.idsFor([files[0]]), ['ok']);
    });

    test('a photo that still fails is named, so the user knows which one', () async {
      final tracker = PhotoUploadTracker(
          service: _FakeUploader((path) async =>
              path.endsWith('p1.jpg') ? throw const SocketException('offline') : 'ok'));
      await expectLater(
        tracker.idsFor(files),
        throwsA(isA<PhotoUploadIncomplete>().having((e) => e.index, 'index', 1)),
      );
    });

    test('a restored draft keeps its uploaded ids and uploads nothing again', () async {
      final fake = _FakeUploader((path) async => 'new');
      final tracker = PhotoUploadTracker(service: fake)
        ..restore({files[0].path: 'saved-0', files[1].path: 'saved-1'});
      tracker.start(files[0]);
      expect(await tracker.idsFor(files.sublist(0, 2)), ['saved-0', 'saved-1']);
      expect(fake.attempts, isEmpty);
      expect(tracker.uploadedIds, {files[0].path: 'saved-0', files[1].path: 'saved-1'});
    });
  });

  group('BrokaImage', () {
    test('resolves backend paths against the API and leaves absolute URLs alone', () {
      expect(BrokaImage.networkUrl('/media/i/img/x/thumb.webp'),
          '${ApiService.baseUrl}/media/i/img/x/thumb.webp');
      expect(BrokaImage.networkUrl('https://media.broka.co.ke/img/x/thumb.webp'),
          'https://media.broka.co.ke/img/x/thumb.webp');
      expect(BrokaImage.networkUrl(_pngBase64), isNull);
    });

    test('decodes data URIs and bare base64, and rejects junk', () {
      expect(BrokaImage.inlineBytes(_pngBase64), isNotNull);
      expect(BrokaImage.inlineBytes('data:image/png;base64,$_pngBase64'), isNotNull);
      expect(BrokaImage.inlineBytes('not base64 at all!'), isNull);
      expect(BrokaImage.inlineBytes(null), isNull);
    });

    testWidgets('picks the right renderer for each shape', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Column(children: [
          const SizedBox(width: 40, height: 40, child: BrokaImage('https://media.broka.co.ke/a.webp')),
          const SizedBox(width: 40, height: 40, child: BrokaImage(_pngBase64)),
          SizedBox(width: 40, height: 40,
              child: BrokaImage('garbage!!', placeholder: Container(key: const Key('ph')))),
        ]),
      ));
      expect(find.byType(CachedNetworkImage), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      expect(find.byKey(const Key('ph')), findsOneWidget);
    });
  });

  group('Listing models', () {
    test('parse stored photos, the cover and the seller avatar', () {
      final l = BrokaListing.fromJson({
        'id': 'l1', 'seller_id': 's1', 'name': 'Phone', 'category': 'Electronics',
        'price': 1000, 'lat': 0, 'lng': 0,
        'photos': [_uploaded('p1'), _uploaded('p2'), {'broken': true}],
        'cover': {..._uploaded('p1'), 'kind': 'photo'},
        'seller_avatar_url': '/media/i/img/av/thumb.webp',
        'verified_photos': null,
      });
      expect(l.photos.map((p) => p.id), ['p1', 'p2']);
      expect(l.cover!.kind, 'photo');
      expect(l.sellerAvatarUrl, '/media/i/img/av/thumb.webp');
    });

    testWidgets('a product card shows the stored cover, not the legacy base64', (tester) async {
      final l = BrokaListing.fromJson({
        'id': 'l3', 'seller_id': 's1', 'name': 'Phone', 'category': 'Electronics',
        'price': 1000, 'lat': 0, 'lng': 0,
        'cover': {..._uploaded('c1'), 'kind': 'photo'},
        'verified_photos': _pngBase64,
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 200, height: 340, child: ProductCard(item: l))),
      ));
      final images = tester.widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage));
      expect(images.map((i) => i.imageUrl), contains(endsWith('/media/i/img/c1/thumb.webp')));
    });

    test('a listing the backend has not converted yet has no stored photos', () {
      final l = BrokaListing.fromJson({
        'id': 'l2', 'seller_id': 's1', 'name': 'Phone', 'category': 'Electronics',
        'price': 1000, 'lat': 0, 'lng': 0, 'verified_photos': _pngBase64,
      });
      expect(l.photos, isEmpty);
      expect(l.cover, isNull);
      expect(ListingPhoto.fromJson(null), isNull);
    });
  });
}
