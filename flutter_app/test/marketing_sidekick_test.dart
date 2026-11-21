// The Marketing Studio's four areas, driven through the real repository and
// fake transport.
//
// What must hold:
//   * the studio opens on Overview and Sidekick/Creative/Ads are one tap away;
//   * a Sidekick question is sent with the chosen platform and the answer
//     says whether it is AI or BROKA's own guidance;
//   * a Sidekick action opens Creative Studio with the same product chosen -
//     the seller does not choose it twice;
//   * generating a creative sends the chosen product, platform, objective and
//     format, and a failure keeps every selection and the typed offer;
//   * the Meta Ads plan is shown as a checklist and never as a created
//     campaign.
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/presentation/marketing_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _storeJson() => {
      'id': 's1',
      'name': 'Clanix Electronics',
      'slug': 'clanix',
      'url': 'https://broka.co.ke/store/clanix',
      'category': 'Electronics',
      'is_active': true,
      'listing_count': 1,
    };

Map<String, dynamic> _productJson() => {
      'id': 'l1',
      'seller_id': 'u1',
      'name': 'Solar Lantern',
      'category': 'Electronics',
      'price': 2500.0,
      'price_unit': null,
      'lat': -1.0,
      'lng': 36.0,
      'location_name': 'Nairobi',
      'created_at': '2026-10-20T09:00:00',
      'status': 'active',
      'is_active': true,
      'store_state': 'live',
      'description': 'Brand new solar lantern.',
      'seller_name': 'Seller',
    };

Map<String, dynamic> _campaignJson() => {
      'id': 'c1',
      'title': 'Solar week',
      'objective': 'product',
      'tone': 'friendly',
      'language': 'en',
      'product_ids': ['l1'],
      'products': [
        {'id': 'l1', 'name': 'Solar Lantern', 'price': 2500.0},
      ],
      'platforms': ['instagram'],
      'status': 'generated',
      'link_token': 'tok1',
      'links': {
        'instagram': 'https://broka.co.ke/store/clanix?via=instagram&c=tok1',
      },
      'store_url': 'https://broka.co.ke/store/clanix?via=direct&c=tok1',
      'creatives': [
        {
          'id': 'cr1',
          'platform': 'instagram',
          'format': 'caption',
          'headline': 'Solar Lantern',
          'body': 'Solar Lantern is available at KES 2,500.',
          'hashtags': ['BROKA', 'Kenya'],
          'cta': 'Open the link',
          'media': {'aspect_ratio': '1:1'},
          'source': 'template',
        },
      ],
      'plan': const <Object?>[],
      'events': {
        'by_kind': const <String, int>{},
        'by_platform': const <String, int>{},
        'measured': const <String>[],
        'not_measured': const <String>[],
      },
      'generation': {'provider': 'template', 'fallback': true},
      'created_at': '2026-10-20T09:00:00',
      'updated_at': '2026-10-20T09:00:00',
    };

Map<String, dynamic> _sidekickJson() => {
      'reply':
          'Start with the Solar Lantern at KES 2,500. Post a close-up on Instagram, '
              'then put the store link in your bio and answer questions in the comments.',
      'provider': 'template',
      'available': false,
      'fallback_reason':
          "No AI provider is configured on the server, so this is BROKA's standard "
              'guidance built from your store details.',
      'platform': 'instagram',
      'products': [
        {
          'id': 'l1',
          'name': 'Solar Lantern',
          'price': 2500.0,
          'price_label': 'KES 2,500'
        },
      ],
      'actions': [
        {
          'type': 'creative_studio',
          'label': 'Create an Instagram post',
          'description': 'Open Creative Studio with Solar Lantern selected.',
          'platform': 'instagram',
          'product_id': 'l1',
          'objective': 'product',
          'creative_format': 'caption',
        },
        {
          'type': 'platform_guide',
          'label': 'See the full Instagram guide',
          'platform': 'instagram',
        },
        {
          'type': 'meta_ads',
          'label': 'Plan a Meta ad for Solar Lantern',
          'product_id': 'l1',
        },
      ],
      'suggestions': ['What should I post on Instagram this week?'],
    };

