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
// Since 2026-10-09 a Zeno section: the switch for Zeno's orb on every
// screen (zeno_launcher.dart), and Zeno's tour of BROKA, run again.
//
// New: "Sign out of all devices" (POST /auth/token/revoke-all). The
// startup-sound switch went with the splash's sound (2026-10-09).
//
// Since 2026-10-09 Notifications says whether they are actually on, and
// "Run in background" whether battery saving holds BROKA back - each fixed
// with a tap (services/delivery_access.dart), and read again on returning
// from the phone's settings.
//
// Since 2026-10-03: "Change password" (with an SMS-code reset for a
// forgotten one). Only English and Kiswahili can be chosen as Zeno's
// language. Dholuo, Kikuyu, Luganda and Sheng were listed as "Coming soon"
// chips that did nothing when tapped; they are gone until Zeno can deal in
// them (2026-10-09).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/utils/result.dart';
import '../features/account/data/repositories/account_repository.dart';
import '../features/auth/presentation/change_password_screen.dart';
import '../features/zeno_assistant/presentation/zeno_launcher.dart';
import '../features/zeno_assistant/zeno_session.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/delivery_access.dart';
import '../services/global_poller_service.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/menu_tiles.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.repository, this.animateBackground = true, this.access});

  final AccountRepository? repository;

  /// Defaults to DeliveryAccess.instance.
  final DeliveryAccess? access;

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

  AccountRepository get _repo => widget.repository ?? accountRepository;

  /// Null until /auth/me answers: the switch is disabled rather than showing
  /// a guess.
  bool? _locationVisible;
  bool _savingLocation = false;
  String _language = ApiService.currentUserLanguage;

  DeliveryAccess get _access => widget.access ?? DeliveryAccess.instance;

  /// Null until known, or where it can't be told.
  DeliveryState? _delivery;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _load();
    _checkDelivery();
    unawaited(ZenoLauncherPrefs.load());
    _lifecycle = AppLifecycleListener(onResume: _checkDelivery);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _checkDelivery() async {
    final state = await _access.check();
    if (mounted) setState(() => _delivery = state);
  }

  Future<void> _allowNotifications() async {
    await _access.allowNotifications();
    await _checkDelivery();
  }

  Future<void> _allowBackground() async {
    await _access.allowBackground();
    await _checkDelivery();
  }

  Future<void> _load() async {
    final me = await _repo.getMe();
    if (!mounted) return;
    if (me case Success(:final data)) {
      setState(() => _locationVisible = data.locationVisible);
    }
  }

  /// Whether BROKA can reach this phone while it is closed, in words. Calls
  /// that rang only with the app open (2026-10) came from an APK built
  /// without Firebase, and nothing on the phone could show that.
  String _notificationsSubtitle() {
    final poller = GlobalPollerService.instance;
    if (!poller.firebaseReady) {
      return 'Only while BROKA is open - this version was built without push notifications';
    }
    if (!poller.pushReady) {
      return 'Only while BROKA is open until push notifications connect';
    }
    return "Messages, offers and calls, even with BROKA closed - managed in your phone's settings";
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
        const MenuSectionLabel('Zeno'),
        MenuGroup(children: [
          MenuTile(
            icon: Icons.blur_circular_rounded,
            tint: BrokaColors.neonPurple,
            title: "Zeno's orb on every screen",
            subtitle: 'Tap it on any screen to talk to Zeno; hold it to type',
            trailing: ValueListenableBuilder<bool>(
              valueListenable: ZenoLauncherPrefs.enabled,
              builder: (_, on, __) => _switch(
                key: const Key('settings-zeno-orb-switch'),
                value: on,
                onChanged: ZenoLauncherPrefs.setEnabled,
              ),
            ),
          ),
          if (ZenoSession.maybeOf(context) != null)
            MenuTile(
              key: const Key('settings-zeno-tour'),
              icon: Icons.explore_rounded,
              tint: BrokaColors.neonCyan,
              title: 'Take the tour with Zeno',
              subtitle: 'A minute around BROKA, with Zeno showing you what it can do',
              onTap: () => ZenoSession.maybeOf(context)?.startTour(),
            ),
        ]),
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
          if (_delivery?.notificationsAllowed == false)
            MenuTile(
              key: const Key('settings-notifications-off'),
              icon: Icons.notifications_off_outlined,
              tint: BrokaColors.danger,
              title: 'Notifications',
              subtitle: "Off - buyers' messages, offers and calls won't reach you. Tap to turn them on",
              trailing: const MenuPill('OFF', color: BrokaColors.danger),
              onTap: _allowNotifications,
            )
          else
            MenuTile(
              icon: Icons.notifications_outlined,
              title: 'Notifications',
              subtitle: _notificationsSubtitle(),
              trailing: const Icon(Icons.open_in_new_rounded, color: BrokaColors.textMid, size: 18),
              onTap: () async {
                if (!await openAppSettings() && mounted) {
                  _snack("Couldn't open your phone's settings.");
                }
              },
            ),
          if (_delivery != null && defaultTargetPlatform == TargetPlatform.android)
            MenuTile(
              key: const Key('settings-background'),
              icon: Icons.bolt_rounded,
              tint: _delivery!.backgroundAllowed ? BrokaColors.neonGreen : BrokaColors.gold,
              title: 'Run in background',
              subtitle: _delivery!.backgroundAllowed
                  ? 'On - calls ring and messages arrive with BROKA closed'
                  : 'Battery saving may hold calls and messages back while BROKA is closed. Tap to allow',
              trailing: _delivery!.backgroundAllowed
                  ? const MenuPill('ON', color: BrokaColors.neonGreen)
                  : const MenuPill('OFF', color: BrokaColors.gold),
              onTap: _delivery!.backgroundAllowed ? null : _allowBackground,
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
          ]),
        ]),
      );
}
