// "Your store is live" - the end of store setup: the link, its QR code,
// one-tap sharing, and the next thing to do (add products).
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;
import '../../../screens/sell_photos_screen.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/gradient_button.dart';
import '../../../widgets/wizard_scaffold.dart';
import '../data/store_share.dart';
import '../domain/models/store.dart';
import 'widgets/store_share_card.dart';

class StoreLaunchedScreen extends StatelessWidget {
  const StoreLaunchedScreen({
    super.key,
    required this.store,
    this.share,
    this.animateBackground = true,
  });

  final Store store;
  final StoreShare? share;
  final bool animateBackground;

  /// Back to the My Store screen setup was started from, when there is
  /// one, rather than stacking a second copy of it.
  static void _goToMyStore(BuildContext context) {
    final navigator = Navigator.of(context);
    var found = false;
    navigator.popUntil((route) {
      found = route.settings.name == '/store-manage';
      return found || route.isFirst;
    });
    if (!found) navigator.pushNamed('/store-manage');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: animateBackground,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid),
                  onPressed: () => _goToMyStore(context),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 84, height: 84,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: kWizardCtaGradient),
                    boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.45),
                        blurRadius: 32, spreadRadius: 2)],
                  ),
                  child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 42),
                ),
              ),
              const SizedBox(height: 20),
              Text('${store.name} is open!', textAlign: TextAlign.center,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 26,
                      fontWeight: FontWeight.w800, letterSpacing: -0.4)),
              const SizedBox(height: 8),
              const Text(
                'Share your link everywhere your customers are. Every product you '
                'add to the store shows up there - and on BROKA\'s home screen too.',
                textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textMid, fontSize: 14, height: 1.45),
              ),
              const SizedBox(height: 24),
              StoreShareCard(store: store, share: share),
              const SizedBox(height: 18),
              Center(child: StoreQrCode(store: store, size: 150)),
              const SizedBox(height: 8),
              const Text('Print this QR code for your shop counter',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
              const SizedBox(height: 26),
              GradientButton(
                height: 56,
                borderRadius: 16,
                colors: kWizardCtaGradient,
                onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                    builder: (_) => SellPhotosScreen(presetStoreId: store.id))),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add_box_outlined, color: Colors.white),
                  SizedBox(width: 10),
                  Flexible(
                    child: Text('Add your first product',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white,
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _goToMyStore(context),
                child: const Text('Go to My Store', style: TextStyle(color: BrokaColors.gold,
                    fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
