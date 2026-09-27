import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'core/state/marketplace_state.dart';
import 'core/network/api_client.dart';
import 'screens/splash_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/sell_photos_screen.dart';
import 'screens/broker_screen.dart';
import 'screens/auction_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/menu_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/inbox_screen.dart';
import 'screens/negotiation_screen.dart';
import 'screens/negotiate_screen.dart';
import 'screens/ai_assistant_screen.dart';
import 'screens/product_screen.dart';
import 'screens/zeno_screen.dart';
import 'screens/listing_analytics_screen.dart';
import 'screens/how_broka_works_screen.dart';
import 'screens/receipt_history_screen.dart';
import 'screens/store_explainer_screen.dart';
import 'screens/zeno_insights_screen.dart';
import 'screens/listing_map_screen.dart';
import 'screens/selfie_camera_screen.dart';
import 'screens/user_profile_screen.dart';
import 'screens/start_selling_screen.dart';
import 'screens/mpesa_confirmation_screen.dart';
import 'screens/econfirm_payment_screen.dart';
import 'screens/deal_receipt_history_screen.dart';
import 'screens/voip_call_screen.dart';
import 'services/global_poller_service.dart';
import 'theme/motion.dart';
import 'screens/dispute_screen.dart';
import 'screens/verification_screen.dart';
import 'screens/boost_screen.dart';
import 'screens/review_screen.dart';
import 'features/premium/presentation/premium_screen.dart';
import 'features/stores/presentation/my_store_screen.dart';
import 'features/stores/presentation/setup/store_setup_screen.dart';
import 'features/stores/presentation/store_home_screen.dart';
import 'features/zeno_assistant/presentation/zeno_session_host.dart';
import 'features/zeno_assistant/zeno_session.dart';
import 'services/api_service.dart';
import 'services/notification_service.dart';
import 'services/callkit_service.dart';
import 'services/deep_link_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Set from main() if the app was launched cold (fully terminated) by tapping
// an incoming-call push notification, before the navigator exists to act on
// it. SplashScreen consumes and clears this once it's ready to route.
// Deliberately just the data map, not the whole RemoteMessage - keeps the
// firebase_messaging import contained to this file and the one background
// handler below, rather than spreading it across the screens that route.
Map<String, dynamic>? pendingColdStartCallData;

/// Handles an FCM message while the app is backgrounded or fully
/// terminated. Per FlutterFire's requirements this MUST be a top-level (or
/// static) function annotated exactly like this to survive tree-shaking/AOT
/// and to be registerable as an isolate entry point - it cannot be a
/// closure or an instance method, and it runs in its own isolate with no
/// guaranteed access to any state from the main isolate (hence
/// re-initializing Firebase here rather than assuming it's already done).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  if (message.data['type'] == 'incoming_call') {
    // A fresh, throwaway navigator key - nothing in this isolate ever
    // attaches a real Navigator to it, and nothing needs to: showing the
    // notification is all that happens here. A tap on it is handled
    // separately, in the main isolate, via onMessageOpenedApp/
    // getInitialMessage once the app actually comes to the foreground.
    final svc = NotificationService.instance;
    await svc.initialize(navKey: GlobalKey<NavigatorState>());
    await svc.showIncomingCall(
      roomId: message.data['roomId'] as String? ?? '',
      callerName: message.data['callerName'] as String? ?? 'Someone',
      listingName: message.data['listingName'] as String? ?? 'your listing',
      isVideo: message.data['callType'] == 'video',
      payload: message.data,
      // Nothing outside this isolate could stop a ringer started here -
      // see showIncomingCall's ringInApp.
      ringInApp: false,
    );
  }
}

