import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/presentation/storefront_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/url_launcher.dart';

Store _store({
  String slug = 'clanix',
  String url = 'https://www.broka.co.ke/store/clanix',
}) =>
    Store(
      id: 'store-1',
      name: 'Clanix Online Shop',
      slug: slug,
      url: url,
    );

void main() {
  test('builds the dedicated public route from the immutable store slug', () {
    expect(
      storeWebsiteUriForSlug('Clanix-2'),
      Uri.parse('https://www.broka.co.ke/store/clanix-2'),
    );
    expect(storeWebsiteUriForSlug(null), isNull);
    expect(storeWebsiteUriForSlug('  '), isNull);
    expect(storeWebsiteUriForSlug('../clanix'), isNull);
  });

  test('opens the canonical singular URL in an in-app browser view', () async {
    // A stale plural/profile URL in an API payload must never send the buyer
    // back to the generic page; the immutable slug is the source of truth.
    final store = _store(
      slug: 'clanix-2',
      url: 'https://www.broka.co.ke/stores/clanix-2',
    );
    Uri? openedUri;
    LaunchMode? openedMode;

    final opened = await launchStoreWebsite(
      store,
      launcher: (uri, mode) async {
        openedUri = uri;
        openedMode = mode;
        return true;
      },
    );

    expect(opened, isTrue);
    expect(openedUri, Uri.parse('https://www.broka.co.ke/store/clanix-2'));
    expect(openedMode, LaunchMode.inAppBrowserView);
  });

  test('opens a product-feed store from its slug', () async {
    Uri? openedUri;

    final opened = await launchStoreBySlug(
      'clanix',
      launcher: (uri, _) async {
        openedUri = uri;
        return true;
      },
    );

    expect(opened, isTrue);
    expect(openedUri, Uri.parse('https://www.broka.co.ke/store/clanix'));
  });

  testWidgets('shows feedback when the slug is missing or launch fails',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => visitStoreBySlug(
                context,
                null,
                launcher: (_, __) async => false,
              ),
              child: const Text('Open store'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open store'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.text("Couldn't open this store's website. Please try again."),
      findsOneWidget,
    );
  });
}
