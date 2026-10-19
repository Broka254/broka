// A photo's small file going missing no longer blanks the photo (2026-10-19).
//
// In production a card's thumbnail URL answered 404 while the same image's
// other sizes were fine, and the card showed its emoji: BrokaImage asked for
// one size and treated any failure as "no photo". Now a card tries thumb,
// then medium, then large, each URL at most once, and shows the emoji only
// when all of them fail. The network layer is replaced by
// support/fake_network_image.dart; nothing here touches a network.
import 'package:broka/features/categories/domain/category_visual.dart';
import 'package:broka/features/listings/domain/models/listing.dart';
import 'package:broka/models/listing_photo.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/broka_image.dart';
import 'package:broka/widgets/product_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_network_image.dart';

const _thumb = 'https://media.test/img/p1/thumb.webp';
const _medium = 'https://media.test/img/p1/medium.webp';
const _large = 'https://media.test/img/p1/large.webp';
const _placeholderKey = ValueKey('placeholder');

Widget _image(String? source, {List<String?> fallbacks = const []}) => BrokaImage(
      source,
      fallbacks: fallbacks,
      placeholder: const Text('no photo', key: _placeholderKey),
    );

Future<void> _show(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SizedBox(width: 200, height: 200, child: child)),
  ));
  await tester.pump();
}

