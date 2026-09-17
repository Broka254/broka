import 'dart:async';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/global_poller_service.dart';
import '../services/notification_service.dart';
import '../services/sell_draft_store.dart';
import '../services/sound_preference_service.dart';
import '../widgets/splash_painters.dart';
import 'home_screen.dart';
import 'sell_photos_screen.dart';

/// BROKA splash screen — the Zeno "AI boot sequence".
///
/// Visual layers (back to front): a deep navy backdrop, a sparse
/// neural-network mesh, three concentric orbital rings around the
/// BROKA/Zeno logo core, a flowing digital wave along the bottom, and the
/// boot-status text stack. See the splash spec for the full breakdown -
/// layout fractions below are calibrated directly against the reference
/// artwork.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  // Layout calibration (fractions of screen height/width) - see splash spec.
  static const double _kLogoCenterY = 0.426;
  static const double _kTextTopY = 0.548;
  static const double _kWaveHeightFrac = 0.24;

  // Master boot timeline - phase fractions below all read from this.
  late final AnimationController _boot;

  // Continuous/looping drivers.
  late final AnimationController _ringInner;
  late final AnimationController _ringMiddle;
  late final AnimationController _ringOuter;
  late final AnimationController _comet;
  late final AnimationController _breathe;
  late final AnimationController _waveDrift;
  late final AnimationController _dotsSweepCtrl;
  late final AnimationController _networkTimeCtrl;
  late final Animation<double> _breatheScale;

  final AudioPlayer _bootPlayer = AudioPlayer(playerId: 'broka_splash_boot');
  bool _soundOn = true;

  int _bootMsgIndex = 0;
  static const _bootMessages = [
    'Connecting Trust Network...',
    'Initializing Commerce Intelligence...',
    'Negotiation Engine Online...',
    'Securing Transaction Layer...',
    'Marketplace Intelligence Ready...',
    'Zeno Ready.',
  ];
  static const _bootMsgOffsetsMs = [0, 1445, 2890, 4335, 5780, 7225];

  final List<Timer> _msgTimers = [];
  Timer? _navTimer;

  @override
  void initState() {
    super.initState();

    _boot = AnimationController(vsync: this, duration: const Duration(milliseconds: 8500))..forward();

    _ringInner = AnimationController(vsync: this, duration: const Duration(seconds: 9))..repeat();
    _ringMiddle = AnimationController(vsync: this, duration: const Duration(seconds: 22))..repeat();
    _ringOuter = AnimationController(vsync: this, duration: const Duration(seconds: 14))..repeat();
    _comet = AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();
    _breathe = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..repeat(reverse: true);
    _waveDrift = AnimationController(vsync: this, duration: const Duration(seconds: 11))..repeat();
    _dotsSweepCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
    _networkTimeCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 20))..repeat();

    _breatheScale = Tween<double>(begin: 0.98, end: 1.02)
        .animate(CurvedAnimation(parent: _breathe, curve: Curves.easeInOut));

    _initSound();
    _scheduleBootMessages();

    _navTimer = Timer(const Duration(milliseconds: 10300), _decideNextScreen);
  }

  Future<void> _initSound() async {
    final enabled = await SoundPreferenceService.load();
    if (!mounted) return;
    setState(() => _soundOn = enabled);
    if (enabled) _playBootSound();
  }

  Future<void> _playBootSound() async {
    try {
      // A short, original synthesised chime (assets/audio/zeno_boot.wav) -
      // not a sampled/licensed sound, same approach as ringtone.mp3.
      await _bootPlayer.play(AssetSource('audio/zeno_boot.wav'));
    } catch (_) {
      // Missing/unsupported audio asset shouldn't block the boot animation.
    }
  }

  void _toggleSound() {
    final next = !_soundOn;
    setState(() => _soundOn = next);
    SoundPreferenceService.setEnabled(next);
    if (!next) {
      _bootPlayer.stop().catchError((_) {});
    }
  }

  void _scheduleBootMessages() {
    for (int i = 1; i < _bootMsgOffsetsMs.length; i++) {
      _msgTimers.add(Timer(Duration(milliseconds: _bootMsgOffsetsMs[i]), () {
        if (!mounted) return;
        setState(() => _bootMsgIndex = i);
      }));
    }
  }

  Future<void> _decideNextScreen() async {
    if (!mounted) return;
    // ApiService.loadSavedSession() already ran in main() before runApp,
    // so currentUserId is populated here if a session exists.
    final loggedIn = ApiService.currentUserId != null && ApiService.authToken != null;
    if (loggedIn) GlobalPollerService.instance.start();

    // App was launched cold by tapping an incoming-call push notification -
    // route straight there instead of the normal home/draft-recovery flow.
    // Only meaningful for a logged-in session (calls require
    // authentication); a stale/invalid value here for a logged-out user is
    // simply ignored, falling through to the normal flow below.
    final coldStartCall = pendingColdStartCallData;
    pendingColdStartCallData = null; // consume once, regardless of outcome
    if (loggedIn && coldStartCall != null) {
      await NotificationService.instance.navigateFromPayload(coldStartCall);
      return;
    }

    // A saved sell-listing draft almost always means the app's process was
    // killed mid-flow (most commonly: the camera launch for a listing
    // photo/video handed the foreground to the system camera app, and
    // Android reclaimed BROKA's memory while it was in the background).
    // From the user's side this looks exactly like the app crashing and
    // restarting - so send them back into the listing flow with their
    // progress intact rather than dropping them at home as if nothing
    // was in progress.
    //
    // Checked unconditionally, NOT gated behind `loggedIn` above: a sell
    // draft can only be created by a logged-in user, but re-evaluating
    // `loggedIn` here on every cold start and gating this check behind it
    // silently drops the recovery whenever that re-evaluation doesn't come
    // back true fast enough - which is exactly the "kicked back to Home"
    // bug this store exists to prevent, just reintroduced one layer up.
    // See CHANGES.md "Sell flow — photo capture kicking you back to Home"
    // and the v6.1 entry's "always proceeds to Home (or a saved sell draft)
    // regardless of login state" — this restores that literally.
    if (await SellDraftStore.hasDraft()) {
      Navigator.of(context).pushReplacement(_smoothRoute(const SellPhotosScreen()));
      return;
    }

    // v6.1 onboarding rework: browsing no longer requires an account.
    // Splash now always lands on Home — account-gated actions (Sell, talk
    // to Zeno, negotiations, Profile) prompt sign-up only when actually
    // attempted (see lib/utils/auth_gate.dart), not up front.
    Navigator.of(context).pushReplacement(_smoothRoute(const HomeScreen()));
  }

  /// A calm fade + very slight scale so the boot sequence hands off to the
  /// next screen with no black flash and no abrupt directional slide (see
  /// splash spec "Transition Into Login"). BROKA's actual navigation lands
  /// on Home (or a recovered sell draft) rather than a login screen - see
  /// the v6.1 onboarding note above - so this keeps the handoff itself
  /// premium and seamless without faking a shared-element trip into screens
  /// that haven't been through this redesign pass yet. Once the login
  /// screen gets its own pass, this is the natural place to add a Hero
  /// handoff for the logo itself.
  Route _smoothRoute(Widget page) {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 700),
      reverseTransitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
        final scale = Tween<double>(begin: 1.05, end: 1.0)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
        return FadeTransition(opacity: fade, child: ScaleTransition(scale: scale, child: child));
      },
    );
  }

  @override
  void dispose() {
    _boot.dispose();
    _ringInner.dispose();
    _ringMiddle.dispose();
    _ringOuter.dispose();
    _comet.dispose();
    _breathe.dispose();
    _waveDrift.dispose();
    _dotsSweepCtrl.dispose();
    _networkTimeCtrl.dispose();
    for (final t in _msgTimers) {
      t.cancel();
    }
    _navTimer?.cancel();
    _bootPlayer.dispose();
    super.dispose();
  }

  // ── Boot-phase reveal curves (see splash spec "Animation Sequence") ──────
  double get _logoReveal => const Interval(0.0, 0.17, curve: Curves.easeOut).transform(_boot.value);
  double get _textReveal => const Interval(0.08, 0.30, curve: Curves.easeOut).transform(_boot.value);
  double get _ringsReveal => const Interval(0.14, 0.42, curve: Curves.easeOut).transform(_boot.value);
  double get _networkReveal => const Interval(0.35, 0.68, curve: Curves.easeOut).transform(_boot.value);
  double get _waveReveal => const Interval(0.35, 0.65, curve: Curves.easeOut).transform(_boot.value);
  double get _finalPulse => const Interval(0.85, 1.0, curve: Curves.easeInOut).transform(_boot.value);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final coreSize = size.width * 0.94;

    return Scaffold(
      backgroundColor: const Color(0xFF03040B),
      body: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _SplashBackdrop(),

            // Neural network mesh.
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge([_boot, _networkTimeCtrl]),
                builder: (_, __) => CustomPaint(
                  size: size,
                  painter: NeuralNetworkPainter(
                    t: _networkTimeCtrl.value,
                    reveal: _networkReveal,
                    nodes: NeuralNetworkField.nodes,
                    edges: NeuralNetworkField.edges,
                  ),
                ),
              ),
            ),

            // Orbital rings + Zeno core logo.
            Positioned(
              left: (size.width - coreSize) / 2,
              top: size.height * _kLogoCenterY - coreSize / 2,
              width: coreSize,
              height: coreSize,
              child: RepaintBoundary(
                child: _OrbitalCore(
                  boot: _boot,
                  ringInner: _ringInner,
                  ringMiddle: _ringMiddle,
                  ringOuter: _ringOuter,
                  comet: _comet,
                  breatheScale: _breatheScale,
                  screenWidth: size.width,
                  ringsReveal: () => _ringsReveal,
                  logoReveal: () => _logoReveal,
                  finalPulse: () => _finalPulse,
                ),
              ),
            ),

            // Digital wave, bottom band.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: size.height * _kWaveHeightFrac,
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_boot, _waveDrift]),
                  builder: (_, __) => CustomPaint(
                    size: Size(size.width, size.height * _kWaveHeightFrac),
                    painter: DigitalWavePainter(
                      t: _waveDrift.value,
                      reveal: _waveReveal,
                      layers: kSplashWaveLayers,
                    ),
                  ),
                ),
              ),
            ),

            // Boot-status text stack.
            Positioned(
              left: 0,
              right: 0,
              top: size.height * _kTextTopY,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: size.width * 0.07),
                child: AnimatedBuilder(
                  animation: _boot,
                  builder: (_, __) {
                    final reveal = _textReveal;
                    return Opacity(
                      opacity: reveal,
                      child: Transform.translate(
                        offset: Offset(0, (1 - reveal) * 14),
                        child: _BootTextBlock(
                          message: _bootMessages[_bootMsgIndex],
                          dotsSweepCtrl: _dotsSweepCtrl,
                          reveal: reveal,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            // Sound toggle, bottom-left.
            Positioned(
              left: 22,
              bottom: bottomSafe + size.height * 0.048,
              child: AnimatedBuilder(
                animation: _boot,
                builder: (_, __) => Opacity(
                  opacity: _waveReveal,
                  child: _SoundToggle(on: _soundOn, onTap: _toggleSound),
                ),
              ),
            ),

            // Bottom branding.
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomSafe + size.height * 0.014,
              child: AnimatedBuilder(
                animation: _boot,
                builder: (_, __) => Opacity(
                  opacity: _waveReveal,
                  child: const _PoweredByFooter(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SplashBackdrop extends StatelessWidget {
  const _SplashBackdrop();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.15, -0.35),
          radius: 1.25,
          colors: [Color(0xFF050810), Color(0xFF03040A), Color(0xFF000004)],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
    );
  }
}

class _OrbitalCore extends StatelessWidget {
  final AnimationController boot;
  final AnimationController ringInner;
  final AnimationController ringMiddle;
  final AnimationController ringOuter;
  final AnimationController comet;
  final Animation<double> breatheScale;
  final double screenWidth;
  final double Function() ringsReveal;
  final double Function() logoReveal;
  final double Function() finalPulse;

  const _OrbitalCore({
    required this.boot,
    required this.ringInner,
    required this.ringMiddle,
    required this.ringOuter,
    required this.comet,
    required this.breatheScale,
    required this.screenWidth,
    required this.ringsReveal,
    required this.logoReveal,
    required this.finalPulse,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([boot, ringInner, ringMiddle, ringOuter, comet, breatheScale]),
      builder: (context, _) {
        final rReveal = ringsReveal();
        final lReveal = logoReveal();
        final pulseBoost = 1.0 + finalPulse() * 0.06;

        return Stack(alignment: Alignment.center, children: [
          // Outer ring - slow clockwise (spec §3).
          Transform.rotate(
            angle: ringOuter.value * 2 * pi,
            child: SizedBox(
              width: screenWidth * 0.385 * 2,
              height: screenWidth * 0.385 * 2,
              child: CustomPaint(
                painter: OrbitRingPainter(
                  dotCount: 8,
                  dotRadius: 2.6,
                  colors: const [BrokaColors.gold, BrokaColors.neonBlue],
                  strokeOpacity: 0.16,
                  reveal: rReveal,
                ),
              ),
            ),
          ),
          // Middle ring - slower, counter-clockwise, dashed (spec §3).
          Transform.rotate(
            angle: -ringMiddle.value * 2 * pi,
            child: SizedBox(
              width: screenWidth * 0.30 * 2,
              height: screenWidth * 0.30 * 2,
              child: CustomPaint(
                painter: OrbitRingPainter(
                  dotCount: 5,
                  dotRadius: 2.2,
                  colors: const [BrokaColors.gold, BrokaColors.neonBlue],
                  strokeOpacity: 0.20,
                  reveal: rReveal,
                  dashed: true,
                ),
              ),
            ),
          ),
          // Inner ring - slightly faster clockwise, carries the comet particle.
          Transform.rotate(
            angle: ringInner.value * 2 * pi,
            child: SizedBox(
              width: screenWidth * 0.225 * 2,
              height: screenWidth * 0.225 * 2,
              child: CustomPaint(
                painter: OrbitRingPainter(
                  dotCount: 6,
                  dotRadius: 2.4,
                  colors: const [BrokaColors.neonBlue, BrokaColors.neonCyan],
                  strokeOpacity: 0.26,
                  reveal: rReveal,
                  cometAngle: comet.value * 2 * pi,
                  cometColor: Colors.white,
                ),
              ),
            ),
          ),
          // Soft ambient glow behind the logo.
          Opacity(
            opacity: lReveal,
            child: Container(
              width: screenWidth * 0.62 * pulseBoost,
              height: screenWidth * 0.62 * pulseBoost,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  BrokaColors.gold.withOpacity(0.22),
                  BrokaColors.neonBlue.withOpacity(0.08),
                  Colors.transparent,
                ]),
              ),
            ),
          ),
          // The logo itself - breathing scale, unchanged emblem (spec §2).
          Transform.scale(
            scale: breatheScale.value * (0.85 + 0.15 * lReveal) * pulseBoost,
            child: Opacity(
              opacity: lReveal,
              child: SizedBox(
                width: screenWidth * 0.40,
                height: screenWidth * 0.40,
                child: Image.asset('assets/images/broka_logo_transparent.png', fit: BoxFit.contain),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class _BootTextBlock extends StatelessWidget {
  final String message;
  final AnimationController dotsSweepCtrl;
  final double reveal;
  const _BootTextBlock({required this.message, required this.dotsSweepCtrl, required this.reveal});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShaderMask(
          shaderCallback: (b) => const LinearGradient(colors: BrokaColors.brandGradient).createShader(b),
          child: const Text(
            'BROKA',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 9),
          ),
        ),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'THE FUTURE OF INTELLIGENT COMMERCE',
            textAlign: TextAlign.center,
            maxLines: 1,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: BrokaColors.textMid,
                letterSpacing: 1.6),
          ),
        ),
        const SizedBox(height: 34),
        ShaderMask(
          shaderCallback: (b) =>
              const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]).createShader(b),
          child: const Text(
            'BOOTING ZENO',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 4),
          ),
        ),
        const SizedBox(height: 9),
        Center(
          child: Container(
            width: 64,
            height: 1.4,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.18), end: Offset.zero).animate(anim),
              child: child,
            ),
          ),
          child: Text(
            message,
            key: ValueKey(message),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: Color(0xFFEDF2FF)),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 14,
          child: AnimatedBuilder(
            animation: dotsSweepCtrl,
            builder: (_, __) => CustomPaint(
              painter: ActivityDotsPainter(
                count: 14,
                sweep: -0.25 + dotsSweepCtrl.value * 1.5,
                reveal: reveal,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SoundToggle extends StatelessWidget {
  final bool on;
  final VoidCallback onTap;
  const _SoundToggle({required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: BrokaColors.gold.withOpacity(0.55), width: 1.2),
          ),
          child: Icon(
            on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            color: BrokaColors.gold.withOpacity(0.9),
            size: 20,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          on ? 'SOUND ON' : 'SOUND OFF',
          style: const TextStyle(fontSize: 9, letterSpacing: 2, fontWeight: FontWeight.w600, color: BrokaColors.textMid),
        ),
      ]),
    );
  }
}

class _PoweredByFooter extends StatelessWidget {
  const _PoweredByFooter();

  @override
  Widget build(BuildContext context) {
    return RichText(
      textAlign: TextAlign.center,
      text: const TextSpan(
        style: TextStyle(fontSize: 10, letterSpacing: 2.4, fontWeight: FontWeight.w500, color: BrokaColors.textMid),
        children: [
          TextSpan(text: 'POWERED BY '),
          TextSpan(text: 'ZENO', style: TextStyle(color: BrokaColors.neonBlue, fontWeight: FontWeight.w700)),
          TextSpan(text: ' INTELLIGENCE'),
        ],
      ),
    );
  }
}
