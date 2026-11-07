import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/models/store.dart';

typedef StoreUrlLauncher = Future<bool> Function(Uri uri, LaunchMode mode);

/// Uses the API-provided store link when it is a canonical BROKA storefront.
/// Older or incomplete payloads fall back to the slug-based public route.
Uri? storeWebsiteUri(Store store) {
  final slug = store.slug.trim().toLowerCase();
  if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(slug)) return null;

  final supplied = Uri.tryParse(store.url.trim());
  final isBrokaHost = supplied != null &&
      const {'broka.co.ke', 'www.broka.co.ke'}
          .contains(supplied.host.toLowerCase());
  final segments = supplied?.pathSegments ?? const <String>[];
  if (supplied != null &&
      supplied.scheme.toLowerCase() == 'https' &&
      isBrokaHost &&
      segments.length == 2 &&
      segments.first == 'store' &&
      segments.last.toLowerCase() == slug) {
    return supplied;
  }

  return Uri.https('broka.co.ke', '/store/$slug');
}

/// Opens the store website, not the reusable in-app StoreHomeScreen.
/// In-app browser mode prevents Android's verified /store app link from
/// handing this deliberate website visit back to the generic app screen.
Future<bool> launchStoreWebsite(
  Store store, {
  StoreUrlLauncher? launcher,
}) async {
  final uri = storeWebsiteUri(store);
  if (uri == null) return false;

  final StoreUrlLauncher open = launcher ??
      ((uri, mode) => launchUrl(uri, mode: mode));
  try {
    return await open(uri, LaunchMode.inAppBrowserView);
  } on Exception {
    return false;
  }
}

/// Gives the user feedback rather than silently leaving a dead tap if the
/// browser cannot open the store's public URL.
Future<void> visitStoreWebsite(
  BuildContext context,
  Store store, {
  StoreUrlLauncher? launcher,
}) async {
  final opened = await launchStoreWebsite(store, launcher: launcher);
  if (opened || !context.mounted) return;

  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    const SnackBar(
      content: Text("Couldn't open this store's website. Please try again."),
    ),
  );
}
