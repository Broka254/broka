// The comparison, detail and report screens for escrow providers.
//
// What a person must be able to see, and what must not be on screen:
//   * every card: fee summary, limits, payment methods, account/ID checks,
//     release, disputes, how current the pricing is, "View full details" and
//     "Official website";
//   * the required notice, on every screen, in the owner's words;
//   * a fee for a provider that publishes none is NEVER shown - its own
//     wording is ("Check live quotation in Lipasafe before paying");
//   * no total where a charge is missing; no "cheapest" unless the server
//     allows it; saved copies say so and are dated;
//   * no ratings, reviews, user counts, "approved", "safe" or "guaranteed";
//   * links open in the external browser, and only if they are on the
//     provider's own domain.
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/utils/result.dart';
import 'package:broka/features/safe_payment/payments_shown.dart';
import 'package:broka/features/safe_payment/provider_comparison_screen.dart';
import 'package:broka/features/safe_payment/provider_detail_screen.dart';
import 'package:broka/features/safe_payment/provider_directory.dart';
import 'package:broka/features/safe_payment/provider_directory_repository.dart';
import 'package:broka/features/safe_payment/provider_widgets.dart';
import 'package:broka/features/safe_payment/report_scam_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

final _fetched = DateTime.utc(2026, 11, 16, 9);

ProviderDirectory _dir(String name, {bool cached = false}) {
  final d = ProviderDirectory.tryParse(_fixture(name), fetchedAt: _fetched)!;
  return cached ? d.asCached() : d;
}

/// A repository that answers from fixtures and records what it was asked.
class _FakeRepo extends ProviderDirectoryRepository {
  _FakeRepo(this.answer);
  final Result<ProviderDirectory> Function(DirectoryQuery q) answer;
  final List<DirectoryQuery> asked = [];

  @override
  Future<Result<ProviderDirectory>> fetch({DirectoryQuery query = const DirectoryQuery(), bool forceRefresh = false}) async {
    asked.add(query);
    return answer(query);
  }
}

_FakeRepo _repoOf(String fixture, {bool cached = false}) => _FakeRepo((_) => Success(_dir(fixture, cached: cached)));

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> _open(WidgetTester tester, _FakeRepo repo,
    {List<Uri>? opened, List<String>? asked, DateTime Function()? clock}) async {
  await _phone(tester);
  await tester.pumpWidget(MaterialApp(
    home: ProviderComparisonScreen(
      repository: repo,
      debounce: const Duration(milliseconds: 10),
      clock: clock ?? () => _fetched,
      openUrl: (u) async {
        opened?.add(u);
        return true;
      },
      onZeno: (p) => asked?.add(p),
    ),
  ));
  await tester.pump(const Duration(seconds: 1));
}

/// Scroll until [f] is on screen, from wherever the list is now.
///
/// These screens are lazy lists: a widget below the fold is not built, so a
/// finder cannot see it until it is scrolled to. scrollUntilVisible only moves
/// one way (the delta's sign), so a target ABOVE the current position was never
/// found and the test died with "No element". Going back to the top first makes
/// the helper correct whichever way the target lies. The scrollable is the one
/// inside the screen, not an unrelated one (a dropdown or sheet may sit above).
Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  final list = find.byType(Scrollable).first;
  // Always from the top: "already built" is not "on screen" (the cache extent
  // builds a little beyond the viewport), so testing for it would still leave
  // a target above the viewport unreachable.
  await tester.drag(list, const Offset(0, 100000));
  await tester.pump();
  await tester.scrollUntilVisible(f, 300, scrollable: list);
  // scrollUntilVisible stops as soon as the widget is BUILT, and a lazy list
  // builds a little beyond the viewport: the first version tapped a button at
  // y=1496 on an 844px screen and nothing happened. ensureVisible brings it
  // fully on screen, so a tap lands.
  await tester.ensureVisible(f.first);
  await tester.pump();
}

