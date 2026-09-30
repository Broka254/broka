// Store links opening in the app.
//
// https://broka.co.ke/store/<name>            -> the store's home
// https://broka.co.ke/store/<name>/about      -> its Store details
// https://broka.co.ke/store/<name>/p/<id>     -> one of its products
// (www.broka.co.ke too; a ?via= tag is kept for the owner's visit stats.)
//
// Android hands these links to MainActivity (intent filters in
// AndroidManifest.xml), which passes them here over the
// "com.broka.app/links" channel: the link that launched the app
// ("getInitialLink"), and links arriving while it runs ("onLink").
//
// A link that arrives before the app is ready - cold start, while the
// splash screen is still deciding where to go - is held until the splash
// calls [appReady], then opened on top of wherever the splash went, so Back
// returns to Home rather than closing the app.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/utils/result.dart';
import '../features/stores/data/repositories/stores_repository.dart';

/// Where a link points.
@immutable
class StoreLinkTarget {
  const StoreLinkTarget({
    required this.slug,
    this.listingId,
    this.via,
    this.details = false,
    this.cart,
  });

  final String slug;

  /// Set for a product link.
  final String? listingId;

  /// The link's ?via= tag.
  final String? via;

  /// A link to the store's details page (/store/<name>/about). Every
  /// /store/ link opens the app, so one it didn't know opened nothing.
  final bool details;

  /// A link to the store's cart (/store/<name>/cart?items=<id>:<qty>,...):
  /// the web storefront's "check out in the app" - the products and how
  /// many of each, to put in the phone's cart for this store. Null for any
  /// other link; empty for a cart link without items.
  final Map<String, int>? cart;

  bool get isProduct => listingId != null;

  /// At most this many products come in through one link.
  static const maxCartItems = 30;

  static const _hosts = {'broka.co.ke', 'www.broka.co.ke'};
  static final _slugPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
  static final _idPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  /// The target of [link], or null when it isn't a store link BROKA knows.
  static StoreLinkTarget? parse(String? link) {
    if (link == null || link.isEmpty) return null;
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'https' || !_hosts.contains(uri.host.toLowerCase())) {
      return null;
    }
    final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (parts.length < 2 || parts[0] != 'store') return null;
    final slug = parts[1].toLowerCase();
    if (!_slugPattern.hasMatch(slug)) return null;
    final via = uri.queryParameters['via'];
    if (parts.length == 2) return StoreLinkTarget(slug: slug, via: via);
    if (parts.length == 3 && parts[2] == 'about') {
      return StoreLinkTarget(slug: slug, via: via, details: true);
    }
    if (parts.length == 3 && parts[2] == 'cart') {
      return StoreLinkTarget(slug: slug, via: via, cart: _cartItems(uri.queryParameters['items']));
    }
    if (parts.length == 4 && parts[2] == 'p' && _idPattern.hasMatch(parts[3])) {
      return StoreLinkTarget(slug: slug, listingId: parts[3], via: via);
    }
    return null;
  }

  /// "l1:2,l2" -> {l1: 2, l2: 1}. Anything malformed is left out rather
  /// than failing the whole link; quantities are 1-99.
  static Map<String, int> _cartItems(String? raw) {
    final items = <String, int>{};
    for (final part in (raw ?? '').split(',')) {
      if (items.length >= maxCartItems) break;
      final bits = part.trim().split(':');
      if (bits.isEmpty || !_idPattern.hasMatch(bits[0]) || bits.length > 2) continue;
      final qty = bits.length == 2 ? int.tryParse(bits[1]) : 1;
      if (qty == null || qty < 1) continue;
      items[bits[0]] = qty > 99 ? 99 : qty;
    }
    return items;
  }

  @override
  bool operator ==(Object other) =>
      other is StoreLinkTarget &&
      other.slug == slug &&
      other.listingId == listingId &&
      other.via == via &&
      other.details == details &&
      mapEquals(other.cart, cart);

  @override
  int get hashCode => Object.hash(slug, listingId, via, details, cart?.length);

  @override
  String toString() =>
      'StoreLinkTarget($slug, $listingId, $via${details ? ', details' : ''}'
      '${cart != null ? ', cart $cart' : ''})';
}

class DeepLinkService {
  DeepLinkService({
    MethodChannel? channel,
    StoresRepository? repository,
  })  : _channel = channel ?? const MethodChannel('com.broka.app/links'),
        _repository = repository;

  static final DeepLinkService instance = DeepLinkService();

  final MethodChannel _channel;
  final StoresRepository? _repository;
  StoresRepository get _repo => _repository ?? storesRepository;

  GlobalKey<NavigatorState>? _navigator;
  bool _ready = false;
  StoreLinkTarget? _pending;

  /// Starts listening, and picks up the link that launched the app, if
  /// any. Safe to call more than once.
  Future<void> init(GlobalKey<NavigatorState> navigator) async {
    _navigator = navigator;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLink') handle(call.arguments as String?);
    });
    try {
      handle(await _channel
          .invokeMethod<String>('getInitialLink')
          .timeout(const Duration(seconds: 3)));
    } on MissingPluginException {
      // Not Android: no links to receive.
    } on PlatformException {
      // Never let a link failure stop the app.
    } on TimeoutException {
      // The platform side never answered; carry on without the link.
    }
  }

  /// The splash screen has put the first screen up: open any held link.
  /// [openPending] false drops it instead - the app was opened for
  /// something more urgent (an incoming call).
  void appReady({bool openPending = true}) {
    _ready = true;
    final pending = _pending;
    _pending = null;
    if (pending != null && openPending) _open(pending);
  }

  /// Opens [link] now, or once the app is ready. Returns whether it was a
  /// store link.
  bool handle(String? link) {
    final target = StoreLinkTarget.parse(link);
    if (target == null) return false;
    if (_ready && _navigator?.currentState != null) {
      _open(target);
    } else {
      _pending = target;
    }
    return true;
  }

  @visibleForTesting
  StoreLinkTarget? get pending => _pending;

  void _open(StoreLinkTarget target) {
    final nav = _navigator?.currentState;
    if (nav == null) {
      _pending = target;
      return;
    }
    if (target.isProduct) {
      nav.pushNamed('/product', arguments: {'listingId': target.listingId});
      _countProductVisit(target);
    } else {
      // The store screen counts its own visit, with the link's tag, and
      // opens its details on top for an /about link.
      nav.pushNamed('/store-view', arguments: {
        'slug': target.slug,
        'via': target.via,
        if (target.details) 'view': 'details',
        if (target.cart != null) ...{'view': 'cart', 'items': target.cart},
      });
    }
  }

  /// Someone arriving at a product from a store link visited the store.
  Future<void> _countProductVisit(StoreLinkTarget target) async {
    final store = await _repo.getStoreBySlug(target.slug);
    store.fold(
      onSuccess: (s) => _repo.recordVisit(s.id, via: target.via ?? 'direct'),
      onFailure: (_, __) {},
    );
  }
}
