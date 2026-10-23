// The Marketing Studio's last step: a generated poster leaves the phone
// through the share sheet, and the server hears about it once - as a save,
// not an impression, a post or a sale.
//
// What must hold:
//   * "Save image" hands the server-rendered poster URL and the campaign's
//     own caption to the device bridge;
//   * the download is recorded only after the sheet opens (a device that
//     cannot share must not look like a successful save);
//   * "Share post" sends the edited caption plus this campaign's tracked
//     link, not the store URL without a token;
//   * a creative with no rendered poster has no Save button - nothing on
//     the screen claims a file exists when it does not.
import 'package:broka/features/stores/data/creative_share.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/presentation/marketing_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_api.dart';

class _FakeShare implements CreativeShare {
  _FakeShare({this.works = true});

  final bool works;
  final List<({String url, String caption})> images = [];
  final List<String> texts = [];

  @override
  Future<bool> image(
    String url, {
    required String caption,
    String? fileName,
    Rect? origin,
  }) async {
    images.add((url: url, caption: caption));
    return works;
  }

  @override
  Future<bool> text(String text, {Rect? origin}) async {
    texts.add(text);
    return works;
  }
}

Map<String, dynamic> _storeJson() => {
      'id': 's1',
      'name': 'Clanix Electronics',
      'slug': 'clanix',
      'url': 'https://broka.co.ke/store/clanix',
      'category': 'Electronics',
      'is_active': true,
      'listing_count': 1,
    };

Map<String, dynamic> _creative({String? image}) => {
      'id': 'w1',
      'platform': 'whatsapp',
      'format': 'message',
      'headline': 'Solar Lantern at Clanix',
      'body': 'Solar Lantern is available at Clanix Electronics.\nPrice: KES 2,500.',
      'hashtags': <String>[],
      'cta': 'Open the link to see more.',
      'media': {'aspect_ratio': '9:16', 'template': 'product_card'},
      'source': 'template',
      if (image != null)
        'asset': {'id': 'a1', 'thumb': image, 'medium': image, 'large': image},
    };

Map<String, dynamic> _campaign() => {
      'id': 'c1',
      'title': 'New stock at Clanix',
      'objective': 'new_stock',
      'tone': 'friendly',
      'language': 'en',
      'product_ids': <String>['l1'],
      'products': [
        {'id': 'l1', 'name': 'Solar Lantern', 'price': 2500},
      ],
      'platforms': <String>['whatsapp'],
      'status': 'generated',
      'link_token': 'krafty-token-1',
      'links': {
        'whatsapp': 'https://broka.co.ke/store/clanix?via=whatsapp&c=krafty-token-1',
      },
      'store_url': 'https://broka.co.ke/store/clanix?via=direct&c=krafty-token-1',
      'creatives': [_creative(image: 'https://cdn.broka.co.ke/a1/large.webp')],
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

void main() {
  setUpAll(installFakeApi);
  late _FakeShare share;

  setUp(() {
    share = _FakeShare();
    clearFakeRequests();
  });

  Future<void> pump(WidgetTester tester, {Map<String, dynamic>? campaign}) async {
    setFakeRoute((uri) {
      if (uri.path.endsWith('/marketing/campaigns/c1') && uri.path.startsWith('/stores/')) {
        return campaign ?? _campaign();
      }
      if (uri.path.endsWith('/events')) {
        return {
          'by_kind': {'downloaded': 1, 'shared': 1},
          'by_platform': {'whatsapp': 2},
          'measured': const <String>[],
          'not_measured': const <String>[],
        };
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      home: CampaignDetailScreen(
        store: Store.fromJson(_storeJson()),
        repo: StoresRepository(),
        campaignId: 'c1',
        share: share,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Save image hands the real poster and caption to the share sheet',
      (tester) async {
    await pump(tester);

    await tester.ensureVisible(find.byKey(const Key('save-image-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-image-w1')));
    await tester.pumpAndSettle();

    expect(share.images, hasLength(1));
    expect(share.images.single.url, 'https://cdn.broka.co.ke/a1/large.webp');
    expect(share.images.single.caption, contains('KES 2,500'));

    // And the server heard exactly one save.
    final event = fakeRequests.where((r) => r.method == 'POST').toList().single;
    expect(event.uri.path, '/stores/s1/marketing/campaigns/c1/events');
    expect(event.json, {'kind': 'downloaded', 'platform': 'whatsapp'});
  });

  testWidgets('a share sheet that cannot open records nothing', (tester) async {
    share = _FakeShare(works: false);
    await pump(tester);

    await tester.ensureVisible(find.byKey(const Key('save-image-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-image-w1')));
    await tester.pumpAndSettle();

    expect(fakeRequests.where((r) => r.method == 'POST'), isEmpty);
    expect(find.textContaining("Couldn't get the image ready"), findsOneWidget);
  });

  testWidgets('Share post sends the caption with this campaign link', (tester) async {
    await pump(tester);

    await tester.ensureVisible(find.byKey(const Key('share-post-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-post-w1')));
    await tester.pumpAndSettle();

    expect(share.texts.single, contains('c=krafty-token-1'));
    expect(share.texts.single, contains('Solar Lantern'));
    final event = fakeRequests.where((r) => r.method == 'POST').toList().single;
    expect(event.json, {'kind': 'shared', 'platform': 'whatsapp'});
  });

  testWidgets('a creative with no rendered poster offers no Save button',
      (tester) async {
    await pump(
      tester,
      campaign: {..._campaign(), 'creatives': [_creative()]},
    );

    expect(find.byKey(const Key('save-image-w1')), findsNothing);
    expect(find.byKey(const Key('share-post-w1')), findsOneWidget);
  });
}
