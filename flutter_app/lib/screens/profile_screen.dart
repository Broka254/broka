// BROKA - Profile Screen
//
// Who you are on BROKA: photo (tap the camera to retake the selfie), name,
// verification, the numbers other people see, and the account's details.
//
// It used to be the whole fifth tab - seller dashboard, store, language,
// location privacy, help and sign-out stacked under the profile. Those moved
// to the Menu (menu_screen.dart) and Settings (settings_screen.dart); this is
// the Menu's first entry now. Also fixed on the way:
//  * "Listings" and "Traded" read listing_count and volume_traded from
//    /auth/me, which has never sent either, so both always said 0. Listings
//    is the real active count now; Traded is gone until something computes
//    it.
//  * The photo went through Image.memory(base64Decode(...)), which throws on
//    a BROKA image URL - a valid profile photo - and took the screen down.
//  * A rating of 5.0 showed for accounts with no finished deals: that is the
//    column's default, not a score anyone gave. It reads "New" until a deal
//    is rated.
import 'package:flutter/material.dart';

import '../core/utils/result.dart';
import '../features/account/data/repositories/account_repository.dart';
import '../features/account/domain/models/my_account.dart';
import '../features/safe_payment/payments_shown.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../widgets/broka_image.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/menu_tiles.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.repository, this.animateBackground = true});

  final AccountRepository? repository;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const _gradient = [BrokaColors.neonPurple, BrokaColors.neonPink];

  AccountRepository get _repo => widget.repository ?? accountRepository;

  MyAccount? _account;
  String? _error;
  bool _loading = true;
  int? _listingCount;
  bool _savingPhoto = false;

  @override
  void initState() {
    super.initState();
    _load();
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

  Future<void> _updateSelfie() async {
    final result = await Navigator.pushNamed(context, '/selfie');
    if (result is! String || result.isEmpty || !mounted) return;
    setState(() => _savingPhoto = true);
    try {
      await ApiService.updateProfile(profilePhoto: result);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't save your new photo. Try again."),
          backgroundColor: BrokaColors.bgCard,
        ));
      }
    } finally {
      if (mounted) setState(() => _savingPhoto = false);
    }
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
            color: BrokaColors.gold,
            backgroundColor: BrokaColors.bgCard,
            displacement: 72,
            onRefresh: _load,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: CollapsingScreenHeader(
                    title: 'Profile',
                    emoji: '👤',
                    gradient: _gradient,
                    onBack: () => Navigator.maybePop(context),
                    narrow: media.size.width < 360,
                    textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                  ),
                ),
                ..._body(media),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(MediaQueryData media) {
    final account = _account;
    if (account == null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: _loading
                ? const CircularProgressIndicator(color: BrokaColors.gold)
                : BrokaEmptyState(
                    emoji: '📡',
                    gradient: _gradient,
                    headline: "Couldn't load your profile",
                    body: _error ?? 'Check your connection and try again.',
                    action: OutlinedButton(onPressed: _load, child: const Text('Retry')),
                  ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + media.padding.bottom),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            _header(account),
            const SizedBox(height: 20),
            _stats(account),
            // Not sold while payments are hidden (payments_shown.dart), and
            // the server refuses it too (VERIFIED_BADGE_ENABLED).
            if (paymentsShown && !account.isVerified) ...[
              const SizedBox(height: 12),
              MenuGroup(children: [
                MenuTile(
                  icon: Icons.verified_outlined,
                  tint: BrokaColors.success,
                  title: 'Get verified',
                  subtitle: 'A verified badge makes buyers and sellers more willing to deal',
                  onTap: () => Navigator.pushNamed(context, '/verify').then((_) {
                    if (mounted) _load();
                  }),
                ),
              ]),
            ],
            const MenuSectionLabel('Account details'),
            MenuGroup(children: [
              _detail(Icons.person_outline_rounded, 'Name', account.name.isEmpty ? '—' : account.name),
              if ((account.nickname ?? '').isNotEmpty)
                _detail(Icons.badge_outlined, 'Preferred name', account.nickname!),
              if ((account.phone ?? '').isNotEmpty)
                _detail(Icons.phone_iphone_rounded, 'Phone', account.phone!),
              if ((account.email ?? '').isNotEmpty)
                _detail(Icons.email_outlined, 'Email', account.email!,
                    badge: account.emailVerified
                        ? const MenuPill('Verified', color: BrokaColors.success)
                        : null),
              _detail(Icons.storefront_outlined, 'Account',
                  account.isSeller ? 'Buyer & seller' : 'Buyer'),
              if (account.memberSince != null)
                _detail(Icons.calendar_month_outlined, 'Member since', account.memberSince!),
            ]),
          ]),
        ),
      ),
    ];
  }

  Widget _header(MyAccount account) {
    final photo = account.photo;
    final initials = Center(
      child: Text(account.initials,
          style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800)),
    );
    return Column(children: [
      Stack(alignment: Alignment.bottomRight, children: [
        Container(
          width: 108,
          height: 108,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
            boxShadow: const [BrokaColors.glowGold],
            border: Border.all(color: BrokaColors.gold.withOpacity(0.55), width: 2),
          ),
          child: ClipOval(
            child: _savingPhoto
                ? const Center(
                    child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)))
                : photo != null && photo.isNotEmpty
                    ? BrokaImage(photo, fit: BoxFit.cover, placeholder: initials)
                    : initials,
          ),
        ),
        Tooltip(
          message: 'Retake your photo',
          child: GestureDetector(
            onTap: _savingPhoto ? null : _updateSelfie,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
                border: Border.all(color: BrokaColors.bg, width: 2),
                boxShadow: const [BrokaColors.glowGold],
              ),
              child: const Icon(Icons.camera_front_rounded, color: Colors.white, size: 16),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      Text(account.displayName,
          textAlign: TextAlign.center,
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 21, fontWeight: FontWeight.w800)),
      if ((account.nickname ?? '').isNotEmpty && account.name.isNotEmpty) ...[
        const SizedBox(height: 2),
        Text(account.name, style: const TextStyle(color: BrokaColors.textMid, fontSize: 13.5)),
      ],
      const SizedBox(height: 10),
      account.isVerified
          ? const MenuPill('Verified', color: BrokaColors.success, icon: Icons.verified_rounded)
          : const MenuPill('Unverified', color: BrokaColors.textMid),
    ]);
  }

  Widget _stats(MyAccount account) => Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(children: [
          _stat(_listingCount == null ? '—' : '$_listingCount', 'Active listings'),
          Container(width: 1, height: 32, color: BrokaColors.border),
          _stat('${account.completedDeals}', 'Deals'),
          Container(width: 1, height: 32, color: BrokaColors.border),
          _stat(account.ratingLabel, 'Rating'),
        ]),
      );

  Widget _stat(String value, String label) => Expanded(
        child: Column(children: [
          Text(value,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        ]),
      );

  Widget _detail(IconData icon, String label, String value, {Widget? badge}) => MenuTile(
        icon: icon,
        title: value,
        subtitle: label,
        trailing: badge,
      );
}
