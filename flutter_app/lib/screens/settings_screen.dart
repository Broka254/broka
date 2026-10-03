// Settings - reached from the Menu.
//
// What used to be Profile's "Preferences" and "Support" cards, keeping only
// settings that do something:
//
//  * "Push notifications" was a switch that changed a local bool and nothing
//    else - no call, not even saved; it was back on the next time Profile
//    opened. Android decides what an app may notify about, so the row now
//    opens the phone's own notification settings for BROKA.
//  * "Dark mode" was a disabled switch captioned "coming soon". Removed until
//    there is a light theme to switch to.
//  * "Show my location" always opened switched ON, whatever the account's
//    real setting was: it was initialised to true and never read back from
//    /auth/me. Someone who had hidden their location saw it apparently
//    public again. It now starts from the server's value, and a change that
//    fails is undone on screen and said so.
//  * "Help & FAQ", "Privacy policy" and "Rate BROKA" were snackbars saying
//    "coming soon". Help is in the Menu (How BROKA works); the other two have
//    nothing behind them yet and are left out rather than promised.
//
// New: the splash's startup sound, which could only be changed on the splash
// itself, and "Sign out of all devices" (POST /auth/token/revoke-all).
//
// Since 2026-10-03: "Change password" (with an SMS-code reset for a
// forgotten one). Only English and Kiswahili can be chosen as Zeno's
// language for now; Dholuo, Kikuyu, Luganda and Sheng are shown as coming
// soon and can't be selected.
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/utils/result.dart';
import '../features/account/data/repositories/account_repository.dart';
import '../features/auth/presentation/change_password_screen.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/global_poller_service.dart';
import '../services/sound_preference_service.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/menu_tiles.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.repository, this.animateBackground = true});

  final AccountRepository? repository;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _gradient = [BrokaColors.neonBlue, BrokaColors.neonCyan];

  static const _languages = [
    ('english', 'English', '🇬🇧'),
    ('swahili', 'Kiswahili', '🇰🇪'),
  ];

  /// Shown, not offered: not ready for Zeno to deal in yet.
  static const _comingSoon = [
    ('luo', 'Dholuo', '🟡'),
    ('kikuyu', 'Kikuyu', '🟤'),
    ('luganda', 'Luganda', '🇺🇬'),
    ('sheng', 'Sheng', '🔥'),
  ];

  AccountRepository get _repo => widget.repository ?? accountRepository;

  /// Null until /auth/me answers: the switch is disabled rather than showing
  /// a guess.
  bool? _locationVisible;
  bool _savingLocation = false;
  bool _sound = SoundPreferenceService.cached;
  String _language = ApiService.currentUserLanguage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sound = await SoundPreferenceService.load();
    if (mounted) setState(() => _sound = sound);
    final me = await _repo.getMe();
    if (!mounted) return;
    if (me case Success(:final data)) {
      setState(() => _locationVisible = data.locationVisible);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: BrokaColors.bgCard,
    ));
  }

  Future<void> _setLocationVisible(bool visible) async {
    final previous = _locationVisible;
    setState(() {
      _locationVisible = visible;
      _savingLocation = true;
    });
    final result = await _repo.setLocationVisible(visible);
    if (!mounted) return;
    setState(() => _savingLocation = false);
    if (result case Failure()) {
      setState(() => _locationVisible = previous);
      _snack("Couldn't change your location setting. Check your connection and try again.");
    }
  }

  Future<void> _setLanguage(String key) async {
    setState(() => _language = key);
    await ApiService.setLanguage(key);
  }

  Future<void> _setSound(bool on) async {
    setState(() => _sound = on);
    await SoundPreferenceService.setEnabled(on);
  }

  Future<void> _changePassword() async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ChangePasswordScreen(animateBackground: widget.animateBackground),
    ));
    if (changed == true && mounted) {
      _snack('Password changed. Any other phone signed in to your account has been signed out.');
    }
  }

  void _confirmSignOutEverywhere() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sign out of all devices?',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        content: const Text(
            'Every phone signed in to this account - including this one - will need to sign in again. '
            'Use this if you lost a phone or think someone else has access.',
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
              try {
                await ApiService.signOutEverywhere();
              } catch (_) {
                if (mounted) {
                  _snack("Couldn't reach BROKA, so nothing was signed out. Try again when you're online.");
                }
                return;
              }
              GlobalPollerService.instance.stop();
              navigator.pushNamedAndRemoveUntil('/auth', (_) => false);
            },
            child: const Text('Sign out everywhere',
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
          child: CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: CollapsingScreenHeader(
                  title: 'Settings',
                  emoji: '⚙️',
                  gradient: _gradient,
                  onBack: () => Navigator.maybePop(context),
                  narrow: media.size.width < 360,
                  textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + media.padding.bottom),
                sliver: SliverList(delegate: SliverChildListDelegate(_sections())),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sections() => [
        const MenuSectionLabel('Language'),
        _languageCard(),
        const MenuSectionLabel('Privacy'),
        MenuGroup(children: [
          MenuTile(
            icon: Icons.location_on_outlined,
            title: 'Show my location',
            subtitle: 'Let buyers and sellers see your approximate area and distance',
            trailing: _switch(
              key: const Key('settings-location-switch'),
              value: _locationVisible ?? false,
              onChanged: _locationVisible == null || _savingLocation ? null : _setLocationVisible,
            ),
          ),
        ]),
        const MenuSectionLabel('Notifications & sound'),
        MenuGroup(children: [
          MenuTile(
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            subtitle: "Messages, offers and calls - managed in your phone's settings",
            trailing: const Icon(Icons.open_in_new_rounded, color: BrokaColors.textMid, size: 18),
            onTap: () async {
              if (!await openAppSettings() && mounted) {
                _snack("Couldn't open your phone's settings.");
              }
            },
          ),
          MenuTile(
            icon: Icons.volume_up_outlined,
            title: 'Startup sound',
            subtitle: 'Play the BROKA sound when the app opens',
            trailing: _switch(
              key: const Key('settings-sound-switch'),
              value: _sound,
              onChanged: _setSound,
            ),
          ),
        ]),
        const MenuSectionLabel('Security'),
        MenuGroup(children: [
          MenuTile(
            key: const Key('settings-change-password'),
            icon: Icons.password_rounded,
            tint: BrokaColors.neonBlue,
            title: 'Change password',
            subtitle: 'Or reset a forgotten one with an SMS code to your number',
            onTap: _changePassword,
          ),
          MenuTile(
            icon: Icons.devices_other_rounded,
            title: 'Sign out of all devices',
            subtitle: 'Ends every session on this account, including this phone',
            destructive: true,
            onTap: _confirmSignOutEverywhere,
          ),
        ]),
        const SizedBox(height: 24),
        const Center(
          child: Text('BROKA v2.3.0',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        ),
      ];

  Widget _switch({Key? key, required bool value, required ValueChanged<bool>? onChanged}) => Switch(
        key: key,
        value: value,
        onChanged: onChanged,
        activeColor: BrokaColors.gold,
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? BrokaColors.gold.withOpacity(0.3) : BrokaColors.border),
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? BrokaColors.gold : BrokaColors.textMid),
      );

  Widget _languageCard() => Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text("The language Zeno writes and speaks to you in",
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (key, name, flag) in _languages)
              ChoiceChip(
                selected: _language == key,
                onSelected: (_) => _setLanguage(key),
                showCheckmark: false,
                avatar: Text(flag, style: const TextStyle(fontSize: 14)),
                label: Text(name),
                labelStyle: TextStyle(
                  fontSize: 13,
                  fontWeight: _language == key ? FontWeight.w700 : FontWeight.w500,
                  color: _language == key ? Colors.white : BrokaColors.textMid,
                ),
                backgroundColor: BrokaColors.bgMid,
                selectedColor: BrokaColors.gold.withOpacity(0.25),
                side: BorderSide(
                  color: _language == key ? BrokaColors.gold : BrokaColors.border,
                  width: _language == key ? 1.5 : 1,
                ),
                shape: const StadiumBorder(),
              ),
            for (final (key, name, flag) in _comingSoon)
              Opacity(
                key: Key('settings-language-soon-$key'),
                opacity: 0.55,
                child: Chip(
                  avatar: Text(flag, style: const TextStyle(fontSize: 14)),
                  label: Text.rich(TextSpan(children: [
                    TextSpan(text: name),
                    const TextSpan(
                      text: '  Coming soon',
                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700,
                          color: BrokaColors.gold),
                    ),
                  ])),
                  labelStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500, color: BrokaColors.textMid),
                  backgroundColor: BrokaColors.bgMid,
                  side: const BorderSide(color: BrokaColors.border),
                  shape: const StadiumBorder(),
                ),
              ),
          ]),
        ]),
      );
}
