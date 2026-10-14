// Sharing a store's link.
//
// Every shared link is tagged with where it went (…/store/clanix?via=whatsapp)
// so the owner's stats can say where visitors came from, and every tap is
// counted (POST /stores/{id}/share).
//
// How each destination is reached, best first:
//   WhatsApp  - straight into WhatsApp (or WhatsApp Business), else wa.me.
//   Facebook  - straight into the Facebook app, else its web share page.
//   X         - its web share page (opens the app when installed).
//   Instagram - into Instagram's own share target (Direct), with the link
//               also on the clipboard for a bio or a story sticker.
//   TikTok    - TikTok takes no links through sharing, so the link is
//               copied and TikTok opened: paste it in the bio or a caption.
//   More      - the system share sheet (SMS, Telegram, email, ...).
// The native side is the "com.broka.app/share" channel in MainActivity.kt;
// where it's missing (not Android), links open in the browser instead.
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/models/store.dart';
import 'repositories/stores_repository.dart';

enum ShareDestination {
  whatsapp('whatsapp', 'WhatsApp'),
  tiktok('tiktok', 'TikTok'),
  instagram('instagram', 'Instagram'),
  facebook('facebook', 'Facebook'),
  x('x', 'X'),
  copy('copy', 'Copy link'),
  more('other', 'More');

  const ShareDestination(this.channel, this.label);

  /// The backend's name for it (visit source and share channel).
  final String channel;
  final String label;
}

/// What happened, so the screen can tell the person.
enum ShareOutcome {
  /// Handed to the app or the share sheet.
  shared,

  /// The link is on the clipboard (and the app opened, if it could be).
  copied,

  /// Nothing could be opened; the link is on the clipboard instead.
  failed,
}

class StoreShare {
  StoreShare({
    MethodChannel? channel,
    StoresRepository? repository,
    Future<bool> Function(Uri uri)? openUrl,
  })  : _channel = channel ?? const MethodChannel('com.broka.app/share'),
        _repo = repository ?? storesRepository,
        _openUrl = openUrl ??
            ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final MethodChannel _channel;
  final StoresRepository _repo;
  final Future<bool> Function(Uri uri) _openUrl;

  static const _whatsapp = 'com.whatsapp';
  static const _whatsappBusiness = 'com.whatsapp.w4b';
  static const _facebook = 'com.facebook.katana';
  static const _instagram = 'com.instagram.android';
  static const _tiktok = ['com.zhiliaoapp.musically', 'com.ss.android.ugc.trill'];

  /// The message that goes with a shared link.
  static String message(Store store, String link) =>
      'Shop ${store.name} on BROKA: $link';

  Future<ShareOutcome> share(Store store, ShareDestination to) async {
    final link = to == ShareDestination.copy ? store.url : store.shareUrl(to.channel);
    final text = message(store, link);
    _repo.recordShare(store.id, to.channel);

    switch (to) {
      case ShareDestination.whatsapp:
        if (await _send(text, _whatsapp) || await _send(text, _whatsappBusiness)) {
          return ShareOutcome.shared;
        }
        return _openOrCopy(
            Uri.https('wa.me', '/', {'text': text}), link);
      case ShareDestination.facebook:
        if (await _send(text, _facebook)) return ShareOutcome.shared;
        return _openOrCopy(
            Uri.https('www.facebook.com', '/sharer/sharer.php', {'u': link}), link);
      case ShareDestination.x:
        return _openOrCopy(
            Uri.https('twitter.com', '/intent/tweet',
                {'text': 'Shop ${store.name} on BROKA', 'url': link}),
            link);
      case ShareDestination.instagram:
        await _copy(link);
        await _send(text, _instagram);
        return ShareOutcome.copied;
      case ShareDestination.tiktok:
        await _copy(link);
        for (final pkg in _tiktok) {
          if (await _invoke('openApp', {'package': pkg}) == 'opened') break;
        }
        return ShareOutcome.copied;
      case ShareDestination.copy:
        await _copy(link);
        return ShareOutcome.copied;
      case ShareDestination.more:
        if (await _invoke('shareText', {
              'text': text,
              'subject': store.name,
              'title': 'Share ${store.name}',
            }) ==
            'shared') {
          return ShareOutcome.shared;
        }
        await _copy(link);
        return ShareOutcome.failed;
    }
  }

  /// One product's link through the system share sheet (WhatsApp, a
  /// status, SMS...), tagged and counted like the store's own link. Sellers
  /// post single products far more often than whole stores.
  Future<ShareOutcome> shareProduct(Store store,
      {required String listingId, required String name, required String price}) async {
    const to = ShareDestination.more;
    final link = store.productUrl(listingId, via: to.channel);
    _repo.recordShare(store.id, to.channel);
    if (await _invoke('shareText', {
          'text': '$name, $price at ${store.name}: $link',
          'subject': name,
          'title': 'Share $name',
        }) ==
        'shared') {
      return ShareOutcome.shared;
    }
    await _copy(link);
    return ShareOutcome.failed;
  }

  /// The QR code was opened (to screenshot or print): counted as a share.
  void countQrShown(Store store) => _repo.recordShare(store.id, 'qr');

  Future<bool> _send(String text, String package) async =>
      await _invoke('shareText', {'text': text, 'package': package}) == 'shared';

  Future<String?> _invoke(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<String>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<ShareOutcome> _openOrCopy(Uri uri, String link) async {
    try {
      if (await _openUrl(uri)) return ShareOutcome.shared;
    } catch (_) {}
    await _copy(link);
    return ShareOutcome.failed;
  }

  Future<void> _copy(String link) => Clipboard.setData(ClipboardData(text: link));
}