/// The session ended (ApiService.onSessionEnded): show sign-in, saying why.
/// Left alone on the splash and sign-in screens, which already handle a
/// signed-out user, and during a call, which is never interrupted - the
/// next screen after it finds the user signed out.
void _returnToSignIn() {
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  String? current;
  nav.popUntil((route) {
    current = route.settings.name;
    return true;
  });
  if (current == '/auth' || current == '/splash' || current == '/voip-call') return;
  nav.pushNamedAndRemoveUntil('/auth', (_) => false);
  ScaffoldMessenger.maybeOf(nav.context)?.showSnackBar(const SnackBar(
    content: Text('Your session has ended. Please sign in again.'),
  ));
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF03040A),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  await ApiService.loadSavedSession();
  await apiClient.loadToken();
  // ApiService owns the refresh token; apiClient asks it to renew when a
  // request comes back 401, then retries with the new token.
  apiClient.onUnauthorized = ApiService.renewSession;
  // When the server refuses the refresh token (expired after a long time
  // away, or revoked), the session is over: back to sign-in.
  ApiService.onSessionEnded = _returnToSignIn;
  await NotificationService.instance.initialize(navKey: navigatorKey);
  NotificationService.instance.listenForCallActions();
  // Launched by tapping (or pressing Accept on) an incoming-call
  // notification - SplashScreen routes it, as it does an FCM cold start.
  pendingColdStartCallData =
      await NotificationService.instance.launchCallPayload();
  // broka.co.ke/store links: held until the splash screen is done. Not
  // awaited - startup never waits on it.
  unawaited(DeepLinkService.instance.init(navigatorKey));

  // Firebase is optional at this point in BROKA's rollout (see
  // FCM_SETUP_REMAINING.md for exactly what's still externally
  // configurable) - without a real google-services.json in
  // android/app/, initializeApp() throws, and every FCM call below would
  // too. Guarded so the app runs exactly as it does today (local
  // notifications via polling only) until that's in place, rather than
  // crashing on startup for every user until then.
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Foreground: FCM never auto-displays anything while the app is
    // frontmost, by design on every platform - our own local notification
    // (via the same showIncomingCall the poller already uses) is what the
    // user actually sees.
    FirebaseMessaging.onMessage.listen((message) {
      NotificationService.instance.handleForegroundFcmMessage(message.data);
    });

    // App was backgrounded (not terminated) and the user tapped the
    // notification - the navigator already exists by the time this fires.
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      NotificationService.instance.navigateFromPayload(message.data);
    });

    // App was fully terminated and launched BY tapping the notification -
    // no navigator yet at this point in main(), so stash it for
    // SplashScreen to consume once it's ready to route.
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      pendingColdStartCallData = initialMessage.data;
    }

    // Tokens can change (app reinstall, data cleared, etc.) - re-register
    // whenever that happens so a stale token doesn't silently stop
    // delivering calls. GlobalPollerService.start() covers the normal
    // login/session-restore case; this covers the token changing under an
    // already-running session.
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      ApiService.registerFcmToken(newToken);
    });
  } catch (e) {
    debugPrint('[FCM] Firebase not configured yet, skipping: $e');
  }

  // iOS calling. CallKit owns the ringing UI and the audio session on iOS;
  // this hands native answer/end/mute events back into the same call flow
  // every other platform uses. No-op on Android.
  CallKitService.instance.onAnswered = (payload) async {
    await NotificationService.instance.navigateFromPayload({
      'type': 'incoming_call',
      ...payload,
      'answer': true, // answered in the native call UI
    });
  };
  await CallKitService.instance.initialize();


  runApp(
    ChangeNotifierProvider(
      create: (_) => MarketplaceState(),
      child: const BrokaApp(),
    ),
  );
}

// ─── DARK MATTER Design Tokens ─────────────────────────────────────────────
// Deep Navy / Gold Quantum — 22nd-century trading terminal
class BrokaColors {
  // ── Backgrounds ──────────────────────────────────────────────────────────
  static const bg      = Color(0xFF03040A);   // near-black - matches the splash backdrop
  static const bgMid   = Color(0xFF070B16);   // raised surface
  static const bgCard  = Color(0xFF111D35);   // card surface
  static const bgGlass = Color(0x1A8B5CF6);   // purple-tint glass

