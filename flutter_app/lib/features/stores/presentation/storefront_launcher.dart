import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/models/store.dart';

typedef StoreUrlLauncher = Future<bool> Function(Uri uri, LaunchMode mode);

/// What opens a store's website when a caller passes no launcher: for a
/// widget test of a screen whose button calls [visitStoreBySlug] itself.
@visibleForTesting
StoreUrlLauncher? storeUrlLauncherOverride;

/// The web storefront's canonical route is `/store/<slug>` (web/src/lib/links.ts).
/// Use the immutable slug, never a display name, store ID, or a legacy plural
/// `/stores/<slug>` URL from an older payload.
Uri? storeWebsiteUriForSlug(String? rawSlug) {
  final slug = rawSlug?.trim().toLowerCase();
  if (slug == null || !RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(slug)) return null;
  return Uri.https('www.broka.co.ke', '/store/$slug');
}

/// Opens the store's home **in the app** - StoreHomeScreen on '/store-view'.
///
/// Every in-app card and store badge goes here (2026-11-08). Sending those
/// taps to the website instead put a screen the app already has behind an
/// in-app browser, losing the cart, Follow and in-app checkout a buyer in
/// BROKA expects. The website stays a deliberate destination: a shared link,
/// or a seller's own "View as a buyer".
Future<void> openStoreHome(
  BuildContext context, {
  String? storeId,
  String? slug,
  String? via,
}) {
  final id = storeId?.trim();
  final link = slug?.trim().toLowerCase();
  final source = via?.trim();
  return Navigator.of(context).pushNamed('/store-view', arguments: {
    if (id != null && id.isNotEmpty) 'storeId': id,
    if (link != null && link.isNotEmpty) 'slug': link,
    if (source != null && source.isNotEmpty) 'via': source,
  });
}

Future<void> openStoreHomeFor(BuildContext context, Store store) =>
    openStoreHome(context, storeId: store.id, slug: store.slug);

Future<bool> _launchStoreWebsiteUri(
  Uri? uri, {
  StoreUrlLauncher? launcher,
}) async {
  if (uri == null) return false;

  final StoreUrlLauncher open = launcher ??
      storeUrlLauncherOverride ??
      ((uri, mode) => launchUrl(uri, mode: mode));
  try {
    return await open(uri, LaunchMode.inAppBrowserView);
  } on Exception {
    return false;
  }
}

/// Opens the dedicated website - for a shared link or a seller previewing
/// their own public storefront, never for an in-app store card
/// ([openStoreHome] is that). In-app browser mode prevents Android's
/// verified `/store` app link from handing this deliberate website visit
/// back to the app screen.
Future<bool> launchStoreWebsite(
  Store store, {
  StoreUrlLauncher? launcher,
}) =>
    _launchStoreWebsiteUri(
      storeWebsiteUriForSlug(store.slug),
      launcher: launcher,
    );

/// Opens a storefront from a product feed that only has its immutable slug.
Future<bool> launchStoreBySlug(
  String? slug, {
  StoreUrlLauncher? launcher,
}) =>
    _launchStoreWebsiteUri(
      storeWebsiteUriForSlug(slug),
      launcher: launcher,
    );

/// Gives the user feedback rather than silently leaving a dead tap if the
/// browser cannot open the store's public URL.
Future<void> _visitStoreUri(
  BuildContext context,
  Future<bool> Function() open,
) async {
  final opened = await open();
  if (opened || !context.mounted) return;

  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    const SnackBar(
      content: Text("Couldn't open this store's website. Please try again."),
    ),
  );
}

Future<void> visitStoreWebsite(
  BuildContext context,
  Store store, {
  StoreUrlLauncher? launcher,
}) =>
    _visitStoreUri(
      context,
      () => launchStoreWebsite(store, launcher: launcher),
    );

Future<void> visitStoreBySlug(
  BuildContext context,
  String? slug, {
  StoreUrlLauncher? launcher,
}) =>
    _visitStoreUri(
      context,
      () => launchStoreBySlug(slug, launcher: launcher),
    );