Map<String, dynamic> _adsPlanJson() => {
      'product': {
        'id': 'l1',
        'name': 'Solar Lantern',
        'price': 2500.0,
        'price_label': 'KES 2,500',
      },
      'store': {'id': 's1', 'name': 'Clanix Electronics'},
      'currency': 'KES',
      'objective': 'traffic',
      'objective_label': 'Traffic',
      'objective_options': [
        {
          'value': 'traffic',
          'label': 'Traffic',
          'when': 'Send people to your storefront.'
        },
        {
          'value': 'sales',
          'label': 'Sales',
          'when': 'Send buyers to a product.'
        },
      ],
      'audience': 'People interested in Electronics',
      'location': 'Nairobi',
      'budget': {
        'daily_kes': 750,
        'trial_days': 5,
        'total_kes': 3750,
        'note': 'A starting point for testing, not a prediction of results.',
      },
      'stages': [
        {
          'key': 'objective',
          'title': '1. Choose the objective',
          'summary': 'Recommended: Traffic.',
          'suggestion': 'Traffic',
          'steps': ['Open Meta Ads Manager and choose Create.'],
        },
        {
          'key': 'launch',
          'title': '8. Finish in Meta Ads Manager',
          'summary': 'BROKA does not create or publish the campaign.',
          'suggestion': 'https://adsmanager.facebook.com/',
          'steps': ['Open Meta Ads Manager and complete the campaign there.'],
        },
      ],
      'manager_url':
          'https://adsmanager.facebook.com/adsmanager/manage/campaigns',
      'campaign_created': false,
      'disclaimer': 'BROKA has not created or published a campaign. This is a plan '
          'for you to complete in Meta Ads Manager, where Meta sets the final '
          'prices and rules. BROKA does not process buyer-to-seller payments.',
    };

bool _failCampaignCreation = false;