  // ── Purple palette (primary accent — replaces the old gold) ───────────────
  static const gold        = Color(0xFF8B5CF6);  // primary violet
  static const goldDim     = Color(0xFF4C2E8C);  // deep purple (dim variant)
  static const goldGlow    = Color(0x508B5CF6);
  static const goldSubtle  = Color(0x208B5CF6);

  // ── Accent colours ───────────────────────────────────────────────────────
  static const neonBlue    = Color(0xFF3B82F6);
  static const neonGreen   = Color(0xFF10B981);
  static const neonPurple  = Color(0xFF8B5CF6);
  static const neonPink    = Color(0xFFF472B6);
  static const neonCyan    = Color(0xFF22D3EE);

  // ── Brand gradient (matches the splash logo: violet → blue → cyan) ────────
  // Use this for anything meant to carry BROKA/Zeno's own identity (the AI
  // Broker avatar, primary CTA buttons, the negotiation-room header icon) -
  // green stays reserved for success/positive-action states (Accept,
  // Finalize, online indicators) and isn't part of this sweep.
  static const List<Color> brandGradient = [
    Color(0xFF8B5CF6), // violet (logo top)
    Color(0xFF3B82F6), // blue (logo mid)
    Color(0xFF22D3EE), // cyan (logo bottom)
  ];

  // ── Semantic ─────────────────────────────────────────────────────────────
  static const success = Color(0xFF10B981);
  static const danger  = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);

  // ── Text ─────────────────────────────────────────────────────────────────
  static const textHigh = Color(0xFFE3D9F7);  // pale lavender (was warm cream)
  static const textMid  = Color(0xFF8A9BBF);  // muted slate
  static const textLow  = Color(0xFF2E3D5A);  // very dim

  // ── Borders ──────────────────────────────────────────────────────────────
  static const border     = Color(0xFF1E2D47);
  static const borderGlow = Color(0xFF8B5CF6);

  // ── Gradient helpers ─────────────────────────────────────────────────────
  static const List<Color> headerGradColors = [Color(0xFF070B16), Color(0xFF03040A)];
  static const List<Color> cardGradColors   = [Color(0xFF111D35), Color(0xFF0A1220)];

  static const bool isDark = true;

  // Legacy aliases (keep unchanged screens compiling)
  static const gradStart  = Color(0xFF8B5CF6);
  static const gradMid    = Color(0xFF4C2E8C);
  static const gradEnd    = Color(0xFF03040A);
  static const neonBlue2  = Color(0xFF3B82F6);

  static const primaryGradient = LinearGradient(
    colors: [gold, goldDim],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const cardGradient = LinearGradient(
    colors: cardGradColors,
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Glows
  static const glowGold   = BoxShadow(color: Color(0x508B5CF6), blurRadius: 24);
  static const glowBlue   = BoxShadow(color: Color(0x403B82F6), blurRadius: 20);
  static const glowPurple = BoxShadow(color: Color(0x408B5CF6), blurRadius: 20);
  static const glowCyan   = BoxShadow(color: Color(0x4000E5CC), blurRadius: 20);

  // ── Zone theming ─────────────────────────────────────────────────────────
  // Per Document 2 (the founder's own reconciliation of the Gemini spec):
  // "The Zone doesn't need to change the entire colour palette dramatically
  // ... use subtle differences ... The BROKA identity stays consistent,
  // while each Zone gets its own personality." Each zone gets a 2-colour
  // gradient for its header/glow/selected-chip - mostly built from the
  // existing neon tokens above rather than a separate palette, so a zone
  // reads as "BROKA, tuned for this category" and not a different app.
  // amber/orange are the only two genuinely new hex values in this file;
  // every other zone reuses a token already defined above.
  // Public (was _amber/_orange) so features/categories/domain/category_visual.dart
  // can hold the per-category gradient table. These two exist only for
  // category personality colours, hence the zone* naming.
  static const zoneAmber  = Color(0xFFFBBF24);
  static const zoneOrange = Color(0xFFFF6B4A);

  // zoneGradients / zoneGradientFor moved to
  // features/categories/domain/category_visual.dart (category-alignment pass,
  // 2026-09-18). They were a second, parallel category table keyed the same
  // way as home_screen's emoji map and drifting from it - "furniture" had a
  // gradient but no emoji, "other" had an emoji but no gradient. One
  // registry now owns emoji, icon and gradient together; call
  // CategoryVisuals.gradientFor(name) (or .resolve(name).gradient) instead.

}

// ─── Shared UI Components ──────────────────────────────────────────────────
class DmCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? borderColor;
  final List<BoxShadow>? shadows;
  const DmCard({super.key, required this.child, this.padding, this.borderColor, this.shadows});

  @override
  Widget build(BuildContext context) => Container(
    padding: padding ?? const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: BrokaColors.cardGradient,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: borderColor ?? BrokaColors.border),
      boxShadow: shadows,
    ),
    child: child,
  );
}

class GoldButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  final IconData? icon;
  const GoldButton({super.key, required this.label, this.onTap, this.loading = false, this.icon});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: loading ? null : onTap,
    child: Container(
      height: 52,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BrokaColors.glowGold],
      ),
      child: Center(
        child: loading
            ? const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(color: BrokaColors.bg, strokeWidth: 2))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, color: BrokaColors.bg, size: 18), const SizedBox(width: 8)],
                Text(label, style: const TextStyle(
                  color: BrokaColors.bg, fontWeight: FontWeight.bold,
                  fontSize: 15, letterSpacing: 1,
                )),
              ]),
      ),
    ),
  );
}

class DmDivider extends StatelessWidget {
  final String? label;
  const DmDivider({super.key, this.label});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Container(height: 1,
      decoration: const BoxDecoration(gradient: LinearGradient(
        colors: [Colors.transparent, BrokaColors.border])))),
    if (label != null) ...[
      const SizedBox(width: 12),
      Text(label!, style: const TextStyle(color: BrokaColors.textLow, fontSize: 10, letterSpacing: 2)),
      const SizedBox(width: 12),
    ],
    Expanded(child: Container(height: 1,
      decoration: const BoxDecoration(gradient: LinearGradient(
        colors: [BrokaColors.border, Colors.transparent])))),
  ]);
}

/// Gradient-filled, glowing header text - the "Zone" signature moment
/// (ELECTRONICS ZONE / GAMING ZONE / ...). srcIn replaces colour only where
/// the child has any alpha, so the TextStyle's own Shadow entries come out
/// as a soft gradient-tinted glow around the letters rather than a flat
/// drop shadow - no image asset, stays crisp at any size.
class ZoneGlowText extends StatelessWidget {
  final String text;
  final List<Color> gradient;
  final double fontSize;
  final TextAlign textAlign;
  /// Added for the category-alignment pass (2026-09-18): a Zone title like
  /// "BEAUTY & PERSONAL CARE ZONE" has to be allowed to wrap, and to stop
  /// wrapping once the header collapses. Null keeps the previous
  /// unconstrained behaviour for any existing caller.
  final int? maxLines;
  final double letterSpacing;
  const ZoneGlowText(this.text, {
    super.key, required this.gradient, this.fontSize = 26, this.textAlign = TextAlign.start,
    this.maxLines, this.letterSpacing = 1.4,
  });

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (bounds) => LinearGradient(
      colors: gradient,
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    ).createShader(bounds),
    child: Text(
      text.toUpperCase(),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        letterSpacing: letterSpacing,
        height: 1.12,
        color: Colors.white,
        shadows: [
          Shadow(color: gradient.first, blurRadius: 18),
          Shadow(color: gradient.last, blurRadius: 36),
        ],
      ),
    ),
  );
}

// ─── App ──────────────────────────────────────────────────────────────────
class BrokaApp extends StatefulWidget {
  const BrokaApp({super.key});

  @override
  State<BrokaApp> createState() => _BrokaAppState();
}