void main() {
  FakeImageNetwork? net;

  FakeImageNetwork serve(Iterable<String> available, {Map<String, Object>? errors}) {
    final n = FakeImageNetwork(available: available, errors: errors)..install();
    net = n;
    return n;
  }

  tearDown(() {
    net?.uninstall();
    net = null;
  });

  group('the fallback chain', () {
    testWidgets('a missing thumbnail falls back to the medium size', (tester) async {
      final n = serve({_medium, _large});
      await _show(tester, _image(_thumb, fallbacks: [_medium, _large]));

      expect(n.loaded(_medium), findsOneWidget);
      expect(find.byKey(_placeholderKey), findsNothing);
      expect(n.requested, [_thumb, _medium]); // large was never needed
    });

    testWidgets('thumbnail and medium missing, large available', (tester) async {
      final n = serve({_large});
      await _show(tester, _image(_thumb, fallbacks: [_medium, _large]));

      expect(n.loaded(_large), findsOneWidget);
      expect(find.byKey(_placeholderKey), findsNothing);
      expect(n.requested, [_thumb, _medium, _large]);
    });

    testWidgets('every size missing shows the placeholder, each URL asked once', (tester) async {
      final n = serve(const []);
      await _show(tester, _image(_thumb, fallbacks: [_medium, _large]));
      await tester.pumpAndSettle(); // would time out if the chain kept retrying

      expect(find.byKey(_placeholderKey), findsOneWidget);
      expect(n.requested, [_thumb, _medium, _large]);
    });

    testWidgets('rebuilding does not ask for a failed file again', (tester) async {
      final n = serve({_medium});
      for (var i = 0; i < 3; i++) {
        await _show(tester, _image(_thumb, fallbacks: [_medium]));
      }

      expect(n.requested, [_thumb, _medium]);
    });

    testWidgets('a URL the backend repeats for a size an image lacks is asked once', (tester) async {
      final n = serve(const []);
      // asset_urls gives every size the same URL when an asset has one size.
      await _show(tester, _image(_medium, fallbacks: [_medium, _medium]));

      expect(n.requested, [_medium]);
      expect(find.byKey(_placeholderKey), findsOneWidget);
    });

    testWidgets('the same file by its relative and absolute spelling is asked once', (tester) async {
      final n = serve(const []);
      final absolute = '${ApiService.baseUrl}/media/i/img/p1/thumb.webp';
      await _show(tester, _image('/media/i/img/p1/thumb.webp', fallbacks: [absolute]));

      expect(n.requested, [absolute]);
    });

    testWidgets('null, empty and malformed entries are skipped without a crash', (tester) async {
      final n = serve({_medium});
      await _show(tester, _image(null, fallbacks: ['', '   ', 'https://', 'not a url', _medium]));

      expect(tester.takeException(), isNull);
      expect(n.loaded(_medium), findsOneWidget);
      expect(n.requested, [_medium]);
    });

    testWidgets('nothing usable at all is the placeholder, with no request', (tester) async {
      final n = serve(const []);
      for (final source in <String?>[null, '', '  ', 'https://', 'not a photo!']) {
        await _show(tester, _image(source));
        expect(find.byKey(_placeholderKey), findsOneWidget, reason: '$source');
      }
      expect(n.requested, isEmpty);
    });

    testWidgets('legacy base64 still renders as an image, with no request', (tester) async {
      final n = serve(const []);
      const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      await _show(tester, _image(png));
      expect(find.byType(Image), findsOneWidget);
      await _show(tester, _image('data:image/png;base64,$png'));
      expect(find.byType(Image), findsOneWidget);
      expect(n.requested, isEmpty);
    });
  });

  group('what is remembered about a failed file', () {
    testWidgets('a file that answered 404 is not asked for again by the next widget', (tester) async {
      final n = serve({_medium});
      await _show(tester, _image(_thumb, fallbacks: [_medium]));
      await tester.pumpWidget(const SizedBox()); // the card scrolls away
      await _show(tester, _image(_thumb, fallbacks: [_medium]));

      expect(n.requested, [_thumb, _medium, _medium]); // thumb once, medium per widget
      expect(n.loaded(_medium), findsOneWidget);
    });

    testWidgets('410 is remembered too, and so is a 404 that only the message carries', (tester) async {
      final n = serve({_large}, errors: {
        _thumb: const FakeHttpStatusException(410),
        _medium: FakeImageNetwork.notFoundMessageOnly(_medium),
      });
      for (var i = 0; i < 2; i++) {
        await _show(tester, _image(_thumb, fallbacks: [_medium, _large]));
        await tester.pumpWidget(const SizedBox());
      }

      expect(n.requested, [_thumb, _medium, _large, _large]);
    });

    testWidgets('a failure that says nothing about the file is not remembered', (tester) async {
      final n = serve({_medium}, errors: {
        _thumb: Exception('connection dropped'),
      });
      await _show(tester, _image(_thumb, fallbacks: [_medium]));
      await tester.pumpWidget(const SizedBox());
      await _show(tester, _image(_thumb, fallbacks: [_medium]));

      expect(n.requested, [_thumb, _medium, _thumb, _medium]);
    });

    testWidgets('a server error (500) is not remembered either', (tester) async {
      final n = serve({_medium}, errors: {_thumb: const FakeHttpStatusException(500)});
      await _show(tester, _image(_thumb, fallbacks: [_medium]));
      await tester.pumpWidget(const SizedBox());
      await _show(tester, _image(_thumb, fallbacks: [_medium]));

      expect(n.requested.where((u) => u == _thumb), hasLength(2));
    });

    testWidgets('the memory of a missing file expires', (tester) async {
      var now = DateTime(2026, 10, 19, 12);
      BrokaImage.clock = () => now;
      final n = serve({_medium});

      await _show(tester, _image(_thumb, fallbacks: [_medium]));
      await tester.pumpWidget(const SizedBox());
      now = now.add(const Duration(minutes: 9));
      await _show(tester, _image(_thumb, fallbacks: [_medium]));
      expect(n.requested.where((u) => u == _thumb), hasLength(1), reason: 'after 9 minutes');

      await tester.pumpWidget(const SizedBox());
      now = now.add(const Duration(minutes: 2));
      await _show(tester, _image(_thumb, fallbacks: [_medium]));
      expect(n.requested.where((u) => u == _thumb), hasLength(2), reason: 'after 11 minutes');
    });
  });

  group('URLs', () {
    test('an absolute URL is used exactly as given, signed query included', () {
      const signed = 'https://media.test/img/p1/thumb.webp?X-Amz-Signature=a%2Fb&X-Amz-Expires=60';
      expect(BrokaImage.resolveNetworkUrl(signed, 'https://api.test'), signed);
      expect(BrokaImage.resolveNetworkUrl('HTTPS://media.test/a.webp', 'https://api.test'),
          'HTTPS://media.test/a.webp');
      expect(BrokaImage.resolveNetworkUrl('  http://media.test/a.webp  ', 'https://api.test'),
          'http://media.test/a.webp');
    });

    test('an API-relative media path joins the base once, however the base is written', () {
      for (final base in ['https://api.test', 'https://api.test/', 'https://api.test//']) {
        expect(BrokaImage.resolveNetworkUrl('/media/i/img/p1/thumb.webp', base),
            'https://api.test/media/i/img/p1/thumb.webp',
            reason: base);
      }
      expect(BrokaImage.networkUrl('/media/i/img/p1/thumb.webp'),
          '${ApiService.baseUrl}/media/i/img/p1/thumb.webp');
    });

    test('a query string on an API-relative path is kept', () {
      expect(BrokaImage.resolveNetworkUrl('/media/i/img/p1/thumb.webp?v=2', 'https://api.test'),
          'https://api.test/media/i/img/p1/thumb.webp?v=2');
    });

    test('null, empty, hostless, relative-but-not-media and base64 are not URLs', () {
      for (final s in <String?>[
        null, '', '   ', 'https://', 'http:///x.webp', '/img/p1/thumb.webp', '/9j/4AAQSkZJRg',
        'data:image/png;base64,AAAA', 'ftp://media.test/a.webp', 'media.test/a.webp',
      ]) {
        expect(BrokaImage.resolveNetworkUrl(s, 'https://api.test'), isNull, reason: '$s');
      }
      // A media path with no base to join it to can't be loaded.
      expect(BrokaImage.resolveNetworkUrl('/media/i/img/p1/thumb.webp', ''), isNull);
    });
  });

  group('debug diagnostics', () {
    testWidgets('one line per failed URL, with host, path and error class only', (tester) async {
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => lines.add(message ?? '');
      addTearDown(() => debugPrint = original);
      serve({_medium});
      const signed = 'https://media.test/img/p1/thumb.webp?X-Amz-Signature=sekrit&token=t0k3n';

      await _show(tester, _image(signed, fallbacks: [_medium]));
      await _show(tester, _image(signed, fallbacks: [_medium])); // a rebuild: no second line

      expect(lines, hasLength(1));
      expect(lines.single, contains('media.test/img/p1/thumb.webp'));
      expect(lines.single, contains('FakeHttpStatusException'));
      expect(lines.single, contains('404'));
      for (final secret in ['sekrit', 't0k3n', 'X-Amz', '?']) {
        expect(lines.single, isNot(contains(secret)), reason: secret);
      }
    });

    test('redactUrl drops user info, query and fragment', () {
      expect(
        BrokaImage.redactUrl('https://user:pw@media.test:8443/img/p1/thumb.webp?X-Amz-Signature=s#frag'),
        'https://media.test:8443/img/p1/thumb.webp',
      );
      expect(BrokaImage.redactUrl('https://media.test/a.webp'), 'https://media.test/a.webp');
      expect(BrokaImage.redactUrl('not a url'), '<not a url>');
    });
  });

  group('ProductCard', () {
    Map<String, dynamic> photo(String id) => {
          'id': id,
          'thumb': 'https://media.test/img/$id/thumb.webp',
          'medium': 'https://media.test/img/$id/medium.webp',
          'large': 'https://media.test/img/$id/large.webp',
        };

    BrokaListing listing({Map<String, dynamic> extra = const {}}) => BrokaListing.fromJson({
          'id': 'l1', 'seller_id': 's1', 'name': 'Airtel 5G router', 'category': 'Electronics',
          'price': 1500, 'lat': 0, 'lng': 0,
          ...extra,
        });

    Future<void> pumpCard(WidgetTester tester, BrokaListing l) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 200, height: 340, child: ProductCard(item: l))),
      ));
      await tester.pump();
    }

    final emoji = CategoryVisuals.emojiFor('Electronics');

    testWidgets('thumbnail 404 with a working medium image: the photo shows, not the emoji', (tester) async {
      final n = serve({'https://media.test/img/c1/medium.webp'});
      await pumpCard(tester, listing(extra: {'cover': {...photo('c1'), 'kind': 'photo'}}));

      expect(n.loaded('https://media.test/img/c1/medium.webp'), findsOneWidget);
      expect(find.text(emoji), findsNothing);
      expect(n.requested, ['https://media.test/img/c1/thumb.webp', 'https://media.test/img/c1/medium.webp']);
    });

    testWidgets('thumbnail and medium unavailable, large available', (tester) async {
      final n = serve({'https://media.test/img/c1/large.webp'});
      await pumpCard(tester, listing(extra: {'cover': {...photo('c1'), 'kind': 'photo'}}));

      expect(n.loaded('https://media.test/img/c1/large.webp'), findsOneWidget);
      expect(find.text(emoji), findsNothing);
    });

    testWidgets('all sizes unavailable: the emoji placeholder appears, nothing throws', (tester) async {
      final n = serve(const []);
      await pumpCard(tester, listing(extra: {'cover': {...photo('c1'), 'kind': 'photo'}}));
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);
      expect(find.text(emoji), findsWidgets);
      expect(n.requested.toSet().length, n.requested.length, reason: 'no URL asked twice');
    });

    testWidgets('a card without a cover falls back through the first photo\'s sizes', (tester) async {
      final n = serve({'https://media.test/img/p9/medium.webp'});
      await pumpCard(tester, listing(extra: {'photos': [photo('p9')]}));

      expect(n.loaded('https://media.test/img/p9/medium.webp'), findsOneWidget);
      expect(find.text(emoji), findsNothing);
    });

    test('a photo entry with a wrongly typed id or kind still parses', () {
      final p = ListingPhoto.fromJson({
        'id': 5, 'thumb': 'https://media.test/t.webp', 'medium': 'https://media.test/m.webp',
        'large': 'https://media.test/l.webp', 'kind': 3,
      });
      expect(p, isNotNull);
      expect(p!.id, '');
      expect(p.kind, isNull);
      expect(ListingPhoto.listFromJson('nope'), isEmpty);
      expect(ListingPhoto.listFromJson(null), isEmpty);
    });

    testWidgets('null and malformed image fields give the placeholder without a request', (tester) async {
      final n = serve(const []);
      for (final extra in <Map<String, dynamic>>[
        {'cover': null, 'photos': null, 'verified_photos': null},
        {'cover': {'broken': true}, 'photos': [{'broken': true}, 'x', null]},
        {'cover': {...photo('c2'), 'thumb': null}},
      ]) {
        await pumpCard(tester, listing(extra: extra));
        expect(tester.takeException(), isNull, reason: '$extra');
        expect(find.text(emoji), findsWidgets, reason: '$extra');
      }
      expect(n.requested, isEmpty);
    });
  });
}
