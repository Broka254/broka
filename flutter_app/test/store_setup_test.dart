// Online Stores phase 2 on the phone: setting a store up, sharing it, and
// the owner's dashboard.
//
// HTTP goes through a MockClient behind an injected ApiClient, the share
// bridge through a mocked MethodChannel, and uploads through a fake
// uploader, so every test runs offline and deterministically.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/listings/data/repositories/listings_repository.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/data/store_share.dart';
import 'package:broka/features/stores/domain/kenya_locations.dart';
import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/domain/store_categories.dart';
import 'package:broka/features/stores/presentation/my_store_screen.dart';
import 'package:broka/features/stores/presentation/setup/store_setup_controller.dart';
import 'package:broka/features/stores/presentation/setup/store_setup_screen.dart';
import 'package:broka/features/stores/presentation/setup/store_setup_steps.dart';
import 'package:broka/features/stores/presentation/store_launched_screen.dart';
import 'package:broka/features/stores/presentation/widgets/store_share_card.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/image_upload_service.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:broka/widgets/wizard_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _owner({
  String tier = 'long_term',
  String accountType = 'buyer_seller',
  String? email,
  bool emailVerified = false,
}) =>
    {
      'id': 'u1',
      'name': 'Jane Wanjiru',
      'account_type': accountType,
      'seller_tier': tier,
      'business_name': 'Clanix Electronics',
      'business_category': 'Phones & Accessories',
      'business_location': 'Moi Avenue, Nairobi',
      'business_description': 'Phones and accessories, genuine only.',
      'email': email,
      'email_verified': emailVerified,
    };

Map<String, dynamic> _storeJson({
  String slug = 'clanix',
  bool active = true,
  String? email,
  bool emailVerified = false,
}) =>
    {
      'id': 's1',
      'name': 'Clanix Electronics',
      'slug': slug,
      'url': 'https://broka.co.ke/store/$slug',
      'category': 'Electronics',
      'description': 'Phones',
      'county': 'Nairobi',
      'subcounty': 'Starehe',
      'location_description': 'Moi Avenue',
      'business_email': email,
      'business_email_verified': emailVerified,
      'logo': null,
      'cover': null,
      'photo_images': [],
      'logo_url': null,
      'photos': [],
      'owner': {'verified': true, 'rating': 4.8, 'completed_deals': 12,
          'member_since': '2025-01-10T00:00:00'},
      'is_active': active,
      'listing_count': 3,
    };

Map<String, dynamic> _stats() => {
      'days': 7,
      'visits': {
        'total': 9,
        'by_day': [
          for (var i = 0; i < 7; i++)
            {'date': DateTime(2026, 9, 18 + i).toIso8601String().substring(0, 10),
              'count': i == 6 ? 5 : (i == 3 ? 4 : 0)},
        ],
        'by_source': {'whatsapp': 6, 'tiktok': 3, 'instagram': 0, 'facebook': 0, 'x': 0,
            'qr': 0, 'direct': 0, 'other': 0},
        'by_surface': {'app': 2, 'web': 7},
      },
      'shares': {'total': 4, 'by_channel': {'whatsapp': 4}},
    };

/// A backend: [routes] maps "METHOD /path" to a handler. Every request is
/// recorded.
class FakeBackend {
  FakeBackend(this.routes);
  final Map<String, FutureOr<http.Response> Function(http.Request)> routes;
  final List<http.Request> requests = [];

  late final client = ApiClient(client: MockClient((req) async {
    requests.add(req);
    final handler = routes['${req.method} ${req.url.path}'];
    if (handler == null) return _json({'detail': 'no route ${req.method} ${req.url.path}'}, 404);
    return handler(req);
  }));

  late final repo = StoresRepository(client: client);

  Iterable<Map<String, dynamic>> bodiesFor(String method, String path) => requests
      .where((r) => r.method == method && r.url.path == path)
      .map((r) => jsonDecode(r.body) as Map<String, dynamic>);
}

class _FakeUploader extends ImageUploadService {
  final List<String> purposes = [];
  var _n = 0;