class _BrokaAppState extends State<BrokaApp> with WidgetsBindingObserver {
  DateTime? _pausedAt;
  // If the app was backgrounded for longer than this, jump to /home on
  // resume instead of leaving the user on whatever screen they left -
  // that screen's timers/sockets are usually stale after a long pause,
  // which was causing a dark blank screen on some screens.
  static const _idleThreshold = Duration(minutes: 5);

  final _zeno = ZenoSession();

  // App-wide presence heartbeat. Individual chat screens also ping this
  // endpoint while open (harmless/redundant), but WhatsApp-style presence
  // should reflect "the app is open", not "the user happens to be inside a
  // specific chat" - so this fires whenever the app is in the foreground.
  Timer? _heartbeatTimer;

  void _startHeartbeat() {
    ApiService.updateLastSeen();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => ApiService.updateLastSeen());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startHeartbeat();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatTimer?.cancel();
    _zeno.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      // Stop pinging while backgrounded so "last seen" actually freezes at
      // the moment the user left, instead of the app looking perpetually
      // online from a background isolate.
      _heartbeatTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _startHeartbeat();

      // Catch up on everything that happened while we were away, BEFORE any
      // of the early-returns below.
      //
      // The poller's 7s timer only runs while the OS is actually scheduling
      // this isolate. Background it, lose signal, or let the phone sleep and
      // that timer stops; when it starts again it sees the current state of
      // the world and nothing about what was missed in between. So messages
      // and calls that arrived while offline produced no notification at
      // all - the user simply found them next time they opened the thread.
      //
      // Placed above the _idleThreshold check deliberately: that threshold
      // exists to decide whether to REDIRECT the user's screen, which is a
      // much heavier intervention than posting a notification. A 20-second
      // dip out of the app is not worth yanking someone's screen for, but
      // it is absolutely long enough to miss a call.
      unawaited(GlobalPollerService.instance.catchUp());

      final pausedAt = _pausedAt;
      _pausedAt = null;
      if (pausedAt == null) return;
      if (DateTime.now().difference(pausedAt) < _idleThreshold) return;