void main() {
  setUpAll(() => paymentsShown = true);
  tearDownAll(() => paymentsShown = false);
  setUpAll(installFakeApi);

  group('the comparison screen', () {
    testWidgets('shows the required notice first, in the owner\u2019s words', (tester) async {
      await _open(tester, _repoOf('directory_plain.json'));
      expect(find.byKey(const Key('disclosure-box')), findsOneWidget);
      expect(find.textContaining('Broka does not operate these escrow services and does not hold, receive or release your money'),
          findsOneWidget);
      expect(find.textContaining('The services are provided independently by their respective operators'), findsOneWidget);
    });

    testWidgets('a card has everything the brief lists', (tester) async {
      await _open(tester, _repoOf('directory_plain.json'));
      await _scrollTo(tester, find.byKey(const ValueKey('card-kenyaescrow')));
      final card = find.byKey(const ValueKey('card-kenyaescrow'));
      for (final text in [
        'Kenya Escrow', 'kenyaescrow.com',
        'Under review: not yet verified by Broka',                  // review status, honestly
        'Pricing: Not yet verified by BROKA',                       // verification date / state
        'KSh 50 to KSh 240,000',                                    // minimum and maximum
        'M-Pesa STK Push',                                          // payment methods
        'No account required',                                      // registration / KYC
        'Not the same company as Escrow Kenya (escrowkenya.com).',  // the name that must never be confused
        'View full details', 'Official website',
      ]) {
        expect(find.descendant(of: card, matching: find.textContaining(text, findRichText: true)), findsWidgets, reason: text);
      }
    });

    testWidgets('a fee a provider does not publish is shown in its own words, never as a number', (tester) async {
      await _open(tester, _repoOf('directory_plain.json'));
      await _scrollTo(tester, find.byKey(const ValueKey('card-lipasafe')));
      expect(find.textContaining('Check live quotation in Lipasafe before paying', findRichText: true), findsOneWidget);
      await _scrollTo(tester, find.byKey(const ValueKey('card-shikilia')));
      expect(find.textContaining('Fee not publicly specified – confirm before paying', findRichText: true), findsOneWidget);
    });

    testWidgets('no rating, review, user count, approval or guarantee appears anywhere', (tester) async {
      await _open(tester, _repoOf('directory_plain.json'));
      final all = StringBuffer();
      for (var i = 0; i < 6; i++) {
        for (final w in tester.widgetList<Text>(find.byType(Text))) {
          all.write('${w.data ?? w.textSpan?.toPlainText() ?? ''}\n');
        }
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await tester.pump();
      }
      final text = all.toString();
      for (final banned in [
        RegExp(r'\bguaranteed\b', caseSensitive: false), RegExp(r'\bfully safe\b', caseSensitive: false),
        RegExp(r'\b100% safe\b', caseSensitive: false), RegExp(r'\bBroka[- ]approved\b', caseSensitive: false),
        RegExp(r'\bSAFEST\b'), RegExp(r'★|⭐'), RegExp(r'\b\d+(\.\d+)?\s*/\s*5\b'), RegExp(r'\b\d[\d,]*\+? (users|customers|reviews|transactions)\b', caseSensitive: false),
        RegExp(r'\b\d+%\s*(success|satisfaction)', caseSensitive: false),
      ]) {
        expect(banned.hasMatch(text), isFalse, reason: banned.pattern);
      }
    });

    testWidgets('typing an amount asks the server and shows its figures: Kenya Escrow 5,000 -> 5,316', (tester) async {
      final repo = _FakeRepo((q) => Success(_dir(q.amount == null ? 'directory_plain.json' : 'directory_calc_5000.json')));
      await _open(tester, repo);
      await tester.enterText(find.byKey(const Key('amount-field')), '5000');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 1));
      expect(repo.asked.last.amount, 5000);
      await _scrollTo(tester, find.byKey(const ValueKey('card-kenyaescrow')));
      for (final text in ['KSh 5,000', 'KSh 270', 'KSh 46', 'KSh 5,316', '6.32%', 'ESTIMATE']) {
        expect(find.textContaining(text, findRichText: true), findsWidgets, reason: text);
      }
      expect(find.textContaining('quotation on the provider'), findsWidgets);   // the checkout is the authority
    });

    testWidgets('eConfirm shows its commission, not a total, and says what is missing', (tester) async {
      await _open(tester, _FakeRepo((q) => Success(_dir('directory_calc_5000.json'))));
      await tester.enterText(find.byKey(const Key('amount-field')), '5000');
      await tester.pump(const Duration(seconds: 1));
      await _scrollTo(tester, find.byKey(const ValueKey('card-econfirm')));
      final card = find.byKey(const ValueKey('card-econfirm'));
      expect(find.descendant(of: card, matching: find.text('NO TOTAL SHOWN')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('KSh 50')), findsWidgets);          // 1% commission
      expect(find.descendant(of: card, matching: find.textContaining('no total is shown')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Not available')), findsWidgets);   // total and reserve
    });

    testWidgets('Lipasafe and Shikilia get no estimate figures', (tester) async {
      await _open(tester, _FakeRepo((q) => Success(_dir('directory_calc_5000.json'))));
      await tester.enterText(find.byKey(const Key('amount-field')), '5000');
      await tester.pump(const Duration(seconds: 1));
      for (final id in ['lipasafe', 'shikilia']) {
        await _scrollTo(tester, find.byKey(ValueKey('card-$id')));
        final card = find.byKey(ValueKey('card-$id'));
        expect(find.descendant(of: card, matching: find.textContaining('KSh 5,000')), findsNothing, reason: id);
        expect(find.descendant(of: card, matching: find.textContaining('Total buyer payment')), findsNothing, reason: id);
      }
    });

    testWidgets('it does not claim anything is cheapest when the server withholds the ranking', (tester) async {
      await _open(tester, _FakeRepo((q) => Success(_dir('directory_calc_5000.json'))));
      await tester.enterText(find.byKey(const Key('amount-field')), '5000');
      await tester.pump(const Duration(seconds: 1));
      await _scrollTo(tester, find.byKey(const Key('ranking-withheld')));
      expect(find.byKey(const Key('ranking-withheld')), findsOneWidget);
      expect(find.byKey(const Key('ranking-claim')), findsNothing);
      expect(find.textContaining('Not enough comparable'), findsOneWidget);
      expect(find.textContaining('cheapest', findRichText: true), findsNothing);
      expect(find.textContaining('Lowest estimated total'), findsNothing);
    });

    testWidgets('when the server allows a ranking, its sentence is shown as written', (tester) async {
      await _open(tester, _FakeRepo((q) => Success(_dir('directory_ranked_5000.json'))));
      await tester.enterText(find.byKey(const Key('amount-field')), '5000');
      await tester.pump(const Duration(seconds: 1));
      await _scrollTo(tester, find.byKey(const Key('ranking-claim')));
      expect(find.byKey(const Key('ranking-claim')), findsOneWidget);
      expect(find.textContaining('Lowest estimated total among providers with verified, complete pricing: eConfirm'), findsOneWidget);
    });

    testWidgets('filters are sent to the server and excluded providers are listed with the reason', (tester) async {
      final repo = _FakeRepo((q) {
        final j = _fixture('directory_plain.json');
        if (q.noAccount) {
          (j['results'] as List).removeWhere((p) => p['id'] != 'kenyaescrow');
          j['excluded'] = [
            {'id': 'econfirm', 'name': 'eConfirm', 'reason': 'whether an account is needed is not documented'},
            {'id': 'lipasafe', 'name': 'Lipasafe', 'reason': 'needs an account'},
          ];
        }
        return Success(ProviderDirectory.tryParse(j, fetchedAt: _fetched)!);
      });
      await _open(tester, repo);
      await _scrollTo(tester, find.byKey(const Key('filter-no-account')));
      await tester.tap(find.byKey(const Key('filter-no-account')));
      await tester.pump(const Duration(seconds: 1));
      expect(repo.asked.last.noAccount, isTrue);
      expect(find.byKey(const ValueKey('card-kenyaescrow')), findsOneWidget);
      expect(find.byKey(const ValueKey('card-econfirm')), findsNothing);
      await _scrollTo(tester, find.text('Not shown for these filters'));
      expect(find.textContaining('eConfirm: whether an account is needed is not documented'), findsOneWidget);
      expect(find.textContaining('Lipasafe: needs an account'), findsOneWidget);
    });

    testWidgets('choosing where the seller is paid is sent along with the amount', (tester) async {
      final repo = _repoOf('directory_calc_5000.json');
      await _open(tester, repo);
      await tester.enterText(find.byKey(const Key('amount-field')), '5000');
      await _scrollTo(tester, find.byKey(const Key('payout-till')));
      await tester.tap(find.byKey(const Key('payout-till')));
      await tester.pump(const Duration(seconds: 1));
      expect(repo.asked.last.payout, 'till');
      expect(repo.asked.last.amount, 5000);
    });

    testWidgets('a saved copy says it is saved and dated; an old one says it may be out of date', (tester) async {
      await _open(tester, _repoOf('directory_plain.json', cached: true), clock: () => _fetched.add(const Duration(hours: 1)));
      expect(find.byKey(const Key('saved-copy-banner')), findsOneWidget);
      expect(find.textContaining('Saved copy from'), findsOneWidget);
      expect(find.textContaining('may be out of date'), findsNothing);

      await _open(tester, _repoOf('directory_plain.json', cached: true), clock: () => _fetched.add(const Duration(hours: 8)));
      expect(find.textContaining('may be out of date'), findsOneWidget);
      expect(find.textContaining('been taken off the list since'), findsOneWidget);
    });

    testWidgets('with no list there is a plain message - and no provider name from anywhere in the app', (tester) async {
      await _open(tester, _FakeRepo((_) => const Failure('Can\'t reach BROKA right now.')));
      // The banner is near the top and the message is below the calculator and
      // filters, so each is looked for where it is: top first, then scroll down.
      expect(find.byKey(const Key('error-banner')), findsOneWidget);
      expect(find.byKey(const Key('disclosure-box')), findsOneWidget, reason: 'the notice is shown even then');
      await _scrollTo(tester, find.byKey(const Key('no-list')));
      expect(find.byKey(const Key('no-list')), findsOneWidget);
      for (final name in ['eConfirm', 'E-Confirm', 'Kenya Escrow', 'Escrow Kenya', 'Lipasafe', 'Shikilia']) {
        expect(find.text(name), findsNothing, reason: name);
      }
    });

    testWidgets('a suspended provider\u2019s notice is shown, and it is not offered as a provider', (tester) async {
      await _open(tester, _repoOf('directory_plain.json'));
      await _scrollTo(tester, find.textContaining('is not on Broka\'s list'));
      expect(find.textContaining('different website from Kenya Escrow'), findsOneWidget);
      expect(find.byKey(const ValueKey('card-escrowkenya')), findsNothing);
    });

    testWidgets('Official website opens the external browser at the provider\u2019s own address', (tester) async {
      final opened = <Uri>[];
      await _open(tester, _repoOf('directory_plain.json'), opened: opened);
      await _scrollTo(tester, find.byKey(const Key('visit-kenyaescrow')));
      await tester.tap(find.byKey(const Key('visit-kenyaescrow')));
      await tester.pump();
      expect(opened, [Uri.parse('https://kenyaescrow.com/')]);
    });

    testWidgets('a link that is not on the provider\u2019s domain is never opened', (tester) async {
      final opened = <Uri>[];
      final p = _dir('directory_plain.json').byId('kenyaescrow')!;
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }))));
      for (final url in ['https://kenyaescrow.com.evil.example/', 'http://kenyaescrow.com/', 'https://evil.example/kenyaescrow.com']) {
        final ok = await openProviderSite(ctx, p, url, openUrl: (u) async {
          opened.add(u);
          return true;
        });
        expect(ok, isFalse, reason: url);
      }
      expect(opened, isEmpty);
      await tester.pump();
      expect(find.textContaining('is not Kenya Escrow\'s own website'), findsOneWidget);
    });

    testWidgets('Ask Zeno hands the provider\u2019s name to Zeno', (tester) async {
      final asked = <String>[];
      await _open(tester, _repoOf('directory_plain.json'), asked: asked);
      await _scrollTo(tester, find.text('Ask Zeno about Kenya Escrow'));
      await tester.tap(find.text('Ask Zeno about Kenya Escrow'));
      await tester.pump();
      expect(asked, ['Walk me through paying with Kenya Escrow']);
    });

    testWidgets('no amount means no calculator results and no ranking banner', (tester) async {
      await _open(tester, _repoOf('directory_plain.json'));
      expect(find.byKey(const Key('ranking-withheld')), findsNothing);
      expect(find.byKey(const Key('ranking-claim')), findsNothing);
      expect(find.text('ESTIMATE'), findsNothing);
    });
  });

  group('the detail screen', () {
    Future<void> openDetail(WidgetTester tester, String id, {List<Uri>? opened}) async {
      await _phone(tester);
      final dir = _dir('directory_plain.json');
      await tester.pumpWidget(MaterialApp(
        home: ProviderDetailScreen(
          provider: dir.byId(id)!, notice: dir.notice, points: dir.points,
          openUrl: (u) async {
            opened?.add(u);
            return true;
          },
        ),
      ));
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('has all eleven sections, in order', (tester) async {
      await openDetail(tester, 'kenyaescrow');
      const titles = [
        '1. Overview', '2. Fees and charges', '3. Transaction limits', '4. How payment works',
        '5. How funds are released', '6. Buyer protection', '7. Seller protection', '8. Disputes and refunds',
        '9. Registration and verification', '10. Contacts and official policies',
        '11. Broka\'s relationship with this provider',
      ];
      // Each section exists with its title...
      for (final (i, title) in titles.indexed) {
        await _scrollTo(tester, find.byKey(Key('section-${i + 1}')));
        expect(find.text(title), findsOneWidget, reason: title);
      }
      // ...and they are laid out in order: scrolled back to the top, each one
      // that is built sits below the one before it.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 100000));
      await tester.pump();
      var previous = double.negativeInfinity;
      for (var n = 1; n <= 11; n++) {
        final f = find.byKey(Key('section-$n'));
        if (f.evaluate().isEmpty) continue; // not built yet (scrolled out): lists build lazily
        final y = tester.getTopLeft(f).dy;
        expect(y, greaterThan(previous), reason: 'section $n is out of order');
        previous = y;
      }
      expect(previous, isNot(double.negativeInfinity), reason: 'at least one section was laid out');
    });

    testWidgets('what the research did not give says Not documented, and what it gave is attributed', (tester) async {
      await openDetail(tester, 'shikilia');
      await _scrollTo(tester, find.byKey(const Key('section-8')));
      expect(find.textContaining('Not documented', findRichText: true), findsWidgets);
      expect(find.textContaining('24 to 48 hours'), findsOneWidget);          // its stated dispute review window
      await _scrollTo(tester, find.byKey(const Key('section-6')));
      expect(find.textContaining('24-hour buyer protection window'), findsOneWidget);
      await _scrollTo(tester, find.byKey(const Key('section-1')));
      expect(find.textContaining('Jeno-tech Solutions'), findsOneWidget);      // the unresolved entity, shown as unresolved
    });

    testWidgets('eConfirm\u2019s "fully functional beta" and its separate payout reserve are shown', (tester) async {
      await openDetail(tester, 'econfirm');
      expect(find.textContaining('fully functional beta'), findsOneWidget);
      await _scrollTo(tester, find.byKey(const Key('section-2')));
      expect(find.textContaining('not the total fee'), findsOneWidget);
    });

    testWidgets('the section about BROKA\u2019s role says it holds no money and cannot recover any', (tester) async {
      await openDetail(tester, 'kenyaescrow');
      await _scrollTo(tester, find.byKey(const Key('section-11')));
      expect(find.textContaining('not a party to your transaction'), findsOneWidget);
      expect(find.textContaining('cannot recover money'), findsOneWidget);
      expect(find.textContaining('not a recommendation'), findsOneWidget);
    });

    testWidgets('Visit official website opens the external browser', (tester) async {
      final opened = <Uri>[];
      await openDetail(tester, 'kenyaescrow', opened: opened);
      await _scrollTo(tester, find.byKey(const Key('detail-visit')));
      await tester.tap(find.byKey(const Key('detail-visit')));
      await tester.pump();
      expect(opened, [Uri.parse('https://kenyaescrow.com/')]);
    });

    testWidgets('a legal operator that is not confirmed is labelled as such', (tester) async {
      await openDetail(tester, 'lipasafe');
      // Named twice on purpose: in the identity block, with its status, and in the
      // sentence that says where the name came from. Both must say it is unconfirmed.
      expect(find.textContaining('Holda Fintech Technologies Limited'), findsNWidgets(2));
      expect(find.textContaining('not yet verified by Broka', findRichText: true), findsWidgets);
      expect(find.textContaining('has not yet confirmed this independently'), findsOneWidget);
      expect(find.textContaining('Operator confirmed by Broka'), findsNothing);
    });
  });

  group('reporting a scam', () {
    Future<void> openForm(WidgetTester tester, _FakeReports repo, {List<XFile>? picks}) async {
      await _phone(tester);
      var i = 0;
      await tester.pumpWidget(MaterialApp(
        home: ReportScamScreen(
          providerId: 'kenyaescrow', repository: repo, skipSignIn: true,
          pickImage: () async => picks == null || i >= picks.length ? null : picks[i++],
        ),
      ));
      await tester.pump();
    }

    /// Fill the form one field at a time, bringing each into view first: it is a
    /// long lazy list, and a field that is not on screen is not built (the
    /// first version called enterText on the description before it existed).
    Future<void> fill(WidgetTester tester, {String? reason, String description = 'He asked me to send 2,000 to reserve it.'}) async {
      await _scrollTo(tester, find.byKey(const Key('account-field')));
      await tester.enterText(find.byKey(const Key('account-field')), '0712 345 678');
      await _scrollTo(tester, find.byKey(const Key('description-field')));
      await tester.enterText(find.byKey(const Key('description-field')), description);
      await tester.pump();
      if (reason != null) {
        await _scrollTo(tester, find.byKey(const Key('reason-field')));
        await tester.tap(find.byKey(const Key('reason-field')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));   // the menu route animates in
        await tester.tap(find.text(reason).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    testWidgets('the send button waits for a reason, a subject and a description', (tester) async {
      await openForm(tester, _FakeReports());
      // The button ends a long lazy form: it is not built until it is scrolled to.
      Future<FilledButton> button() async {
        await _scrollTo(tester, find.byKey(const Key('send-report')));
        return tester.widget<FilledButton>(find.byKey(const Key('send-report')));
      }
      expect((await button()).onPressed, isNull, reason: 'nothing filled in yet');
      await fill(tester);
      expect((await button()).onPressed, isNull, reason: 'no reason chosen yet');
      await fill(tester, reason: 'Asked for a deposit to reserve an item');
      expect((await button()).onPressed, isNotNull);
    });

    testWidgets('it never asks for a PIN, OTP or password, and says so', (tester) async {
      await openForm(tester, _FakeReports());
      expect(find.textContaining('Do not write or paste your M-Pesa PIN, an OTP or a password here.'), findsOneWidget);
      expect(find.textContaining('Not your PIN, and never an OTP'), findsOneWidget);
      for (final label in ['PIN', 'OTP', 'Password']) {
        expect(find.widgetWithText(TextField, label), findsNothing);
      }
    });

    testWidgets('sending files the report, then tells the person what it is and is not', (tester) async {
      final repo = _FakeReports();
      await openForm(tester, repo);
      await fill(tester, reason: 'Asked for a deposit to reserve an item');
      await _scrollTo(tester, find.byKey(const Key('send-report')));
      await tester.tap(find.byKey(const Key('send-report')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repo.submitted.single['reason'], 'deposit_to_reserve');
      expect(repo.submitted.single['provider'], 'kenyaescrow');
      expect(find.byKey(const Key('report-thanks')), findsOneWidget);
      expect(find.textContaining('not a finding against anyone'), findsOneWidget);
      expect(find.textContaining('cannot promise to recover money'), findsOneWidget);
      expect(find.textContaining('police'), findsOneWidget);
    });

    testWidgets('a refusal is shown as the server\u2019s readable message', (tester) async {
      final repo = _FakeReports(fail: 'description: say what happened (at least a sentence).');
      await openForm(tester, repo);
      await fill(tester, reason: 'Something else', description: 'long enough text here');
      await _scrollTo(tester, find.byKey(const Key('send-report')));
      await tester.tap(find.byKey(const Key('send-report')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('report-error')), findsOneWidget);
      expect(find.textContaining('say what happened'), findsOneWidget);
    });

    test('the reasons are the server\u2019s reasons', () {
      expect(kScamReasons.keys, containsAll([
        'bypass_escrow', 'fake_escrow_link', 'requested_otp_or_pin', 'deposit_to_reserve', 'fake_payment_proof',
        'fake_customer_care', 'changed_payment_destination', 'non_delivery',
      ]));
    });
  });
}

class _FakeReports extends ScamReportRepository {
  _FakeReports({this.fail});
  final String? fail;
  final List<Map<String, String?>> submitted = [];

  @override
  Future<Result<ScamReportReceipt>> submit({
    required String reasonCode,
    required String description,
    String? reportedAccount,
    String? providerId,
    String? transactionReference,
    int? amountKes,
    bool paymentSent = false,
  }) async {
    if (fail != null) return Failure(fail!);
    submitted.add({'reason': reasonCode, 'provider': providerId});
    return const Success(ScamReportReceipt(
      id: 'r1',
      message: 'Thank you. The Broka team will review this. A report is not a finding against anyone, and Broka '
          'cannot promise to recover money sent to another person or to an escrow provider.',
      nextSteps: ['Keep the messages.', 'If you believe a crime was committed, report it to the police.'],
      duplicate: false,
    ));
  }
}
