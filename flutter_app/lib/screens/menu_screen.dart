// The Menu - the bottom nav's fifth tab, which used to be "Profile".
//
// Profile had turned into everything that wasn't a marketplace screen: the
// seller dashboard, the store, language, location privacy, help, sign-out,
// with the profile itself as the first of a dozen cards. The Menu is that hub
// on purpose, one section per thing a person comes here to do:
//
//   Profile       who you are on BROKA - opens the Profile screen
//   Dashboard     a seller's Seller Dashboard, as its own card right under
//                 the profile (2026-10-09): as one row among a dozen, sellers
//                 didn't find the screen that tells them what is selling
//   Selling       posting a listing (or becoming a seller)
//   Online store  the store summary and its actions (MenuStoreSection)
//   Account       Saved items, Settings, payment receipts, help
//   Sign out
//
// On the constellation, like Home and every screen reached from it.
import 'package:flutter/material.dart';

import '../core/utils/result.dart';
import '../features/account/data/repositories/account_repository.dart';
import '../features/account/domain/models/my_account.dart';
import '../features/safe_payment/escrow_callout.dart';
import '../features/safe_payment/safe_payment.dart' show safePaymentRepository;
import '../features/stores/presentation/widgets/menu_store_section.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/global_poller_service.dart';
import '../widgets/broka_image.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/menu_tiles.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key, this.repository, this.animateBackground = true});

  final AccountRepository? repository;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  static const _gradient = [BrokaColors.neonPurple, BrokaColors.neonBlue];

  AccountRepository get _repo => widget.repository ?? accountRepository;

  MyAccount? _account;
  String? _error;
  bool _loading = true;
  int? _listingCount;

  /// Bumped to remount the store section, which loads itself.
  int _storeNonce = 0;

  /// Whether BROKA takes deal payments itself (GET /pricing/safe-payment).
  /// "Payment receipts" lists M-Pesa receipts of BROKA's own escrow, which
  /// nobody can make while payments are paused - so it shows only while
  /// they're on, and not while it's unknown.
  bool _inAppPayments = false;

  @override
  void initState() {
    super.initState();
    _load();
    safePaymentRepository.fetch().then((info) {
      if (mounted && info != null && info.inAppPayments) setState(() => _inAppPayments = true);
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = _account == null;
      _error = null;
    });
    final result = await _repo.getMe();
    if (!mounted) return;
    switch (result) {
      case Failure(:final message):
        setState(() {
          _error = message;
          _loading = false;
        });
      case Success(:final data):
        setState(() {
          _account = data;
          _loading = false;
        });
        final count = await _repo.activeListingCount(data.id);
        if (!mounted) return;
        if (count case Success(:final data)) setState(() => _listingCount = data);
    }
  }

  Future<void> _refresh() async {
    setState(() => _storeNonce++);
    await _load();
  }

  Future<void> _open(String route) async {
    await Navigator.pushNamed(context, route);
    if (mounted) _load();
  }

  void _confirmSignOut() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sign out?',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        content: const Text('You will need to sign in again to buy, sell or chat.',
            style: TextStyle(color: BrokaColors.textMid)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final navigator = Navigator.of(context);
              GlobalPollerService.instance.stop();
              await ApiService.signOut();
              navigator.pushNamedAndRemoveUntil('/auth', (_) => false);
            },
            child: const Text('Sign out',
                style: TextStyle(color: BrokaColors.danger, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _refresh,
            color: BrokaColors.gold,
            backgroundColor: BrokaColors.bgCard,
            displacement: 72,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: CollapsingScreenHeader(
                    title: 'Menu',
                    emoji: '🧭',
                    gradient: _gradient,
                    onBack: () => Navigator.maybePop(context),
                    narrow: media.size.width < 360,
                    textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + media.padding.bottom),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate(_sections()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _sections() {
    final account = _account;
    final isSeller = account?.isSeller ?? ApiService.currentUserAccountType == 'buyer_seller';
    return [
      _profileCard(),
      if (isSeller) ...[
        const SizedBox(height: 14),
        _dashboardCard(),
      ],
      // Above everything else on the Menu: BROKA holds no payments, so how
      // to pay a stranger safely is the most useful thing on it.
      const EscrowCallout(margin: EdgeInsets.only(top: 14)),
      const MenuSectionLabel('Selling'),
      MenuGroup(children: [
        if (isSeller) ...[
          MenuTile(
            icon: Icons.add_circle_outline_rounded,
            tint: BrokaColors.neonGreen,
            title: 'Sell something',
            subtitle: 'Post a new listing',
            onTap: () => _open('/sell'),
          ),
        ] else
          MenuTile(
            icon: Icons.sell_outlined,
            title: 'Start selling',
            subtitle: 'A few items or a whole business - set up in a minute',
            onTap: () => _open('/start-selling'),
          ),
      ]),
      const MenuSectionLabel('Online store'),
      MenuStoreSection(
        key: ValueKey('store-$_storeNonce'),
        businessReady: account?.canOpenStore,
      ),
      const MenuSectionLabel('Account'),
      MenuGroup(children: [
        MenuTile(
          key: const Key('menu-saved'),
          icon: Icons.favorite_rounded,
          tint: BrokaColors.danger,
          title: 'Saved items',
          subtitle: "Listings you've hearted, to come back to",
          onTap: () => _open('/saved'),
        ),
        MenuTile(
          icon: Icons.workspace_premium_rounded,
          tint: BrokaColors.gold,
          title: 'BROKA Premium',
          subtitle: 'Voice mode, the Buying Agent, AI covers and your plan',
          onTap: () => _open('/premium'),
        ),
        MenuTile(
          icon: Icons.settings_rounded,
          tint: BrokaColors.neonBlue,
          title: 'Settings',
          subtitle: 'Language, privacy, notifications and sign-in',
          onTap: () => _open('/settings'),
        ),
        MenuTile(
          icon: Icons.call_rounded,
          tint: BrokaColors.neonGreen,
          title: 'Calls',
          subtitle: 'Voice and video calls with buyers and sellers',
          onTap: () => _open('/call-history'),
        ),
        if (_inAppPayments)
          MenuTile(
            icon: Icons.receipt_long_rounded,
            tint: BrokaColors.neonBlue,
            title: 'Payment receipts',
            subtitle: 'M-Pesa receipts saved on this phone',
            onTap: () => _open('/deal-history'),
          ),
        MenuTile(
          icon: Icons.shield_rounded,
          tint: BrokaColors.neonGreen,
          title: 'Escrow payments',
          subtitle: 'Escrow services in Kenya, and Zeno to guide you',
          onTap: () => _open('/escrow-services'),
        ),
        MenuTile(
          icon: Icons.help_outline_rounded,
          tint: BrokaColors.neonBlue,
          title: 'Help & how BROKA works',
          subtitle: 'Buying, selling, paying with escrow, and Zeno',
          onTap: () => _open('/how-broka-works'),
        ),
      ]),
      const SizedBox(height: 22),
      MenuGroup(children: [
        MenuTile(
          icon: Icons.logout_rounded,
          title: 'Sign out',
          destructive: true,
          onTap: _confirmSignOut,
        ),
      ]),
      const SizedBox(height: 24),
      const Center(
        child: Text('BROKA v2.3.0',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
      ),
    ];
  }

  // ── Profile card ───────────────────────────────────────────────────────────

  Widget _profileCard() {
    final account = _account;
    if (account == null) {
      if (_loading) {
        return Container(
          height: 150,
          decoration: _cardDecoration(),
          child: const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold),
            ),
          ),
        );
      }
      return MenuGroup(children: [
        MenuTile(
          icon: Icons.cloud_off_rounded,
          tint: BrokaColors.warning,
          title: "Couldn't load your profile",
          subtitle: _error,
          trailing: TextButton(onPressed: _load, child: const Text('Retry')),
        ),
      ]);
    }
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const Key('menu-profile-card'),
        borderRadius: BorderRadius.circular(18),
        onTap: () => _open('/profile'),
        child: Ink(
          decoration: _cardDecoration(),
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Row(children: [
              _Avatar(account: account, size: 62),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(account.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w800)),
                  if (account.contactLine != null) ...[
                    const SizedBox(height: 2),
                    Text(account.contactLine!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
                  ],
                  const SizedBox(height: 7),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    account.isVerified
                        ? const MenuPill('Verified', color: BrokaColors.success, icon: Icons.verified_rounded)
                        : const MenuPill('Unverified', color: BrokaColors.textMid),
                    MenuPill(account.isSeller ? 'Seller' : 'Buyer', color: BrokaColors.neonBlue),
                  ]),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid),
            ]),
            const SizedBox(height: 14),
            const Divider(height: 1, color: BrokaColors.border),
            const SizedBox(height: 12),
            Row(children: [
              _stat(_listingCount == null ? '—' : '$_listingCount', 'Listings'),
              _stat('${account.completedDeals}', 'Deals'),
              _stat(account.ratingLabel, 'Rating'),
            ]),
          ]),
        ),
      ),
    );
  }

  /// The way into the Seller Dashboard, as a card of its own under the
  /// profile - the brand gradient around it and a glow, so it reads as the
  /// seller's main destination on this screen rather than one more row.
  Widget _dashboardCard() {
    final count = _listingCount;
    return Container(
      padding: const EdgeInsets.all(1.4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [BrokaColors.gold, BrokaColors.neonPurple, BrokaColors.neonBlue],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.28), blurRadius: 22, spreadRadius: -2),
          BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.18), blurRadius: 30, offset: const Offset(0, 8)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('menu-seller-dashboard'),
          borderRadius: BorderRadius.circular(19),
          onTap: () => _open('/seller-dashboard'),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(19),
              gradient: LinearGradient(
                colors: [
                  Color.alphaBlend(BrokaColors.neonPurple.withOpacity(0.22), BrokaColors.bgCard),
                  Color.alphaBlend(BrokaColors.neonBlue.withOpacity(0.10), BrokaColors.bg),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  gradient: const LinearGradient(
                    colors: [BrokaColors.neonPurple, BrokaColors.neonBlue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.45), blurRadius: 14)],
                ),
                child: const Icon(Icons.insights_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(
                        colors: [BrokaColors.gold, BrokaColors.neonBlue]).createShader(b),
                    child: const Text('Seller Dashboard',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900,
                            letterSpacing: 0.3)),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    count == null
                        ? 'Sales, how each listing is doing, and Zeno\'s tips'
                        : '${count == 1 ? '1 active listing' : '$count active listings'} · sales, chance of selling, Zeno\'s tips',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.3),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: BrokaColors.neonBlue.withOpacity(0.16),
                  border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.5)),
                ),
                child: const Icon(Icons.arrow_forward_rounded, color: BrokaColors.neonBlue, size: 18),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  BoxDecoration _cardDecoration() => BoxDecoration(
        gradient: LinearGradient(
          colors: [
            BrokaColors.bgCard.withOpacity(0.95),
            const Color(0xFF16163A).withOpacity(0.95),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.45)),
        boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.12), blurRadius: 18)],
      );

  Widget _stat(String value, String label) => Expanded(
        child: Column(children: [
          Text(value,
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        ]),
      );
}

/// The account's photo, or its initials on the brand gradient.
///
/// BrokaImage rather than Image.memory(base64Decode(...)): a profile photo can
/// be a BROKA image URL as well as legacy base64 (check_legacy_images accepts
/// both), and base64Decode on a URL threw inside build - a red screen where
/// the profile should be.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.account, required this.size});
  final MyAccount account;
  final double size;

  @override
  Widget build(BuildContext context) {
    final photo = account.photo;
    final initials = Center(
      child: Text(account.initials,
          style: TextStyle(color: Colors.white, fontSize: size * 0.34, fontWeight: FontWeight.w800)),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.5), width: 2),
        boxShadow: const [BrokaColors.glowGold],
      ),
      child: ClipOval(
        child: photo != null && photo.isNotEmpty
            ? BrokaImage(photo, fit: BoxFit.cover, placeholder: initials)
            : initials,
      ),
    );
  }
}
