// Publishing a listing from the sell wizard (LISTING_POSTING_REVIEW.md).
//
// What these cover, each broken before:
//   * a create that is sent again carries the same key, so the server
//     returns the listing it already made instead of posting it twice
//   * photos a restored draft no longer has on the server are uploaded
//     again, and the listing sent once more, instead of a dead end
//   * a gallery cover is uploaded once, however many times Activate is
//     pressed, and an AI cover (already stored) never
//   * the server's refusals read as sentences, not as raw JSON
//   * amounts are typed grouped ("2,500,000") and never parse to NaN
//   * the Location step picks a county the server knows
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/screens/sell_location_screen.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/services/listing_publisher.dart';
import 'package:broka/services/photo_upload_tracker.dart';
import 'package:broka/services/sell_wizard_data.dart';
import 'package:broka/utils/price_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, int status, {Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...headers});

class _FakeUploader extends ImageUploadService {
  int files = 0;
  int showcases = 0;

  UploadedImage _image(String id) => UploadedImage(
      id: id, thumb: '/t/$id', medium: '/m/$id', large: '/l/$id');

  @override
  Future<UploadedImage> uploadFile(File file,
      {required String purpose, void Function(double fraction)? onProgress}) async {
    if (purpose == ImagePurpose.listingShowcase) {
      showcases++;
      return _image('showcase-$showcases');
    }
    files++;
    return _image('photo-$files');
  }

  @override
  Future<UploadedImage> uploadBytes(List<int> bytes,
      {required String purpose, String filename = 'photo.jpg',
      void Function(double fraction)? onProgress}) async {
    showcases++;
    return _image('showcase-$showcases');
  }
}

SellWizardData _draft(_FakeUploader uploader) {
  final data = SellWizardData(photoUploads: PhotoUploadTracker(service: uploader))
    ..name = 'Toyota Vitz 2015'
    ..category = 'Automobiles'
    ..price = '850000'
    ..county = 'Nairobi'
    ..subcounty = 'Westlands';
  data.verifiedPhotos.addAll([File('/photos/front.jpg'), File('/photos/back.jpg')]);
  return data;
}

