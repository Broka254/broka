// The escrow provider directory as the app reads it
// (lib/features/safe_payment/provider_directory.dart and its repository).
//
// The fixtures in test/fixtures/ are the SERVER'S real output, generated from
// the backend's catalogue, not typed here - so a change to the response that
// the app cannot read fails this test, not a user's screen. What must hold:
//
//  * a provider whose website is not on its own domain is DROPPED, never shown
//    with a warning (isOfficialUrl, the same rule as the server's);
//  * a fact the server did not give stays null ("Not documented"), and an
//    unknown freshness is "unverified", never "current";
//  * the required notice is the owner's wording, always;
//  * nothing is ever shown from code that shipped with the app: the plain
//    list is the last saved server answer, marked as saved and dated, and
//    past its limit there is none;
//  * a calculation is never answered from a saved copy.
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/cache/screen_cache.dart';
import 'package:broka/core/cache/cache_store.dart';
import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/utils/result.dart';
import 'package:broka/features/safe_payment/provider_directory.dart';
import 'package:broka/features/safe_payment/provider_directory_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

final _fetched = DateTime.utc(2026, 11, 16, 9);

ProviderDirectory _parse(String name) => ProviderDirectory.tryParse(_fixture(name), fetchedAt: _fetched)!;

void main() {
  group('reading the server answer', () {
    test('every listed provider parses, with its official address and its freshness', () {
      final dir = _parse('directory_plain.json');
      expect(dir.providers.map((p) => p.id), ['econfirm', 'kenyaescrow', 'lipasafe', 'shikilia']);
      expect(dir.byId('kenyaescrow')!.websiteUrl, 'https://kenyaescrow.com/');
      expect(dir.byId('kenyaescrow')!.site, 'kenyaescrow.com');
      expect(dir.byId('shikilia')!.websiteUrl, 'https://www.shikilia.co.ke/');
      for (final p in dir.providers) {
        expect(p.pricingFreshness.state, 'unverified', reason: '${p.id}: nothing starts verified');
        expect(p.pricingFreshness.isCurrent, isFalse);
        expect(p.needsWarning, isTrue);
        expect(p.isReviewed, isFalse);
      }
    });

    test('the suspended provider is a notice, never a listing', () {
      final dir = _parse('directory_plain.json');
      expect(dir.providers.where((p) => p.id == 'escrowkenya'), isEmpty);
      expect(dir.notices.single.domain, 'escrowkenya.com');
      expect(dir.notices.single.message, contains('different website from Kenya Escrow'));
    });

    test('the two names that are easy to confuse are kept apart on screen', () {
      final ke = _parse('directory_plain.json').byId('kenyaescrow')!;
      expect(ke.notToBeConfusedWith.single.text, 'Not the same company as Escrow Kenya (escrowkenya.com).');
    });

    test('a fee Zeno or the app cannot know is worded as the owner specified, not invented', () {
      final dir = _parse('directory_plain.json');
      expect(dir.byId('lipasafe')!.feeSummary, 'Check live quotation in Lipasafe before paying');
      expect(dir.byId('shikilia')!.feeSummary, 'Fee not publicly specified – confirm before paying');
      expect(dir.byId('econfirm')!.feeSummary, contains('1%'));
      expect(dir.byId('econfirm')!.feeSummary, contains('charged separately'));
      expect(dir.byId('econfirm')!.feeSummary.toLowerCase(), isNot(contains('total')));
    });

    test('protection facts the research did not give are null, so the screen says Not documented', () {
      final shikilia = _parse('directory_plain.json').byId('shikilia')!;
      expect(shikilia.protectionText('refund_conditions'), isNull);
      expect(shikilia.protectionText('seller_protection'), isNull);
      expect(shikilia.protectionText('dispute_timeframe'), contains('24 to 48 hours'));
      expect(shikilia.protectionText('buyer_protection'), contains('24-hour'));
    });

    test('the required notice is the owner\u2019s wording, and is present even when the server sent none', () {
      const wording =
          "Broka does not operate these escrow services and does not hold, receive or release your money. "
          "The services are provided independently by their respective operators. Broka does not guarantee "
          "their performance or independently control their funds. Review the provider's current fees, "
          "conditions, refund policy and dispute procedures before paying.";
      expect(kRequiredNotice, wording);
      expect(_parse('directory_plain.json').notice, wording);
      final noDisclosures = _fixture('directory_plain.json')..remove('disclosures');
      final dir = ProviderDirectory.tryParse(noDisclosures, fetchedAt: _fetched)!;
      expect(dir.notice, wording);
      expect(dir.points, kDisclosurePoints);
      expect(kDisclosurePoints.join(' '), contains('cannot guarantee that a dispute will end in a refund'));
    });

    test('garbage is refused without crashing', () {
      for (final bad in <Object?>[null, 5, 'x', <Object?>[], {}, {'results': 'nope'}, {'providers': null}]) {
        expect(ProviderDirectory.tryParse(bad, fetchedAt: _fetched), isNull, reason: '$bad');
      }
      final partly = ProviderDirectory.tryParse({'results': [null, 5, 'x', {}]}, fetchedAt: _fetched)!;
      expect(partly.providers, isEmpty);
    });
  });

  group('an address is shown only if it is on the provider\u2019s own domain', () {
    for (final bad in [
      'https://kenyaescrow.com@evil.example/',
      'https://user@kenyaescrow.com/',
      'https://kenyaescrow.com.evil.example/',
      'https://evilkenyaescrow.com/',
      'http://kenyaescrow.com/',
      'https://kenyaescrow.com:8443/x',
      'https://xn--kenyaescrw-8cf.com/',
      'https://sub.kenyaescrow.com/',
      'https://escrowkenya.com/',
      'javascript:alert(1)',
      '//kenyaescrow.com/',
      'kenyaescrow.com',
      '',
    ]) {
      test('refuses $bad', () => expect(isOfficialUrl(bad, 'kenyaescrow.com'), isFalse));
    }
    for (final good in ['https://kenyaescrow.com', 'https://www.kenyaescrow.com/pricing?x=1', 'https://kenyaescrow.com:443/faq']) {
      test('accepts $good', () => expect(isOfficialUrl(good, 'kenyaescrow.com'), isTrue));
    }
    test('refuses a domain that is not plain, and non-text input', () {
      for (final d in ['www.kenyaescrow.com', 'KenyaEscrow.com', 'xn--abc.com', 'kenyaescrow', '', null, 5]) {
        expect(isOfficialUrl('https://kenyaescrow.com/', d), isFalse, reason: '$d');
      }
      for (final u in <Object?>[null, 5, <Object?>[]]) {
        expect(isOfficialUrl(u, 'kenyaescrow.com'), isFalse);
      }
    });

    test('a tampered response drops the provider rather than showing it with a warning', () {
      final json = _fixture('directory_plain.json');
      final results = (json['results'] as List).cast<Map<String, dynamic>>();
      results.firstWhere((p) => p['id'] == 'kenyaescrow')['website_url'] = 'https://kenyaescrow.com.evil.example/';
      results.firstWhere((p) => p['id'] == 'econfirm')['status'] = 'suspended';
      final dir = ProviderDirectory.tryParse(json, fetchedAt: _fetched)!;
      expect(dir.providers.map((p) => p.id), ['lipasafe', 'shikilia']);
    });

    test('source links off the provider\u2019s domain are dropped', () {
      final json = _fixture('directory_plain.json');
      final ke = (json['results'] as List).cast<Map<String, dynamic>>().firstWhere((p) => p['id'] == 'kenyaescrow');
      (ke['sources'] as List).add({'label': 'Evil', 'url': 'https://evil.example/'});
      final parsed = ProviderDirectory.tryParse(json, fetchedAt: _fetched)!.byId('kenyaescrow')!;
      expect(parsed.sources.map((s) => s.label), isNot(contains('Evil')));
      expect(parsed.sources, isNotEmpty);
    });
  });

  group('freshness', () {
    test('an unknown or missing state is never current', () {
      expect(Freshness.fromJson(null).state, 'unverified');
      expect(Freshness.fromJson({'state': 'current_ish'}).isCurrent, isFalse);
      expect(Freshness.fromJson({'state': 'current'}).isCurrent, isTrue);
      expect(Freshness.fromJson({'state': 'expired', 'label': 'Outdated: last verified 1 Nov 2026'}).label, startsWith('Outdated'));
    });

    test('a saved copy is stale after six hours, and a fresh copy never is', () {
      final dir = _parse('directory_plain.json');
      expect(dir.isStale(_fetched.add(const Duration(days: 9))), isFalse, reason: 'not from cache');
      final saved = dir.asCached();
      expect(saved.fromCache, isTrue);
      expect(saved.isStale(_fetched.add(const Duration(hours: 5))), isFalse);
      expect(saved.isStale(_fetched.add(const Duration(hours: 7))), isTrue);
    });
  });

  group('the calculator answer', () {
    test('Kenya Escrow at KSh 5,000 is the published figure, from the server', () {
      final e = _parse('directory_calc_5000.json').byId('kenyaescrow')!.estimate!;
      expect([e.commission, e.fixedCharges, e.otherCharges, e.totalBuyerPayment], [270, 46, 0, 5316]);
      expect(e.effectivePercent, 6.32);
      expect(e.hasTotal, isTrue);
      expect(e.comparable, isFalse, reason: 'unverified pricing is never comparable');
    });

    test('eConfirm shows its commission but no total - the reserve is not loaded', () {
      final e = _parse('directory_calc_5000.json').byId('econfirm')!.estimate!;
      expect(e.status, 'partial');
      expect(e.commission, 50);
      expect(e.hasTotal, isFalse);
      expect(e.totalBuyerPayment, isNull);
      expect(e.needsPayoutDestination, isTrue);
    });

    test('Lipasafe and Shikilia get no number at all', () {
      for (final id in ['lipasafe', 'shikilia']) {
        final e = _parse('directory_calc_5000.json').byId(id)!.estimate!;
        expect(e.status, 'unavailable');
        expect([e.commission, e.fixedCharges, e.otherCharges, e.totalBuyerPayment, e.effectivePercent], everyElement(isNull));
        expect(e.hasTotal, isFalse);
      }
    });

    test('with nothing verified there is no ranking, and it says why', () {
      final r = _parse('directory_calc_5000.json').ranking!;
      expect(r.claimAllowed, isFalse);
      expect(r.rankedIds, isEmpty);
      expect(r.headline, contains('Not enough comparable'));
      expect(r.notRanked.keys, containsAll(['econfirm', 'kenyaescrow', 'lipasafe', 'shikilia']));
    });

    test('when the server allows a ranking, the app carries it unchanged', () {
      final r = _parse('directory_ranked_5000.json').ranking!;
      expect(r.claimAllowed, isTrue);
      expect(r.rankedIds, ['econfirm', 'kenyaescrow']);
      expect(r.notRanked.keys, containsAll(['lipasafe', 'shikilia']));
    });
  });

  test('shillings are formatted with thousands separators', () {
    expect(formatKes(5316), 'KSh 5,316');
    expect(formatKes(0), 'KSh 0');
    expect(formatKes(246625), 'KSh 246,625');
    expect(formatKes(1000000), 'KSh 1,000,000');
    expect(formatKes(999), 'KSh 999');
  });

  group('fetching', () {
    setUpAll(installFakeApi);
    tearDown(() {
      setFakeRoute(null);
      ScreenCache.debugReset();
      clearFakeRequests();
    });

    bool isCompare(Uri u) => u.path == '/escrow-providers/compare';

    test('the plain list is the server\u2019s answer, parsed and dated now', () async {
      setFakeRoute((u) => isCompare(u) ? _fixture('directory_plain.json') : null);
      final repo = ProviderDirectoryRepository(clock: () => _fetched);
      final result = await repo.fetch();
      final dir = (result as Success<ProviderDirectory>).data;
      expect(dir.providers, hasLength(4));
      expect(dir.fromCache, isFalse);
      expect(dir.fetchedAt, _fetched);
    });

    test('a calculation sends the amount and payout, and is never answered from the phone\u2019s copy', () async {
      ScreenCache.debugInstall(store: MemoryCacheStore());
      var calls = 0;
      setFakeRoute((u) {
        if (!isCompare(u)) return null;
        calls++;
        return _fixture('directory_calc_5000.json');
      });
      final repo = ProviderDirectoryRepository(clock: () => _fetched);
      const q = DirectoryQuery(amount: 5000, payout: 'phone', sort: 'lowest_fee', noAccount: true);
      await repo.fetch(query: q);
      await repo.fetch(query: q);
      expect(calls, 2, reason: 'an estimate is asked for each time, never replayed from a copy');
      final sent = fakeRequests.where((r) => isCompare(r.uri)).last.uri.queryParameters;
      expect(sent, {'amount': '5000', 'payout': 'phone', 'sort': 'lowest_fee', 'no_account': 'true'});
    });

    test('the plain list is kept, and when the server is down the saved copy is marked as saved', () async {
      ScreenCache.debugInstall(store: MemoryCacheStore(), clock: () => _fetched);
      setFakeRoute((u) => isCompare(u) ? _fixture('directory_plain.json') : null);
      final repo = ProviderDirectoryRepository(clock: () => _fetched);
      expect((await repo.fetch()), isA<Success<ProviderDirectory>>());

      setFakeRoute((u) => isCompare(u) ? const FakeResponse.error() : null);
      final offline = await repo.fetch(forceRefresh: true);
      final dir = (offline as Success<ProviderDirectory>).data;
      expect(dir.fromCache, isTrue, reason: 'an old answer must never read as today\u2019s');
      expect(dir.providers, hasLength(4));
      expect(dir.fetchedAt, isNot(isNull));
    });

    test('with no saved copy and no server, there is no list - not a built-in one', () async {
      ScreenCache.debugInstall(store: MemoryCacheStore());
      setFakeRoute((u) => isCompare(u) ? const FakeResponse.error() : null);
      final result = await ProviderDirectoryRepository(clock: () => _fetched).fetch();
      expect(result, isA<Failure<ProviderDirectory>>());
    });

    test('a saved copy older than two days is discarded, not shown', () async {
      var now = _fetched;
      ScreenCache.debugInstall(store: MemoryCacheStore(), clock: () => now);
      setFakeRoute((u) => isCompare(u) ? _fixture('directory_plain.json') : null);
      final repo = ProviderDirectoryRepository(clock: () => now);
      await repo.fetch();
      now = _fetched.add(const Duration(days: 3));
      setFakeRoute((u) => isCompare(u) ? const FakeResponse.error() : null);
      expect(await repo.fetch(forceRefresh: true), isA<Failure<ProviderDirectory>>());
    });

    test('a calculation is not answered from a saved copy when the server is down', () async {
      ScreenCache.debugInstall(store: MemoryCacheStore(), clock: () => _fetched);
      setFakeRoute((u) => isCompare(u) ? _fixture('directory_plain.json') : null);
      final repo = ProviderDirectoryRepository(clock: () => _fetched);
      await repo.fetch();
      setFakeRoute((u) => isCompare(u) ? const FakeResponse.error() : null);
      expect(await repo.fetch(query: const DirectoryQuery(amount: 5000)), isA<Failure<ProviderDirectory>>());
    });

    test('a response the app cannot read is a failure, not an empty list', () async {
      setFakeRoute((u) => isCompare(u) ? {'unexpected': true} : null);
      expect(await ProviderDirectoryRepository(clock: () => _fetched).fetch(), isA<Failure<ProviderDirectory>>());
    });
  });

  group('the query', () {
    test('only the plain list is cacheable', () {
      expect(const DirectoryQuery().isPlain, isTrue);
      for (final q in const [
        DirectoryQuery(amount: 5000), DirectoryQuery(payout: 'till'), DirectoryQuery(sort: 'lowest_fee'),
        DirectoryQuery(noAccount: true), DirectoryQuery(kyc: 'required'), DirectoryQuery(paymentMethod: 'mpesa'),
        DirectoryQuery(category: 'goods'), DirectoryQuery(documentedDisputes: true), DirectoryQuery(documentedRefunds: true),
      ]) {
        expect(q.isPlain, isFalse);
      }
    });

    test('it sends only what was chosen', () {
      expect(const DirectoryQuery().toParams(), isEmpty);
      expect(const DirectoryQuery(amount: 100, kyc: 'not_required', category: 'services', documentedRefunds: true).toParams(),
          {'amount': '100', 'kyc': 'not_required', 'category': 'services', 'documented_refunds': 'true'});
    });
  });

  test('the app declares no provider list of its own', () {
    final offending = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final text = f.readAsStringSync().replaceAll(RegExp(r'//.*'), '');
      if (RegExp(r"""https?://(www\.)?(escrowkenya\.com|kenyaescrow\.com|econfirm\.co\.ke|lipasafe\.co\.ke|shikilia\.co\.ke)""")
          .hasMatch(text)) {
        offending.add(f.path);
      }
    }
    expect(offending, isEmpty, reason: 'a provider address in the app cannot be corrected by the server');
  });
}
