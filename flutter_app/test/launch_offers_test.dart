// Launch offers + time left: parsing and the widgets that sell/warn.
// The server owns both facts; these tests pin that the app shows them
// faithfully — scarcity when there is some, silence when there is not,
// and a countdown only when a deadline is actually near.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/features/launch_offers/domain/launch_offers.dart';
import 'package:broka/features/launch_offers/presentation/launch_offer_widgets.dart';
import 'package:broka/features/listing_fee/domain/listing_fee.dart';
import 'package:broka/features/listings/domain/models/listing.dart';
import 'package:broka/features/stores/domain/models/store_billing.dart';
import 'package:broka/main.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('TimeLeft parsing', () {
    test('nested payload from a listing', () {
      final t = TimeLeft.fromPayload({
        'time_left': {
          'status': 'ending',
          'label': '2d 3h left',
          'seconds_left': 183600,
          'days_left': 2.13,
          'goes_offline_at': '2026-10-03T12:00:00',
          'is_expiring_soon': true,
        },
        'time_left_label': '2d 3h left',
      })!;
      expect(t.status, 'ending');
      expect(t.showOnCard, isTrue);
      expect(t.needsAttention, isTrue);
      expect(t.offlineDateLabel, contains('Oct'));
    });

    test('store-covered listings are not a countdown', () {
      final t = TimeLeft.fromPayload({
        'time_left': {
          'status': 'store_covered',
          'label': 'Live via store plan',
          'seconds_left': null,
          'is_expiring_soon': false,
        },
      })!;
      expect(t.isStoreCovered, isTrue);
      expect(t.showOnCard, isFalse);
    });

    test('unlimited never shows on a card', () {
      final t = TimeLeft.fromJson({
        'status': 'unlimited',
        'label': 'No expiry',
        'seconds_left': null,
        'is_expiring_soon': false,
      })!;
      expect(t.showOnCard, isFalse);
      expect(t.needsAttention, isFalse);
    });
  });

  group('LaunchOffer', () {
    test('available only when enabled, eligible and slots remain', () {
      const offer = LaunchOffer(
        limit: 50, claimed: 47, remaining: 3, freeDays: 60,
        eligible: true, alreadyClaimed: false, enabled: true,
      );
      expect(offer.isAvailableForUser, isTrue);
      expect(offer.shouldShow, isTrue);
    });

    test('billing off does not hide the promotion; exhausted/configured-off does', () {
      // Production ships with listing/store billing off, so eligible and
      // enabled read false for everyone. The card must still show while
      // slots remain — gating on them made the offer invisible everywhere.
      const paused = LaunchOffer(
        limit: 50, claimed: 0, remaining: 50, freeDays: 60,
        eligible: false, enabled: false,
      );
      const gone = LaunchOffer(
        limit: 50, claimed: 50, remaining: 0, freeDays: 60,
        eligible: false, alreadyClaimed: false, enabled: true,
      );
      const off = LaunchOffer(limit: 0, claimed: 0, remaining: 0, freeDays: 60);
      expect(paused.shouldShow, isTrue);
      expect(paused.hasSlots, isTrue);
      expect(paused.isAvailableForUser, isFalse);
      expect(gone.shouldShow, isFalse);
      expect(off.shouldShow, isFalse);
    });

    test('already claimed still shows, so the free period is explained', () {
      const offer = LaunchOffer(
        limit: 10, claimed: 1, remaining: 9, freeDays: 60,
        eligible: false, alreadyClaimed: true, enabled: true,
      );
      expect(offer.shouldShow, isTrue);
      expect(offer.isAvailableForUser, isFalse);
    });

    test('LaunchOffers parses both offers', () {
      final offers = LaunchOffers.fromJson({
        'listing_free': {
          'limit': 50, 'claimed': 2, 'remaining': 48, 'free_days': 60,
          'eligible': true, 'already_claimed': false, 'enabled': true,
        },
        'store_free': {
          'limit': 10, 'claimed': 10, 'remaining': 0, 'free_days': 60,
          'eligible': false, 'already_claimed': false, 'enabled': true,
        },
      });
      expect(offers.listingFree.remaining, 48);
      expect(offers.storeFree.isExhausted, isTrue);
    });
  });

  group('quote and listing models carry the offer/time-left', () {
    test('listing fee quote parses launch offer and store cover', () {
      final q = ListingFeeQuote.fromJson({
        'category': 'Electronics',
        'fees_enabled': false,
        'free_listing': true,
        'store_covered': false,
        'launch_offer': {'eligible': true, 'enabled': true, 'free_days': 60, 'remaining': 7},
        'options': [],
        'recommendation': {},
        'risk': {},
        'discounts': {},
      });
      expect(q.freeListing, isTrue);
      expect(q.launchOffer?.remaining, 7);
      expect(q.launchOffer?.isEnabled, isTrue);
    });

    test('FeeState knows store coverage never needs payment', () {
      final s = FeeState.fromJson({
        'status': 'store_covered', 'live': true, 'paid_until': null,
      })!;
      expect(s.isStoreCovered, isTrue);
      expect(s.needsPayment, isFalse);
    });

    test('BrokaListing parses paid_until and time_left', () {
      final l = BrokaListing.fromJson({
        'id': '1', 'seller_id': 's', 'name': 'Phone', 'category': 'Electronics',
        'price': 100, 'lat': 0, 'lng': 0,
        'paid_until': '2026-10-03T12:00:00',
        'time_left': {
          'status': 'ending', 'label': '2d 0h left', 'seconds_left': 172800,
          'days_left': 2.0, 'goes_offline_at': '2026-10-03T12:00:00',
          'is_expiring_soon': true,
        },
      });
      expect(l.paidUntil, isNotNull);
      expect(l.timeLeft?.showOnCard, isTrue);
    });

    test('Store and StoreBilling parse time left', () {
      final billing = StoreBilling.fromJson({
        'active': true, 'paid_until': '2026-10-03T12:00:00',
        'time_left': {
          'status': 'ending', 'label': '2d 0h left', 'seconds_left': 172800,
          'is_expiring_soon': true,
        },
      })!;
      expect(billing.timeLeft?.isExpiringSoon, isTrue);
      final quote = StoreBillingQuote.fromJson({
        'rate_card': {'id': 'goods', 'name': 'Online'},
        'current': {'active': true},
        'launch_offer_claimed': true,
      });
      expect(quote.launchOfferClaimed, isTrue);
    });
  });

  group('widgets', () {
    testWidgets('banner sells remaining slots and free days', (tester) async {
      await tester.pumpWidget(_host(const LaunchOfferBanner(
        offer: LaunchOffer(
          limit: 50, claimed: 47, remaining: 3, freeDays: 60,
          eligible: true, alreadyClaimed: false, enabled: true,
        ),
        kind: LaunchOfferKind.listing,
      )));
      expect(find.byKey(const Key('launch-offer-listing')), findsOneWidget);
      expect(find.text('3 left'), findsOneWidget);
      expect(find.textContaining('60 days free'), findsOneWidget);
      expect(find.textContaining('one per person'), findsOneWidget);
    });

    testWidgets('exhausted offer renders nothing', (tester) async {
      await tester.pumpWidget(_host(const LaunchOfferBanner(
        offer: LaunchOffer(
          limit: 10, claimed: 10, remaining: 0, freeDays: 60,
          eligible: false, alreadyClaimed: false, enabled: true,
        ),
        kind: LaunchOfferKind.store,
      )));
      expect(find.byKey(const Key('launch-offer-store')), findsNothing);
    });

    testWidgets('time-left chip shows only when ending soon', (tester) async {
      await tester.pumpWidget(_host(const TimeLeftChip(
        timeLeft: TimeLeft(
          status: 'ending', label: '2d 3h left', secondsLeft: 183600,
          isExpiringSoon: true,
        ),
      )));
      expect(find.byKey(const Key('time-left-chip')), findsOneWidget);
      expect(find.text('Ends in 2d 3h'), findsOneWidget);

      await tester.pumpWidget(_host(const TimeLeftChip(
        timeLeft: TimeLeft(status: 'live', label: '40d 0h left', secondsLeft: 3456000),
      )));
      expect(find.byKey(const Key('time-left-chip')), findsNothing);
    });

    testWidgets('owner banner offers renewal when ending', (tester) async {
      var renewed = false;
      await tester.pumpWidget(_host(TimeLeftBanner(
        timeLeft: TimeLeft(
          status: 'ending', label: '1d 2h left', secondsLeft: 93600,
          goesOfflineAt: DateTime.now().add(const Duration(days: 1)),
          isExpiringSoon: true,
        ),
        subject: 'Your listing',
        onRenew: () => renewed = true,
      )));
      expect(find.textContaining('text you 2 days before'), findsOneWidget);
      await tester.tap(find.byKey(const Key('time-left-renew')));
      expect(renewed, isTrue);
    });

    testWidgets('banner shows while slots remain even with billing off', (tester) async {
      // The production state: fees off, nobody eligible yet, slots left.
      await tester.pumpWidget(_host(const LaunchOfferBanner(
        offer: LaunchOffer(
          limit: 50, claimed: 0, remaining: 50, freeDays: 60,
          eligible: false, enabled: false,
        ),
        kind: LaunchOfferKind.listing,
      )));
      expect(find.byKey(const Key('launch-offer-listing')), findsOneWidget);
      expect(find.text('50 left'), findsOneWidget);
    });

    testWidgets('dashboard offers card shows both offers with CTAs', (tester) async {
      var posted = false;
      var opened = false;
      await tester.pumpWidget(_host(LaunchOffersCard(
        offers: const LaunchOffers(
          listingFree: LaunchOffer(
            limit: 50, claimed: 40, remaining: 10, freeDays: 60,
            eligible: false, enabled: false,
          ),
          storeFree: LaunchOffer(
            limit: 10, claimed: 9, remaining: 1, freeDays: 60,
            eligible: false, enabled: false,
          ),
        ),
        onPostListing: () => posted = true,
        onOpenStore: () => opened = true,
      )));
      expect(find.byKey(const Key('launch-offers-card')), findsOneWidget);
      expect(find.text('First 50 listings free'), findsOneWidget);
      expect(find.text('First 10 online stores free'), findsOneWidget);
      expect(find.textContaining('10 of 50 left'), findsOneWidget);
      expect(find.textContaining('never pay a listing fee'), findsOneWidget);
      await tester.tap(find.text('Post free'));
      await tester.tap(find.text('Open free'));
      expect(posted, isTrue);
      expect(opened, isTrue);
    });

    testWidgets('listing time-left row always shows, including no expiry', (tester) async {
      await tester.pumpWidget(_host(const ListingTimeLeftRow(
        timeLeft: TimeLeft(status: 'unlimited', label: 'No expiry'),
      )));
      expect(find.byKey(const Key('listing-time-left-row')), findsOneWidget);
      expect(find.textContaining('No expiry'), findsOneWidget);
      expect(find.byKey(const Key('listing-time-left-renew')), findsNothing);

      var renewed = false;
      await tester.pumpWidget(_host(ListingTimeLeftRow(
        timeLeft: TimeLeft(
          status: 'ending', label: '1d 2h left', secondsLeft: 93600,
          goesOfflineAt: DateTime.now().add(const Duration(days: 1)),
          isExpiringSoon: true,
        ),
        onRenew: () => renewed = true,
      )));
      expect(find.textContaining('goes offline'), findsOneWidget);
      expect(find.textContaining('text you 2 days before'), findsOneWidget);
      await tester.tap(find.byKey(const Key('listing-time-left-renew')));
      expect(renewed, isTrue);

      await tester.pumpWidget(_host(const ListingTimeLeftRow(
        timeLeft: TimeLeft(status: 'store_covered', label: 'Live via store plan'),
      )));
      expect(find.textContaining('store plan'), findsOneWidget);
    });

    testWidgets('offer state line speaks for available, claimed and ended offers', (tester) async {
      await tester.pumpWidget(_host(const OfferStateLine(
        offer: LaunchOffer(limit: 10, claimed: 9, remaining: 1, freeDays: 60),
        kind: LaunchOfferKind.store,
      )));
      expect(find.byKey(const Key('offer-state-line')), findsOneWidget);
      expect(find.textContaining('only 1 left'), findsOneWidget);

      await tester.pumpWidget(_host(const OfferStateLine(
        offer: LaunchOffer(limit: 10, claimed: 10, remaining: 0, freeDays: 60),
        kind: LaunchOfferKind.store,
      )));
      expect(find.textContaining('have been claimed'), findsOneWidget);

      await tester.pumpWidget(_host(const OfferStateLine(
        offer: LaunchOffer(limit: 50, claimed: 3, remaining: 47, freeDays: 60, alreadyClaimed: true),
        kind: LaunchOfferKind.listing,
      )));
      expect(find.textContaining('is claimed'), findsOneWidget);

      // Existing store that missed the claim: says so, with slots left.
      await tester.pumpWidget(_host(const OfferStateLine(
        offer: LaunchOffer(limit: 10, claimed: 5, remaining: 5, freeDays: 60),
        kind: LaunchOfferKind.store,
        existingStore: true,
      )));
      expect(find.textContaining('opened without one'), findsOneWidget);

      // Not configured: silent.
      await tester.pumpWidget(_host(const OfferStateLine(
        offer: LaunchOffer(limit: 0, claimed: 0, remaining: 0, freeDays: 60),
        kind: LaunchOfferKind.store,
      )));
      expect(find.byKey(const Key('offer-state-line')), findsNothing);
    });

    testWidgets('store-covered banner explains no fee', (tester) async {
      await tester.pumpWidget(_host(const StoreCoveredBanner(storeName: 'Clanix')));
      expect(find.byKey(const Key('store-covered-banner')), findsOneWidget);
      expect(find.textContaining('covered by the store plan'), findsOneWidget);
      // BrokaColors is exercised through the banner's styling.
      expect(BrokaColors.success, isNotNull);
    });
  });
}
