// The store's link, its QR code and one-tap sharing - on the "your store is
// live" screen and at the top of My Store.
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../main.dart' show BrokaColors;
import '../../data/store_share.dart';
import '../../domain/models/store.dart';

class StoreShareCard extends StatelessWidget {
  const StoreShareCard({super.key, required this.store, this.share});

  final Store store;

  /// For tests; defaults to the real share bridge.
  final StoreShare? share;

  static const _destinations = [
    (ShareDestination.whatsapp, Icons.chat_rounded, [Color(0xFF25D366), Color(0xFF128C7E)]),
    (ShareDestination.tiktok, Icons.tiktok, [Color(0xFF25F4EE), Color(0xFFFE2C55)]),
    (ShareDestination.instagram, Icons.camera_alt_outlined,
        [Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF)]),
    (ShareDestination.facebook, Icons.facebook, [Color(0xFF1877F2), Color(0xFF0A5AC2)]),
    (ShareDestination.x, null, [Color(0xFF3A3A3A), Color(0xFF0F0F0F)]),
    (ShareDestination.more, Icons.ios_share_rounded, [Color(0xFF8B5CF6), Color(0xFF3B82F6)]),
  ];

  Future<void> _share(BuildContext context, ShareDestination to) async {
    final outcome = await (share ?? StoreShare()).share(store, to);
    if (!context.mounted) return;
    final message = switch ((to, outcome)) {
      (ShareDestination.tiktok, _) =>
        'Link copied. Paste it in your TikTok bio or in a video caption.',
      (ShareDestination.instagram, _) =>
        'Link copied. Paste it in your Instagram bio or add a link sticker to a story.',
      (ShareDestination.copy, _) => 'Store link copied',
      (_, ShareOutcome.failed) => "Couldn't open that app, so the link was copied instead.",
      _ => null,
    };
    if (message != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _showQr(BuildContext context) {
    (share ?? StoreShare()).countQrShown(store);
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: BrokaColors.bgMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(store.name, textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Scan to visit the store', style: TextStyle(color: BrokaColors.textMid)),
            const SizedBox(height: 16),
            StoreQrCode(store: store, size: 240),
            const SizedBox(height: 14),
            Text(store.displayUrl, textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
            const SizedBox(height: 14),
            const Text('Screenshot it for your posts, or print it for your shop counter.',
                textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
            const SizedBox(height: 8),
            TextButton(onPressed: () => Navigator.pop(context),
                child: const Text('Done', style: TextStyle(color: BrokaColors.gold))),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.65),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.35)),
        boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.12),
            blurRadius: 24, spreadRadius: -6)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('YOUR STORE LINK', style: TextStyle(color: BrokaColors.textMid,
            fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Text(store.displayUrl,
                key: const Key('store-link-text'),
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
          IconButton(
            tooltip: 'Copy link',
            icon: const Icon(Icons.copy_rounded, color: BrokaColors.gold, size: 20),
            onPressed: () => _share(context, ShareDestination.copy),
          ),
          IconButton(
            tooltip: 'QR code',
            icon: const Icon(Icons.qr_code_2_rounded, color: BrokaColors.gold, size: 22),
            onPressed: () => _showQr(context),
          ),
        ]),
        const SizedBox(height: 12),
        // One row of six where it fits; two rows of three on narrow phones.
        LayoutBuilder(builder: (context, constraints) {
          const spacing = 8.0;
          final perRow = constraints.maxWidth >= 6 * 50 + 5 * spacing ? 6 : 3;
          final width = (constraints.maxWidth - (perRow - 1) * spacing) / perRow;
          return Wrap(spacing: spacing, runSpacing: 12, children: [
            for (final (to, icon, colors) in _destinations)
              SizedBox(
                width: width,
                child: _ShareButton(
                  label: to.label,
                  icon: icon,
                  colors: colors,
                  onTap: () => _share(context, to),
                ),
              ),
          ]);
        }),
      ]),
    );
  }
}

class _ShareButton extends StatelessWidget {
  const _ShareButton({required this.label, required this.icon, required this.colors,
      required this.onTap});
  final String label;
  final IconData? icon;
  final List<Color> colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Share on $label',
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          child: Column(children: [
            Container(
              width: 44, height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: colors,
                    begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: icon != null
                  ? Icon(icon, color: Colors.white, size: 22)
                  : const Text('X', style: TextStyle(color: Colors.white,
                      fontSize: 18, fontWeight: FontWeight.w900)),
            ),
            const SizedBox(height: 6),
            Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5)),
          ]),
        ),
      ),
    );
  }
}

/// The store link as a QR code, tagged ?via=qr so scans are counted as
/// such. Dark modules on white: every phone camera reads that reliably.
class StoreQrCode extends StatelessWidget {
  const StoreQrCode({super.key, required this.store, this.size = 200});
  final Store store;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: QrImageView(
          data: store.shareUrl('qr'),
          size: size,
          padding: EdgeInsets.zero,
          backgroundColor: Colors.white,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF1B1238)),
          dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square, color: Color(0xFF1B1238)),
          semanticsLabel: 'QR code for ${store.name}',
        ),
      );
}