      final nav = navigatorKey.currentState;
      if (nav == null) return;
      // Don't interrupt the splash/auth flow itself, and never yank the user
      // out of an active call - this exact redirect was the other half of
      // the "screen off -> call drops" bug: a call left running with the
      // screen off for longer than _idleThreshold would resume only to be
      // immediately torn down and replaced with /home.
      final currentRoute = ModalRoute.of(nav.context)?.settings.name;
      if (currentRoute == '/splash' || currentRoute == '/auth' ||
          currentRoute == '/voip-call') return;
      if (ApiService.currentUserId == null) return;
      nav.pushNamedAndRemoveUntil('/home', (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      // Zeno's session lives above the Navigator, so it stays with the user
      // from screen to screen (features/zeno_assistant/zeno_session.dart).
      navigatorObservers: [_zeno.routes],
      builder: (context, child) => ZenoSessionHost(session: _zeno, child: child ?? const SizedBox.shrink()),
      debugShowCheckedModeBanner: false,
      title: 'BROKA',
      theme: _buildTheme(),
      initialRoute: '/splash',
      routes: {
        '/splash':           (_) => const SplashScreen(),
        '/auth':             (_) => const AuthScreen(),
        '/home':             (_) => const HomeScreen(),
        '/sell':             (_) => const SellPhotosScreen(),
        '/broker':           (_) => const BrokerScreen(),
        '/auction':          (ctx) => AuctionScreen(
              listingId: ModalRoute.of(ctx)?.settings.arguments as String?,
            ),
        // The bottom nav's fifth tab. Profile and Settings open from it.
        '/menu':             (_) => const MenuScreen(),
        '/profile':          (_) => const ProfileScreen(),
        '/settings':         (_) => const SettingsScreen(),
        '/inbox':            (_) => const InboxScreen(),
        '/negotiate':        (_) => const NegotiateScreen(),
        '/direct-chat':      (_) => const NegotiationScreen(),
        '/assistant':        (_) => const AiAssistantScreen(),
        '/product':          (_) => const ProductScreen(),
        '/zeno':             (_) => const ZenoScreen(),
        '/listing-map':      (_) => const ListingMapScreen(),
        '/listing-insights': (_) => const ListingAnalyticsScreen(),
        '/zeno-insights':    (_) => const ZenoInsightsScreen(),
        '/how-broka-works':  (_) => const HowBrokaWorksScreen(),
        '/receipt-history':  (_) => const ReceiptHistoryScreen(),
        '/store-explainer':  (_) => const StoreExplainerScreen(),
        '/selfie':           (_) => const SelfieCameraScreen(),
        '/user-profile':     (_) => const UserProfileScreen(),
        '/seller-dashboard': (_) => sellerDashboardOrSetup(),
        '/start-selling':    (_) => const StartSellingScreen(),
        '/mpesa-confirm':    (_) => const MpesaConfirmationScreen(),
        '/escrow-payment':   (_) => const EConfirmPaymentScreen(),
        '/deal-history':     (_) => const DealReceiptHistoryScreen(),
        '/voip-call':        (_) => const VoipCallScreen(),
        '/dispute':          (_) => const DisputeScreen(),
        '/verify':           (_) => const VerificationScreen(),
        '/boost':            (_) => const BoostScreen(),
        // Arguments: the plan to pick first (a refused feature's upgrade_to).
        '/premium':          (ctx) => PremiumScreen(
              highlight: ModalRoute.of(ctx)?.settings.arguments as String?,
            ),
        '/review':           (_) => const ReviewScreen(),
        '/store-setup':      (_) => const StoreSetupScreen(),
        // The old name of the store-setup route; kept so any link to it
        // lands on the setup wizard.
        '/create-store':     (_) => const StoreSetupScreen(),
        '/store-manage':     (_) => const MyStoreScreen(),
        // Arguments: {storeId} or {slug}, and optionally {via}.
        '/store-view':       (_) => const StoreHomeScreen(),
      },
    );
  }

  ThemeData _buildTheme() => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: BrokaColors.bg,
    // One transition for every route in the app.
    //
    // Before this, navigation used the bare platform default everywhere
    // except three hand-rolled PageRouteBuilders - so moving between
    // screens looked like a stock Android app on a product that looks
    // like nothing else. Setting it here means every existing
    // Navigator.push picks it up with no call-site changes.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: BrokaPageTransition(),
      TargetPlatform.iOS:     BrokaPageTransition(),
      TargetPlatform.fuchsia: BrokaPageTransition(),
    }),
    colorScheme: const ColorScheme.dark(
      primary:   BrokaColors.gold,
      secondary: BrokaColors.neonCyan,
      surface:   BrokaColors.bgCard,
      error:     BrokaColors.danger,
    ),
    fontFamily: 'Georgia',
    appBarTheme: const AppBarTheme(
      backgroundColor: BrokaColors.bg,
      foregroundColor: BrokaColors.textHigh,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: BrokaColors.gold,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 2.5,
        fontFamily: 'Georgia',
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge:  TextStyle(color: BrokaColors.textHigh),
      bodyMedium: TextStyle(color: BrokaColors.textMid),
      bodySmall:  TextStyle(color: BrokaColors.textLow),
      titleLarge: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold),
      labelSmall: TextStyle(color: BrokaColors.textLow, letterSpacing: 1.5),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: BrokaColors.bgCard,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: BrokaColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: BrokaColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: BrokaColors.gold, width: 1.5),
      ),
      hintStyle: const TextStyle(color: BrokaColors.textLow),
      labelStyle: const TextStyle(color: BrokaColors.textMid),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: BrokaColors.gold,
        foregroundColor: BrokaColors.bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: BrokaColors.bgMid,
      selectedItemColor: BrokaColors.gold,
      unselectedItemColor: BrokaColors.textLow,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
    dividerColor: BrokaColors.border,
    cardColor: BrokaColors.bgCard,
  );
}