Object? _route(Uri uri) {
  final path = uri.path;
  if (path.endsWith('/manage/listings')) {
    return {
      'items': [_productJson()],
      'counts': {
        'all': 1,
        'live': 1,
        'hidden': 0,
        'in_deal': 0,
        'sold': 0,
        'archived': 0
      },
    };
  }
  if (path.endsWith('/marketing/sidekick')) return _sidekickJson();
  if (path.endsWith('/marketing/ads-plan')) return _adsPlanJson();
  if (path.endsWith('/marketing/campaigns')) {
    // The list request carries paging; the create request does not.
    if (uri.queryParameters.containsKey('limit')) {
      return {'items': const <Object?>[], 'total': 0};
    }
    if (_failCampaignCreation) return const FakeResponse.error(statusCode: 500);
    return _campaignJson();
  }
  if (path.endsWith('/marketing/campaigns/c1')) return _campaignJson();
  return null;
}

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    _failCampaignCreation = false;
    clearFakeRequests();
    setFakeRoute(_route);
  });

  Future<void> pumpStudio(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarketingStudioTab(
          store: Store.fromJson(_storeJson()),
          repo: StoresRepository(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the studio opens on Overview with the other areas one tap away',
      (tester) async {
    await pumpStudio(tester);

    expect(find.byKey(const Key('marketing-overview')), findsOneWidget);
    expect(find.text('Marketing Studio'), findsOneWidget);
    for (final label in const ['Overview', 'Sidekick', 'Creative', 'Ads']) {
      expect(find.text(label), findsOneWidget);
    }
    // The overview's counts are BROKA's observed events, not ad metrics.
    expect(find.textContaining('Impressions, reach and ad'), findsOneWidget);

    await tester.tap(find.byKey(const Key('marketing-section-sidekick')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sidekick-welcome')), findsOneWidget);
    expect(find.text('Your marketing Sidekick'), findsOneWidget);
    expect(find.text('How should I market my store?'), findsOneWidget);
  });

  testWidgets(
      'a Sidekick answer is labelled and can open Creative Studio with '
      'the same product', (tester) async {
    await pumpStudio(tester);
    await tester.tap(find.byKey(const Key('marketing-section-sidekick')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('sidekick-input')),
        'How should I market my store?');
    await tester.tap(find.byKey(const Key('sidekick-send')));
    await tester.pumpAndSettle();

    final sent = fakeRequests
        .firstWhere((r) => r.uri.path.endsWith('/marketing/sidekick'));
    expect((sent.json as Map)['message'], 'How should I market my store?');
    // The store's own product and price are in the answer.
    expect(find.textContaining('Solar Lantern at KES 2,500'), findsOneWidget);
    // A template answer is never passed off as a model's.
    expect(find.text('BROKA guidance'), findsOneWidget);
    expect(find.textContaining('No AI provider is configured'), findsOneWidget);

    await tester.ensureVisible(
        find.byKey(const Key('sidekick-action-creative_studio-instagram')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const Key('sidekick-action-creative_studio-instagram')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('marketing-creative')), findsOneWidget);
    expect(find.byKey(const Key('creative-product-l1')), findsOneWidget);
    // The product came across already chosen, and the platform with it.
    expect(find.text('Generate creative'), findsOneWidget);
  });

  testWidgets('generating a creative sends the real choices', (tester) async {
    await pumpStudio(tester);
    await tester.tap(find.byKey(const Key('marketing-section-creative')));
    await tester.pumpAndSettle();

    await tester
        .ensureVisible(find.byKey(const Key('creative-platform-instagram')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('creative-platform-instagram')));
    await tester.pumpAndSettle();

    await tester
        .ensureVisible(find.byKey(const Key('creative-format-caption')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('creative-format-caption')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('creative-generate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('creative-generate')));
    await tester.pumpAndSettle();

    final post = fakeRequests.firstWhere((r) =>
        r.method == 'POST' && r.uri.path.endsWith('/marketing/campaigns'));
    final body = post.json as Map;
    expect(body['product_ids'], ['l1']);
    expect(body['platforms'], ['instagram']);
    expect(body['objective'], 'product');
    expect(body['creative_format'], 'caption');
    expect(body['generate'], true);

    // The campaign detail is the preview/edit/share step.
    expect(find.text('Campaign'), findsOneWidget);
    expect(find.textContaining('KES 2,500'), findsWidgets);
  });

  testWidgets("a failed generation keeps the seller's choices and words",
      (tester) async {
    _failCampaignCreation = true;
    await pumpStudio(tester);
    await tester.tap(find.byKey(const Key('marketing-section-creative')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('creative-instructions')),
        'Mention delivery to Kisumu');
    await tester.ensureVisible(find.byKey(const Key('creative-generate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('creative-generate')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('creative-error')), findsOneWidget);
    // Nothing was published, and the offer the seller typed is still there.
    expect(find.text('Mention delivery to Kisumu'), findsOneWidget);
    expect(find.byKey(const Key('creative-product-l1')), findsOneWidget);
    // No campaign detail was opened from a failed request.
    expect(find.text('Campaign'), findsNothing);
  });

  testWidgets('the Meta Ads plan is a checklist, not a created campaign',
      (tester) async {
    await pumpStudio(tester);
    await tester.tap(find.byKey(const Key('marketing-section-ads')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ads-budget')), '750');
    await tester.ensureVisible(find.byKey(const Key('ads-build-plan')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ads-build-plan')));
    await tester.pumpAndSettle();

    final sent = fakeRequests
        .firstWhere((r) => r.uri.path.endsWith('/marketing/ads-plan'));
    expect((sent.json as Map)['budget_kes'], 750);
    expect((sent.json as Map)['product_id'], 'l1');

    expect(
        find.textContaining('BROKA has not created or published a campaign.'),
        findsOneWidget);
    expect(find.text('Open Meta Ads Manager'), findsOneWidget);

    // Scroll this tab's own list down to the checklist cards.
    await tester.drag(
        find.byKey(const Key('marketing-ads')), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const Key('marketing-ads')), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ads-stage-objective')), findsOneWidget);
    expect(find.text('1. Choose the objective'), findsOneWidget);
    expect(find.text('Traffic'), findsWidgets);
  });
}