  @override
  Future<UploadedImage> uploadFile(File file,
      {required String purpose, void Function(double fraction)? onProgress}) async {
    purposes.add(purpose);
    final id = 'img${++_n}';
    return UploadedImage(id: id, thumb: '/media/i/img/$id/thumb.webp',
        medium: '/media/i/img/$id/medium.webp', large: '/media/i/img/$id/large.webp');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'u1';
  });

  group('Kenya locations', () {
    test('all 47 counties and 290 constituencies', () {
      expect(KenyaLocations.counties, hasLength(47));
      expect(KenyaLocations.counties.first, 'Mombasa');
      expect(KenyaLocations.counties.last, 'Nairobi');
      final all = KenyaLocations.subcountiesByCounty.values.expand((s) => s).toList();
      expect(all, hasLength(290));
      for (final entry in KenyaLocations.subcountiesByCounty.entries) {
        expect(entry.value.toSet(), hasLength(entry.value.length), reason: entry.key);
      }
    });

    test('lookups forgive spelling', () {
      expect(KenyaLocations.canonicalCounty('nairobi'), 'Nairobi');
      expect(KenyaLocations.canonicalCounty('Muranga'), "Murang'a");
      expect(KenyaLocations.canonicalCounty('Tharaka-Nithi'), 'Tharaka Nithi');
      expect(KenyaLocations.canonicalCounty('Atlantis'), isNull);
      expect(KenyaLocations.canonicalSubcounty('Nairobi', 'langata'), "Lang'ata");
      expect(KenyaLocations.guessCounty('Moi Avenue, Nairobi'), 'Nairobi');
      expect(KenyaLocations.guessCounty('Ruiru town'), 'Kiambu');
      expect(KenyaLocations.guessCounty('somewhere'), isNull);
    });
  });

  group('Store categories', () {
    test('signup business categories map onto BROKA categories', () {
      expect(StoreCategories.all, hasLength(21));
      expect(StoreCategories.fromAny('electronics'), 'Electronics');
      expect(StoreCategories.fromAny('Automotive'), 'Automobiles');
      expect(StoreCategories.fromAny('Vehicles'), 'Automobiles');
      expect(StoreCategories.fromAny('Food & Beverages'), 'Food & Beverages');
      expect(StoreCategories.fromAny('Clothing & Fashion'), 'Fashion');
      expect(StoreCategories.fromAny('Wholesale'), 'Business & Industrial');
      expect(StoreCategories.fromAny('Supermarket'), 'Other');
      expect(StoreCategories.fromAny(''), isNull);
    });
  });

  group('Store model', () {
    test('parses the phase 2 payload', () {
      final s = Store.fromJson(_storeJson(email: 'a@b.co', emailVerified: true));
      expect(s.category, 'Electronics');
      expect(s.displayUrl, 'broka.co.ke/store/clanix');
      expect(s.shareUrl('whatsapp'), 'https://broka.co.ke/store/clanix?via=whatsapp');
      expect(s.owner!.completedDeals, 12);
      expect(s.businessEmailVerified, isTrue);
      expect(s.locationLine, 'Starehe, Nairobi');
    });

    test('an older backend: specialization and no url', () {
      final json = _storeJson()..remove('url')..remove('category');
      json['specialization'] = 'Electronics';
      final s = Store.fromJson(json);
      expect(s.category, 'Electronics');
      expect(s.url, 'https://broka.co.ke/store/clanix');
    });

    test('stats fill the week', () {
      final s = StoreStats.fromJson(_stats());
      expect(s.visits, 9);
      expect(s.visitsByDay, hasLength(7));
      expect(s.visitsBySource['whatsapp'], 6);
      expect(s.sharesByChannel['whatsapp'], 4);
    });
  });

  group('Link names', () {
    test('suggestions from a store name', () {
      expect(StoreSetupController.suggestLink('Clanix Electronics'), 'clanix-electronics');
      expect(StoreSetupController.suggestLink("Mama Mboga's Shop!!"), 'mama-mboga-s-shop');
      expect(StoreSetupController.suggestLink('A'), '');
      expect(StoreSetupController.suggestLink('x' * 50).length, 30);
    });

    test('the same rules as the server', () {
      expect(StoreSetupController.linkProblem('clanix'), isNull);
      expect(StoreSetupController.linkProblem('ab'), contains('at least'));
      expect(StoreSetupController.linkProblem('-ab'), contains('hyphen'));
      expect(StoreSetupController.linkProblem('a--b'), contains('one hyphen'));
      expect(StoreSetupController.linkProblem('a b c'), contains('letters'));
    });
  });

  group('StoreSetupController', () {
    test('a long-term seller starts from their signup details', () async {
      final backend = FakeBackend({
        'GET /auth/me': (_) => _json(_owner()),
        'GET /stores/name-available': (r) => _json({
              'name': r.url.queryParameters['name'], 'available': true,
              'url': 'https://broka.co.ke/store/${r.url.queryParameters['name']}'}),
      });
      final c = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
      await c.load();
      expect(c.showBusinessStep, isFalse);
      expect(c.steps.first, StoreSetupStep.name);
      expect(c.name, 'Clanix Electronics');
      expect(c.slug, 'clanix-electronics');
      expect(c.category, 'Electronics');
      expect(c.county, 'Nairobi');
      expect(c.description, contains('genuine'));
      await pumpEventQueue();
      expect(c.linkStatus, LinkStatus.available);
      expect(c.validate(StoreSetupStep.link), isNull);
      expect(c.validate(StoreSetupStep.location), 'Choose or type your area.');
    });

    test('a short-term seller adds business details first', () async {
      final backend = FakeBackend({
        'GET /auth/me': (_) => _json({..._owner(tier: 'short_term'),
            'business_name': null, 'business_category': null, 'business_location': null}),
        'POST /auth/upgrade-to-seller': (r) {
          final b = jsonDecode(r.body) as Map;
          return _json({..._owner(), 'business_name': b['business_name'],
              'business_category': b['business_category']});
        },
        'GET /stores/name-available': (r) => _json({'name': r.url.queryParameters['name'],
            'available': true}),
      });
      final c = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
      await c.load();
      expect(c.steps.first, StoreSetupStep.business);
      expect(await c.upgrade(), 'Enter your business name.');
      c
        ..setBusinessName('Wanjiru Hardware')
        ..setBusinessCategory('Construction')
        ..setBusinessLocation('Ruiru');
      expect(await c.upgrade(), isNull);
      expect(c.businessDone, isTrue);
      expect(c.validate(StoreSetupStep.business), isNull);
      expect(c.name, 'Wanjiru Hardware');
      expect(c.slug, 'wanjiru-hardware');
      expect(c.category, 'Construction');
      expect(c.county, 'Kiambu');
      final sent = backend.bodiesFor('POST', '/auth/upgrade-to-seller').single;
      expect(sent['business_category'], 'Construction');
      expect(ApiService.currentUserAccountType, 'buyer_seller');
    });

    test('the live link check waits for typing to stop and ignores stale answers', () async {
      final answers = <String, Completer<http.Response>>{};
      final backend = FakeBackend({
        'GET /auth/me': (_) => _json(_owner()),
        'GET /stores/name-available': (r) {
          final name = r.url.queryParameters['name']!;
          return (answers[name] = Completer<http.Response>()).future;
        },
      });
      final c = StoreSetupController(repository: backend.repo,
          linkCheckDelay: const Duration(milliseconds: 20));
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      c.setSlug('clan');
      c.setSlug('clanix');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      // Only the last value was sent (the initial one from the name aside).
      expect(answers.keys, containsAll(['clanix']));
      expect(answers.keys, isNot(contains('clan')));

      // The initial check (for the prefilled link) answers late: ignored.
      answers['clanix-electronics']?.complete(_json({'name': 'clanix-electronics',
          'available': true}));
      await pumpEventQueue();
      expect(c.linkStatus, LinkStatus.checking);

      answers['clanix']!.complete(_json({'name': 'clanix', 'available': false,
          'reason': 'That link is already taken.', 'suggestion': 'clanix-2'}));
      await pumpEventQueue();
      expect(c.linkStatus, LinkStatus.unavailable);
      expect(c.linkSuggestion, 'clanix-2');
      expect(c.validate(StoreSetupStep.link), 'That link is already taken.');

      c.useSuggestedLink();
      expect(c.slug, 'clanix-2');
      expect(c.linkStatus, LinkStatus.checking);
      c.dispose();
    });

    test('an invalid link is caught without asking the server', () async {
      final backend = FakeBackend({
        'GET /auth/me': (_) => _json({..._owner(), 'business_name': null}),
      });
      final c = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
      await c.load();
      c.setSlug('ab');
      await pumpEventQueue();
      expect(c.linkStatus, LinkStatus.invalid);
      expect(c.linkMessage, contains('at least 3'));
      expect(backend.requests.where((r) => r.url.path == '/stores/name-available'), isEmpty);
    });

    test('the business email is verified with a code, and changing it undoes that', () async {
      final backend = FakeBackend({
        'GET /auth/me': (_) => _json(_owner(email: 'jane@mail.com', emailVerified: true)),
        'GET /stores/name-available': (r) => _json({'name': 'x', 'available': true}),
        'POST /stores/email/request-code': (_) => _json({'ok': true, 'debug_code': '123456'}),
        'POST /stores/email/verify': (r) {
          final b = jsonDecode(r.body) as Map;
          return b['code'] == '123456'
              ? _json({'ok': true, 'email_verify_token': 'tok'})
              : _json({'detail': 'Incorrect code'}, 400);
        },
      });
      final c = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
      await c.load();
      expect(c.validate(StoreSetupStep.email), isNull, reason: 'optional');
      expect(c.canUseAccountEmail, isTrue);

      c.setEmail('sales@clanix.co.ke');
      expect(c.validate(StoreSetupStep.email), contains('Verify'));
      expect(await c.sendEmailCode(), isNull);
      expect(c.emailCodeSent, isTrue);
      expect(c.debugEmailCode, '123456');
      expect(await c.verifyEmailCode('000000'), 'Incorrect code');
      expect(await c.verifyEmailCode('123456'), isNull);
      expect(c.emailVerified, isTrue);
      expect(c.validate(StoreSetupStep.email), isNull);

      c.setEmail('other@clanix.co.ke');
      expect(c.emailVerified, isFalse);
      c.useAccountEmail();
      expect(c.email, 'jane@mail.com');
      expect(c.emailVerified, isTrue, reason: 'the account email is already verified');
    });

    test('launching sends the link, the details, uploaded image ids and the email proof',
        () async {
      final dir = await Directory.systemTemp.createTemp('store');
      addTearDown(() => dir.delete(recursive: true));
      final logo = await File('${dir.path}/logo.png').writeAsBytes([1]);
      final photo = await File('${dir.path}/p.jpg').writeAsBytes([2]);
      final backend = FakeBackend({
        'GET /auth/me': (_) => _json(_owner()),
        'GET /stores/name-available': (r) => _json({'name': r.url.queryParameters['name'],
            'available': true}),
        'POST /stores/email/request-code': (_) => _json({'ok': true}),
        'POST /stores/email/verify': (_) => _json({'email_verify_token': 'tok'}),
        'POST /stores': (_) => _json(_storeJson(slug: 'clanix-electronics'), 201),
      });
      final uploader = _FakeUploader();
      final c = StoreSetupController(repository: backend.repo, uploader: uploader,
          linkCheckDelay: Duration.zero);
      await c.load();
      await pumpEventQueue();
      c
        ..setSubcounty('Starehe')
        ..setLandmark('Moi Avenue')
        ..setLogo(logo)
        ..addPhoto(photo)
        ..setEmail('sales@clanix.co.ke');
      await c.sendEmailCode();
      await c.verifyEmailCode('123456');
      await pumpEventQueue();
      expect(c.logo!.id, 'img1');

      final (store, problem) = await c.launch();
      expect(problem, isNull);
      expect(store!.slug, 'clanix-electronics');
      final body = backend.bodiesFor('POST', '/stores').single;
      expect(body['slug'], 'clanix-electronics');
      expect(body['category'], 'Electronics');
      expect(body['county'], 'Nairobi');
      expect(body['subcounty'], 'Starehe');
      expect(body['location_description'], 'Moi Avenue');
      expect(body['logo_id'], 'img1');
      expect(body['photo_ids'], ['img2']);
      expect(body['cover_id'], isNull);
      expect(body['business_email'], 'sales@clanix.co.ke');
      expect(body['business_email_token'], 'tok');
      expect(uploader.purposes, ['store_logo', 'store_photo']);
      expect(await StoreSetupController.hasDraft(), isFalse, reason: 'draft cleared');
    });

    test('a link taken at the last moment sends the owner back to the link step', () async {
      final backend = FakeBackend({
        'GET /auth/me': (_) => _json(_owner()),
        'GET /stores/name-available': (r) => _json({'name': r.url.queryParameters['name'],
            'available': true}),
        'POST /stores': (_) => _json(
            {'detail': 'That store link was just taken. Choose another.'}, 409),
      });
      final c = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
      await c.load();
      await pumpEventQueue();
      c.setSubcounty('Starehe');
      final (store, problem) = await c.launch();
      expect(store, isNull);
      expect(problem!.step, StoreSetupStep.link);
      expect(c.linkStatus, LinkStatus.unavailable);
    });

    test('the draft survives leaving the wizard', () async {
      final backend = FakeBackend({
        'GET /auth/me': (_) => _json(_owner()),
        'GET /stores/name-available': (r) => _json({'name': r.url.queryParameters['name'],
            'available': true}),
      });
      final first = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
      await first.load();
      first
        ..setName('Clanix Phones')
        ..setSlug('clanix-phones')
        ..setCategory('Gaming')
        ..setSubcounty('Starehe');
      await first.saveDraft();
      first.dispose();
      expect(await StoreSetupController.hasDraft(), isTrue);

      final second = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
      await second.load();
      expect(second.name, 'Clanix Phones');
      expect(second.slug, 'clanix-phones');
      expect(second.slugEdited, isTrue);
      expect(second.category, 'Gaming');
      expect(second.subcounty, 'Starehe');
    });

    test('settings save only the part being edited', () async {
      final backend = FakeBackend({
        'PATCH /stores/s1': (r) => _json({..._storeJson(), ...jsonDecode(r.body) as Map}),
      });
      final c = StoreSetupController.edit(Store.fromJson(_storeJson()), repository: backend.repo);
      expect(c.validate(StoreSetupStep.link), isNull);
      c.setSlug('something-else');
      expect(c.slug, 'clanix', reason: "an open store's link can't change");
      c.setName('Clanix Phones & More');
      final (store, problem) = await c.saveSection(StoreSetupStep.name);
      expect(problem, isNull);
      expect(store!.name, 'Clanix Phones & More');
      expect(backend.bodiesFor('PATCH', '/stores/s1').single, {'name': 'Clanix Phones & More'});
    });
  });

  group('Sharing', () {
    late List<MethodCall> calls;
    late Map<String, Object?> answers;
    const channel = MethodChannel('test/share');

    setUp(() {
      calls = [];
      answers = {};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        final pkg = (call.arguments as Map)['package'];
        return answers['${call.method}:$pkg'] ?? answers[call.method];
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    });

    StoreShare make(FakeBackend backend, List<Uri> opened, {bool canOpen = true}) => StoreShare(
          channel: channel,
          repository: backend.repo,
          openUrl: (uri) async {
            opened.add(uri);
            return canOpen;
          },
        );

    test('WhatsApp gets a tagged link, and the share is counted', () async {
      final backend = FakeBackend({'POST /stores/s1/share': (_) => _json({'counted': true}, 202)});
      answers['shareText:com.whatsapp'] = 'shared';
      final share = make(backend, []);
      final outcome = await share.share(Store.fromJson(_storeJson()), ShareDestination.whatsapp);
      expect(outcome, ShareOutcome.shared);
      final args = calls.single.arguments as Map;
      expect(args['package'], 'com.whatsapp');
      expect(args['text'], contains('https://broka.co.ke/store/clanix?via=whatsapp'));
      await pumpEventQueue();
      expect(backend.bodiesFor('POST', '/stores/s1/share').single, {'channel': 'whatsapp'});
    });

    test('without WhatsApp installed, wa.me opens instead', () async {
      final backend = FakeBackend({'POST /stores/s1/share': (_) => _json({}, 202)});
      answers['shareText'] = 'unavailable';
      final opened = <Uri>[];
      final outcome = await make(backend, opened)
          .share(Store.fromJson(_storeJson()), ShareDestination.whatsapp);
      expect(outcome, ShareOutcome.shared);
      expect(calls.map((c) => (c.arguments as Map)['package']),
          ['com.whatsapp', 'com.whatsapp.w4b']);
      expect(opened.single.host, 'wa.me');
      expect(opened.single.queryParameters['text'], contains('via=whatsapp'));
    });

    test('TikTok copies the link and opens the app', () async {
      final backend = FakeBackend({'POST /stores/s1/share': (_) => _json({}, 202)});
      answers['openApp:com.zhiliaoapp.musically'] = 'opened';
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      final outcome = await make(backend, [])
          .share(Store.fromJson(_storeJson()), ShareDestination.tiktok);
      expect(outcome, ShareOutcome.copied);
      expect(copied, 'https://broka.co.ke/store/clanix?via=tiktok');
      expect(calls.single.method, 'openApp');
    });
  });

  group('Screens', () {
    testWidgets('the wizard is on the constellation and checks the link live', (tester) async {
      final backend = FakeBackend({
        'GET /auth/me': (_) => _json(_owner()),
        'GET /stores/mine': (_) => _json(null),
        'GET /stores/name-available': (r) {
          final name = r.url.queryParameters['name'];
          return name == 'clanix-electronics'
              ? _json({'name': name, 'available': false, 'reason': 'That link is already taken.',
                  'suggestion': 'clanix-electronics-2'})
              : _json({'name': name, 'available': true,
                  'url': 'https://broka.co.ke/store/$name'});
        },
      });
      final c = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
      await tester.pumpWidget(MaterialApp(
          home: StoreSetupScreen(controller: c, animateBackground: false)));
      await tester.pumpAndSettle();

      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.byType(WizardProgress), findsOneWidget);
      expect(find.text('Name your store'), findsOneWidget);
      expect(find.text('Clanix Electronics'), findsWidgets);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your link'), findsOneWidget);
      expect(find.text('That link is already taken.'), findsOneWidget);

      // Continue is refused until the link is available.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your link'), findsOneWidget);

      await tester.tap(find.byKey(const Key('use-suggested-link')));
      await tester.pumpAndSettle();
      expect(find.textContaining('clanix-electronics-2 is available'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('What you sell'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your link'), findsOneWidget);
      c.dispose();
    });

    testWidgets('My Store with no store invites setting one up', (tester) async {
      final backend = FakeBackend({'GET /stores/mine': (_) => _json(null)});
      await tester.pumpWidget(MaterialApp(
          home: MyStoreScreen(repository: backend.repo, animateBackground: false)));
      await tester.pumpAndSettle();
      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.text('Your own online store'), findsOneWidget);
      expect(find.byKey(const Key('open-store-setup')), findsOneWidget);
    });

    testWidgets('My Store shows the link, real visits, and pauses the store', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final backend = FakeBackend({
        'GET /stores/mine': (_) => _json(_storeJson()),
        'GET /stores/s1/stats': (_) => _json(_stats()),
        'POST /stores/s1/status': (r) =>
            _json(_storeJson(active: (jsonDecode(r.body) as Map)['is_active'] as bool)),
        'GET /listings/': (_) => _json([]),
      });
      await tester.pumpWidget(MaterialApp(
          home: MyStoreScreen(repository: backend.repo,
              listings: ListingsRepository(client: backend.client), animateBackground: false)));
      await tester.pumpAndSettle();

      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.byType(StoreShareCard), findsOneWidget);
      expect(find.byKey(const Key('store-link-text')), findsOneWidget);
      expect(find.text('broka.co.ke/store/clanix'), findsOneWidget);
      expect(find.byKey(const Key('visits-total')), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('WhatsApp'), findsWidgets);
      expect(find.text('Your store is open'), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-open-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();
      expect(backend.bodiesFor('POST', '/stores/s1/status').single, {'is_active': false});
      expect(find.text('Your store is paused'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Store link'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    });

    testWidgets('the QR code carries the tagged link', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(
          body: StoreQrCode(store: Store.fromJson(_storeJson())))));
      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      expect(qr, isNotNull);
      expect(find.bySemanticsLabel('QR code for Clanix Electronics'), findsOneWidget);
    });

    for (final size in const [Size(320, 568), Size(430, 932)]) {
      testWidgets('nothing overflows at ${size.width.toInt()}dp', (tester) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);

        final backend = FakeBackend({
          'GET /auth/me': (_) => _json(_owner(email: 'jane@mail.com', emailVerified: true)),
          'GET /stores/name-available': (r) => _json({'name': r.url.queryParameters['name'],
              'available': false, 'reason': 'That link is already taken.',
              'suggestion': 'clanix-electronics-2'}),
          'GET /stores/mine': (_) => _json(_storeJson()),
          'GET /stores/s1/stats': (_) => _json(_stats()),
          'GET /listings/': (_) => _json([]),
        });
        final c = StoreSetupController(repository: backend.repo, linkCheckDelay: Duration.zero);
        await c.load();
        c.setEmail('sales@clanix.co.ke');
        c.showBusinessStep = true;
        await tester.pump();

        for (final step in StoreSetupStep.values) {
          await tester.pumpWidget(MaterialApp(home: WizardScaffold(
            flowTitle: 'Set up your store',
            position: step.index,
            total: StoreSetupStep.values.length,
            title: 'A step title long enough to wrap on a small phone screen',
            subtitle: 'And a subtitle that explains the step in a full sentence or two',
            onNext: () {},
            onBack: () {},
            nextLabel: 'Save and continue',
            error: 'Something needs fixing on this step before you continue.',
            animateBackground: false,
            child: switch (step) {
              StoreSetupStep.business => BusinessStep(c),
              StoreSetupStep.name => NameStep(c),
              StoreSetupStep.link => LinkStep(c),
              StoreSetupStep.category => CategoryStep(c),
              StoreSetupStep.location => LocationStep(c),
              StoreSetupStep.logo => LogoStep(c),
              StoreSetupStep.photos => PhotosStep(c),
              StoreSetupStep.email => EmailStep(c, onError: (_) {}),
              StoreSetupStep.review => ReviewStep(c, onEdit: (_) {}),
            },
          )));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$step at $size');
        }

        final store = Store.fromJson(_storeJson());
        await tester.pumpWidget(MaterialApp(home: StoreLaunchedScreen(
            store: store, animateBackground: false)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'launched screen at $size');

        await tester.pumpWidget(MaterialApp(home: MyStoreScreen(repository: backend.repo,
            listings: ListingsRepository(client: backend.client), animateBackground: false)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'My Store at $size');
        for (final tab in ['Products', 'Settings']) {
          await tester.tap(find.text(tab));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'My Store $tab at $size');
        }
        c.dispose();
      });
    }

    testWidgets('WizardProgress: dots for short flows, a bar for long ones', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [
        WizardProgress(position: 2, total: 9),
        WizardProgress(position: 2, total: 12),
      ]))));
      expect(find.text('Step 3 of 12'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);   // the current dot of the 9-step flow
    });
  });
}