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
      name: 'Clanix',
      slug: slug,
      url: url,
    );

void main() {
  test('opens the exact public store URL in an in-app browser view', () async {
    final store = _store();
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
    expect(openedUri, Uri.parse(store.url));
    expect(openedMode, LaunchMode.inAppBrowserView);
  });

  test('falls back to the official BROKA slug URL, never an arbitrary host',
      () async {
    final store = _store(url: 'https://untrusted.example/store/clanix');
    Uri? openedUri;

    final opened = await launchStoreWebsite(
      store,
      launcher: (uri, _) async {
        openedUri = uri;
        return true;
      },
    );

    expect(opened, isTrue);
    expect(openedUri, Uri.parse('https://broka.co.ke/store/clanix'));
  });

  testWidgets(
    'shows a visible message when the store URL cannot be opened',
    (tester) async {
      final store = _store();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => visitStoreWebsite(
                  context,
                  store,
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
    },
  );
}
