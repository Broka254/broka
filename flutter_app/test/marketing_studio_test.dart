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
import 'package:broka/features/stores/domain/models/store_campaign.dart';
import 'package:broka/features/stores/presentation/marketing_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_api.dart';

class _FakeShare implements CreativeShare {
  _FakeShare({this.outcome = CreativeShareOutcome.shared});

  final CreativeShareOutcome outcome;
  final List<({String url, String caption})> images = [];
  final List<String> texts = [];

  @override
  Future<CreativeShareOutcome> image(
    String url, {
    required String caption,
    String? fileName,
    Rect? origin,
  }) async {
    images.add((url: url, caption: caption));
    return outcome;
  }

  @override
  Future<CreativeShareOutcome> text(String text, {Rect? origin}) async {
    texts.add(text);
    return outcome;
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

  String? copied;
  setUp(() {
    share = _FakeShare();
    clearFakeRequests();
    // A widget test has no clipboard behind SystemChannels.platform: without
    // a handler the write never completes, so the screen never says it copied
    // and the phone's own clipboard has to stand in here.
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
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
    // A poster sent on its own still carries the campaign's tracked link.
    expect(share.images.single.caption, contains('c=krafty-token-1'));

    // And the server heard exactly one save.
    final event = fakeRequests.where((r) => r.method == 'POST').toList().single;
    expect(event.uri.path, '/stores/s1/marketing/campaigns/c1/events');
    expect(event.json, {'kind': 'downloaded', 'platform': 'whatsapp'});
  });

  testWidgets('a share sheet that cannot open records nothing', (tester) async {
    share = _FakeShare(outcome: CreativeShareOutcome.failed);
    await pump(tester);

    await tester.ensureVisible(find.byKey(const Key('save-image-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-image-w1')));
    await tester.pumpAndSettle();

    expect(fakeRequests.where((r) => r.method == 'POST'), isEmpty);
    expect(find.textContaining("Couldn't get the image ready"), findsOneWidget);
  });

  testWidgets('a dismissed share sheet is not a download', (tester) async {
    share = _FakeShare(outcome: CreativeShareOutcome.dismissed);
    await pump(tester);

    await tester.ensureVisible(find.byKey(const Key('save-image-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-image-w1')));
    await tester.pumpAndSettle();

    expect(fakeRequests.where((r) => r.method == 'POST'), isEmpty);
    expect(find.text('Nothing was saved.'), findsOneWidget);
  });

  testWidgets('copying a caption is not counted as a share', (tester) async {
    await pump(tester);

    await tester.ensureVisible(find.byKey(const Key('copy-caption-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('copy-caption-w1')));
    await tester.pumpAndSettle();

    // The caption reached the clipboard, but BROKA did not see it posted:
    // "Times you shared" must stay untouched.
    expect(copied, contains('KES 2,500'));
    expect(find.text('Caption copied'), findsOneWidget);
    expect(fakeRequests.where((r) => r.method == 'POST'), isEmpty);
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

  testWidgets('a video script shows its shots, voice-over and duration',
      (tester) async {
    final tiktok = {
      'id': 't1',
      'platform': 'tiktok',
      'format': 'script',
      'headline': 'Looking for Solar Lantern?',
      'body': 'HOOK (0-3s): Looking for Solar Lantern?',
      'hashtags': <String>['BROKA'],
      'cta': 'Open the link to see more.',
      'media': {
        'aspect_ratio': '9:16',
        'duration_seconds': 20,
        'template': 'vertical_script',
        'scenes': [
          {
            'shot': 'Product on a clean surface',
            'on_screen_text': 'Solar Lantern',
            'voice_over': 'Solar Lantern is available at Clanix.',
            'seconds': 3,
          },
          {
            'shot': 'Close-up detail',
            'on_screen_text': 'KES 2,500',
            'voice_over': 'Price: KES 2,500.',
            'seconds': 5,
          },
        ],
      },
      'source': 'template',
    };
    await pump(tester, campaign: {
      ..._campaign(),
      'platforms': <String>['tiktok'],
      'creatives': [tiktok],
      'links': {
        'tiktok': 'https://broka.co.ke/store/clanix?via=tiktok&c=krafty-token-1',
      },
    });

    expect(find.text('Shot list'), findsOneWidget);
    // The planned length is shown, so the script is not mistaken for a
    // finished video.
    expect(find.text('9:16 · 20s'), findsOneWidget);
    expect(find.text('Product on a clean surface'), findsOneWidget);
    expect(find.text('On screen: Solar Lantern'), findsOneWidget);
    expect(find.text('Voice-over: Solar Lantern is available at Clanix.'), findsOneWidget);
    expect(find.text('3s'), findsOneWidget);
    expect(find.textContaining('has not filmed'), findsOneWidget);
  });

  group('the shared text', () {
    const link = 'https://broka.co.ke/store/clanix?via=x&c=token12345678';
    CampaignCreative creative({
      String platform = 'x',
      String body = 'Solar Lantern at Clanix.',
      List<String> hashtags = const ['BROKA', 'Kenya'],
      String format = 'post',
    }) =>
        CampaignCreative(
          id: 'c',
          platform: platform,
          format: format,
          headline: '',
          body: body,
          hashtags: hashtags,
          cta: '',
          media: const {},
        );

    test('an old body with the link does not get it twice', () {
      final text = creative(
        platform: 'whatsapp',
        format: 'message',
        body: 'Solar Lantern is available.\n\n$link',
      ).shareText(link);
      expect(RegExp(r'https?://').allMatches(text).length, 1);
    });

    test('an X post, link and hashtags stay within 280 characters', () {
      final text = creative(
        body: 'A' * 400,
        hashtags: const ['BROKA', 'Kenya', 'Electronics'],
      ).shareText(link);
      expect(text.length, lessThanOrEqualTo(280));
      expect(text, contains(link));
    });
  });
}