Map<String, dynamic> _listing(String id) => {'id': id, 'name': 'Toyota Vitz 2015'};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ListingPublisher', () {
    test('every attempt carries the draft key, so a repeat is not a second listing', () async {
      final keys = <String?>[];
      final bodies = <Map<String, dynamic>>[];
      final client = ApiClient(client: MockClient((req) async {
        keys.add(req.headers['X-Idempotency-Key']);
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return _json(_listing('l1'), 201);
      }));
      final uploader = _FakeUploader();
      final data = _draft(uploader);
      final publisher = ListingPublisher(client: client, uploader: uploader);

      await publisher.publish(data, lat: -1.28, lng: 36.82);
      await publisher.publish(data, lat: -1.28, lng: 36.82);

      expect(keys, [data.draftKey, data.draftKey]);
      expect(data.draftKey, hasLength(32));
      expect(bodies.first['photo_ids'], ['photo-1', 'photo-2']);
      expect(bodies.first['price'], 850000);
      expect(uploader.files, 2, reason: 'photos upload once');
    });

    test('a new draft gets a new key and a restored one keeps its own', () {
      final a = SellWizardData()..name = 'Radio';
      final b = SellWizardData()..name = 'Radio';
      expect(a.draftKey, isNot(b.draftKey));
      expect(SellWizardData.fromDraftJson(a.toDraftJson())!.draftKey, a.draftKey);
    });

    test("photos the server no longer has are uploaded again and the listing sent once more",
        () async {
      final sentIds = <List<dynamic>>[];
      final client = ApiClient(client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        sentIds.add(body['photo_ids'] as List<dynamic>);
        if (sentIds.length == 1) {
          return _json({'detail': "An image wasn't found. Please upload it again."}, 400,
              headers: {'x-error-code': 'IMAGE_GONE'});
        }
        return _json(_listing('l2'), 201);
      }));
      final uploader = _FakeUploader();
      final data = _draft(uploader);
      // A draft restored from last week: its ids are "done", but stale.
      data.photoUploads.restore({'/photos/front.jpg': 'old-1', '/photos/back.jpg': 'old-2'});

      final created = await ListingPublisher(client: client, uploader: uploader)
          .publish(data, lat: -1.28, lng: 36.82);

      expect(created['id'], 'l2');
      expect(sentIds, [
        ['old-1', 'old-2'],
        ['photo-1', 'photo-2'],
      ]);
    });

    test('it tries that only once', () async {
      var calls = 0;
      final client = ApiClient(client: MockClient((req) async {
        calls++;
        return _json({'detail': "An image wasn't found. Please upload it again."}, 400,
            headers: {'x-error-code': 'IMAGE_GONE'});
      }));
      final uploader = _FakeUploader();
      await expectLater(
        ListingPublisher(client: client, uploader: uploader)
            .publish(_draft(uploader), lat: 0, lng: 0),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'IMAGE_GONE')),
      );
      expect(calls, 2);
    });

    test('a gallery cover is uploaded once across retries, and again only when it changes', () async {
      var calls = 0;
      final showcaseIds = <Object?>[];
      final client = ApiClient(client: MockClient((req) async {
        calls++;
        showcaseIds.add((jsonDecode(req.body) as Map)['showcase_id']);
        return calls == 1 ? _json({'detail': 'busy'}, 503) : _json(_listing('l3'), 201);
      }));
      final uploader = _FakeUploader();
      final data = _draft(uploader)..setGalleryShowcase('/photos/cover.jpg');
      final publisher = ListingPublisher(client: client, uploader: uploader);

      await expectLater(publisher.publish(data, lat: 0, lng: 0), throwsA(isA<ApiException>()));
      await publisher.publish(data, lat: 0, lng: 0);
      expect(uploader.showcases, 1);
      expect(showcaseIds, ['showcase-1', 'showcase-1']);

      data.setGalleryShowcase('/photos/cover2.jpg');
      await publisher.publish(data, lat: 0, lng: 0);
      expect(uploader.showcases, 2);
    });

    test('an AI cover is already on the server: sent by id, never uploaded', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = ApiClient(client: MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return _json(_listing('l4'), 201);
      }));
      final uploader = _FakeUploader();
      final data = _draft(uploader)
        ..setAiShowcase(assetId: 'ai-cover', previewUrl: '/m/ai-cover', theme: 'studio');
      await ListingPublisher(client: client, uploader: uploader).publish(data, lat: 0, lng: 0);
      expect(uploader.showcases, 0);
      expect(bodies.single['showcase_id'], 'ai-cover');
      expect(bodies.single['showcase_image_source'], 'ai');
    });

    test('an AI cover the server no longer has is dropped, not a dead end', () async {
      final sent = <Object?>[];
      final client = ApiClient(client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        sent.add(body['showcase_id']);
        if (sent.length == 1) {
          return _json({'detail': "An image wasn't found. Please upload it again."}, 400,
              headers: {'x-error-code': 'IMAGE_GONE'});
        }
        return _json(_listing('l5'), 201);
      }));
      final uploader = _FakeUploader();
      final data = _draft(uploader)..setAiShowcase(assetId: 'gone', previewUrl: '/m/gone');
      await ListingPublisher(client: client, uploader: uploader).publish(data, lat: 0, lng: 0);
      expect(sent, ['gone', null]);
      expect(data.hasShowcase, isFalse);
    });

    test('the selling terms go with the listing', () {
      final data = SellWizardData()
        ..price = '3500'
        ..priceUnit = 'bag'
        ..quantity = '100'
        ..priceNegotiable = false
        ..deliveryAvailable = true
        ..deliveryNote = 'Within Nakuru'
        ..smsAlerts = false;
      final payload = ListingPublisher.payloadFor(
          data, photoIds: const ['p'], showcaseId: null, lat: 0, lng: 0);
      expect(payload['price'], 3500);
      expect(payload['price_unit'], 'bag');
      expect(payload['quantity'], 100);
      expect(payload['price_negotiable'], isFalse);
      expect(payload['delivery_available'], isTrue);
      expect(payload['delivery_note'], 'Within Nakuru');
      expect(payload['sms_alerts'], isFalse);

      // An auction sells the lot: no unit or quantity, and bidding is its
      // negotiation.
      data.type = 'auction';
      final auction = ListingPublisher.payloadFor(
          data, photoIds: const ['p'], showcaseId: null, lat: 0, lng: 0);
      expect(auction.containsKey('price_unit'), isFalse);
      expect(auction.containsKey('quantity'), isFalse);
      expect(auction['price_negotiable'], isTrue);
    });

    test('auction terms go only with an auction', () {
      final data = SellWizardData()
        ..price = '100000'
        ..reserve = '150000'
        ..minBidIncrement = '1000'
        ..auctionEndsAt = DateTime.utc(2030, 1, 1);
      Map<String, dynamic> payload() => ListingPublisher.payloadFor(
          data, photoIds: const ['p'], showcaseId: null, lat: 0, lng: 0);

      expect(payload().containsKey('reserve_price'), isFalse);
      data.type = 'auction';
      expect(payload()['reserve_price'], 150000);
      expect(payload()['min_bid_increment'], 1000);
      expect(payload()['auction_ends_at'], '2030-01-01T00:00:00.000Z');
    });
  });

  group('ApiClient errors', () {
    Future<ApiException> refusal(http.Response response) async {
      final client = ApiClient(client: MockClient((_) async => response));
      try {
        await client.post('/listings/', {});
      } on ApiException catch (e) {
        return e;
      }
      fail('expected an ApiException');
    }

    test('a structured detail gives its message and code, not raw JSON', () async {
      final e = await refusal(_json(
          {'detail': {'code': 'WINDOW_IN_PAST', 'message': 'The closing time has already passed.'}},
          422));
      expect(e.message, 'The closing time has already passed.');
      expect(e.code, 'WINDOW_IN_PAST');
    });

    test("a validation error reads as a sentence", () async {
      final own = await refusal(_json({'detail': [
        {'loc': ['body', 'name'], 'msg': 'Give the listing a name of at least 3 characters.'},
      ]}, 422));
      expect(own.message, 'Give the listing a name of at least 3 characters.');
      final generic = await refusal(_json({'detail': [
        {'loc': ['body', 'reserve_price'], 'msg': 'Input should be a finite number'},
      ]}, 422));
      expect(generic.message, 'Reserve price: Input should be a finite number');
    });

    test('the X-Error-Code header is the code', () async {
      final e = await refusal(_json({'detail': 'gone'}, 400, headers: {'x-error-code': 'IMAGE_GONE'}));
      expect(e.message, 'gone');
      expect(e.code, 'IMAGE_GONE');
    });

    test('extra headers are sent with the auth header', () async {
      late http.Request seen;
      final client = ApiClient(client: MockClient((req) async {
        seen = req;
        return _json({}, 201);
      }));
      await client.saveToken('token');
      await client.post('/listings/', {}, headers: {'X-Idempotency-Key': 'k1'});
      expect(seen.headers['X-Idempotency-Key'], 'k1');
      expect(seen.headers['Authorization'], 'Bearer token');
    });
  });

  group('Amounts', () {
    TextEditingValue type(String text) => const KesInputFormatter()
        .formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: text));

    test('are grouped as typed and keep only digits', () {
      expect(type('2500000').text, '2,500,000');
      expect(type('2,500,000.50').text, '250,000,050');
      expect(type('00450').text, '450');
      expect(type('abc').text, '');
    });

    test('parse from what the field shows, and never to NaN', () {
      expect(parseKesInput('2,500,000'), 2500000);
      expect(parseKesInput(' 850000 '), 850000);
      expect(parseKesInput('NaN'), isNull);
      expect(parseKesInput('Infinity'), isNull);
      expect(parseKesInput(''), isNull);
    });
  });

  group('Location step', () {
    Future<SellWizardData> open(WidgetTester tester, {String county = '', String area = ''}) async {
      // A phone: 360 x 800 logical pixels.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final data = SellWizardData()
        ..county = county
        ..subcounty = area;
      // Reduced motion: the step's constellation backdrop loops forever
      // otherwise, and pumpAndSettle would never settle.
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: SellLocationScreen(data: data),
      ));
      return data;
    }

    testWidgets('a county and area are picked from the list', (tester) async {
      final data = await open(tester);
      await tester.tap(find.byKey(const Key('sell-county-picker')));
      await tester.pumpAndSettle();
      // In the sheet: "Mombasa" is also a quick pick on the step itself.
      final inSheet = find.descendant(
          of: find.byType(BottomSheet), matching: find.text('Mombasa'));
      await tester.scrollUntilVisible(inSheet, 200,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(inSheet);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sell-area-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nyali'));
      await tester.pumpAndSettle();
      expect(data.county, 'Mombasa');
      expect(data.subcounty, 'Nyali');
      expect(data.location, 'Nyali, Mombasa');
    });

    testWidgets('a restored draft keeps a county it can read, spelt properly', (tester) async {
      await open(tester, county: 'nairobi', area: 'westlands');
      expect(find.text('Nairobi'), findsOneWidget);
      expect(find.text('Westlands'), findsOneWidget);
    });

    testWidgets('a county typed wrong is picked again before going on', (tester) async {
      final data = await open(tester, county: 'Nbi', area: 'Town');
      await tester.tap(find.text('NEXT'));
      await tester.pump();
      expect(find.text('Choose the county the item is in.'), findsOneWidget);
      expect(data.county, 'Nbi', reason: 'nothing overwritten until a county is chosen');
    });

    testWidgets('a popular county is one tap away', (tester) async {
      final data = await open(tester);
      await tester.tap(find.byKey(const Key('sell-county-quick-Nakuru')));
      await tester.pumpAndSettle();
      expect(data.county, 'Nakuru');
      // Chosen: the quick picks make way.
      expect(find.byKey(const Key('sell-county-quick-Nakuru')), findsNothing);
      await tester.tap(find.byKey(const Key('sell-area-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Njoro'));
      await tester.pumpAndSettle();
      expect(data.location, 'Njoro, Nakuru');
      expect(find.text('Njoro, Nakuru'), findsOneWidget, reason: 'what buyers see');
    });

    testWidgets('an area the list lacks can be typed', (tester) async {
      final data = await open(tester, county: 'Kiambu');
      await tester.tap(find.byKey(const Key('sell-area-picker')));
      await tester.pumpAndSettle();
      // The sheet's search box (the list is longer than a screen).
      await tester.enterText(find.byType(TextField).last, 'listed');
      await tester.pumpAndSettle();
      await tester.tap(find.text("My area isn't listed"));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sell-area-field')), 'Tatu City');
      expect(data.county, 'Kiambu');
      expect(data.subcounty, 'Tatu City');
    });
  });
}
