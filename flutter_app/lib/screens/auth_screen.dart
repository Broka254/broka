// BROKA - Auth Screen
// Login: phone + password, optional biometric unlock.
// Register: 6-step wizard (v6.1 phone-first onboarding rework)
//   Step 1 - Phone number -> requests an SMS code
//   Step 2 - Verify code (autofilled via the OS, manual entry as fallback)
//   Step 3 - Basic info (official name, preferred name, optional email, password)
//   Step 4 - Profile selfie (front camera only, no gallery)
//   Step 5 - BROKA Biometric Setup (fresh fingerprint or face scan, not stored device data)
//   Step 6 - Confirmation / account created
//
// Registering as a seller is NOT part of this flow anymore - every account
// starts as a buyer; becoming a seller is a separate step from Profile
// ("Become a Seller" -> BecomeSellerScreen) once the account exists.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../main.dart';
import '../widgets/gradient_button.dart';
import '../services/api_service.dart';
import '../services/global_poller_service.dart';
import '../services/sms_autofill_service.dart';
import '../widgets/constellation_background.dart';
import '../widgets/country_phone_field.dart';
import '../widgets/otp_code_field.dart';

/// Primary call-to-action gradient: violet into blue, the left two thirds of
/// the BROKA logo sweep. BrokaColors.gradMid (a deep purple) is the app-wide
/// default and reads much flatter at this button size.
const List<Color> _kCtaGradient = [Color(0xFF8B5CF6), Color(0xFF3B82F6)];

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  bool _isLogin = true;
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  // Registration step (1-6)
  int _step = 1;

  // Fields
  final _phoneCtrl    = TextEditingController();  // step 1 (register) / login identifier
  final _otpCtrl      = TextEditingController();  // step 2
  final _emailCtrl    = TextEditingController();  // step 3 - optional
  final _passwordCtrl = TextEditingController();
  final _nameCtrl     = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();
  final _emailOtpCtrl = TextEditingController();

  // Phone verification (steps 1-2) — OTP is optional at signup; the user
  // can skip it from either step and verify later from Profile.
  String? _phoneVerifyToken;
  bool   _skippedOtp = false; // true only if Step 2 was never reached (see _prevStep)

  /// Seconds until "Resend code" becomes tappable again. Two minutes, not the
  /// 30s it used to be: every resend is a real SMS we pay for, and a tighter
  /// window mostly buys repeat sends from people who simply haven't waited
  /// for the first message to land.
  static const int _kResendCooldownSeconds = 120;
  int _resendCooldown = 0;

  /// Seconds until the code the server issued stops being accepted, taken
  /// from the OTP response rather than assumed, so the countdown on screen
  /// cannot drift away from what the backend will actually honour.
  int _otpExpiresIn = 0;
  Timer? _otpExpiryTimer;

  /// Dial code for the phone field. The typed part stays national
  /// (`0706462869`); `_fullPhone` composes the two into E.164.
  String _dialCode = '+254';

  /// Email verification (step 5). The address is optional, so all of this
  /// stays null/false when the user skips it.
  ///
  /// Step 5 has two phases on one screen rather than two wizard steps: enter
  /// the address, then enter the code sent to it. `_emailCodeSent` is which
  /// phase is showing.
  bool _emailCodeSent = false;
  String? _emailVerifyToken;
  int _emailResendCooldown = 0;
  Timer? _emailResendTimer;
  int _emailOtpExpiresIn = 0;
  Timer? _emailOtpExpiryTimer;
  bool _obscureConfirm = true;

  /// Android SMS Retriever hash for this build, fetched once and reused for
  /// every OTP request in this session.
  String? _appSignature;
  StreamSubscription<String>? _smsSub;
  Timer? _resendTimer;

  // Selfie (step 4)
  String? _capturedPhoto; // base64

  // Biometrics (step 5)
  final LocalAuthentication _localAuth = LocalAuthentication();
  bool   _biometricAvailable  = false;
  bool   _biometricEnrolled   = false;  // device has biometrics set up
  List<BiometricType> _availableTypes = [];
  String _chosenBiometric     = 'none'; // 'fingerprint' | 'face' | 'none'
  bool   _biometricVerified   = false;  // true after a fresh scan is confirmed

  late AnimationController _fadeCtrl, _stepAnim;
  late Animation<double>   _fade, _stepFade;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 600))..forward();
    _stepAnim = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 350))..forward();
    _fade     = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _stepFade = CurvedAnimation(parent: _stepAnim, curve: Curves.easeOut);
    _checkBiometrics();
    _prefetchAppSignature();
  }

  /// The composed E.164 number, e.g. "+254706462869".
  String get _fullPhone => composeE164(_dialCode, _phoneCtrl.text);

  /// Digits the user actually typed, used only for length validation.
  String get _phoneDigits => _phoneCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');

  /// Reads the SMS Retriever app-signature hash up front so requesting a code
  /// doesn't have to wait on a platform round-trip. Null on iOS and wherever
  /// Play Services is unavailable, which simply means a plain SMS.
  Future<void> _prefetchAppSignature() async {
    final sig = await SmsAutofillService.appSignature();
    if (mounted) _appSignature = sig;
  }

  Future<void> _checkBiometrics() async {
    try {
      // isDeviceSupported checks if the hardware exists (sensor present)
      final supported = await _localAuth.isDeviceSupported();
      // canCheckBiometrics is true only if biometrics are ENROLLED on the device
      final enrolled  = await _localAuth.canCheckBiometrics;
      final types     = await _localAuth.getAvailableBiometrics();
      if (mounted) setState(() {
        _biometricAvailable = supported; // hardware exists
        _biometricEnrolled  = enrolled;  // AND biometrics set up in device settings
        _availableTypes     = types;
      });
    } catch (_) {
      // Hardware absent, or no local_auth implementation on this platform at
      // all. The latter raises MissingPluginException, which is NOT a
      // PlatformException, so the narrower catch this replaces let it escape
      // as an unhandled async error and took the whole screen's init with it.
      // Either way the answer is the same: leave the biometric options off.
    }
  }

  @override
  void dispose() {
    _fadeCtrl.dispose(); _stepAnim.dispose();
    _resendTimer?.cancel();
    _otpExpiryTimer?.cancel();
    _smsSub?.cancel();
    SmsAutofillService.stop();
    _emailResendTimer?.cancel();
    _emailOtpExpiryTimer?.cancel();
    _phoneCtrl.dispose(); _otpCtrl.dispose(); _emailCtrl.dispose();
    _passwordCtrl.dispose(); _confirmPasswordCtrl.dispose();
    _emailOtpCtrl.dispose();
    _nameCtrl.dispose(); _nicknameCtrl.dispose();
    super.dispose();
  }

  void _switchMode(bool toLogin) {
    _resendTimer?.cancel();
    _emailResendTimer?.cancel();
    _emailOtpExpiryTimer?.cancel();
    // The expiry countdown ticks setState every second; leaving Login while
    // sitting on the verify step would otherwise keep it running against a
    // screen that no longer shows it.
    _otpExpiryTimer?.cancel();
    SmsAutofillService.stop();
    setState(() {
      _isLogin = toLogin;
      _error   = null;
      _step    = 1;
      _otpCtrl.clear();
      _phoneVerifyToken   = null;
      _skippedOtp         = false;
      _resendCooldown     = 0;
      _otpExpiresIn       = 0;
      _capturedPhoto      = null;
      _chosenBiometric    = 'none';
      _biometricVerified  = false;
      _emailCodeSent      = false;
      _emailVerifyToken   = null;
      _emailResendCooldown = 0;
      _emailOtpExpiresIn  = 0;
      _emailOtpCtrl.clear();
    });
    _stepAnim.forward(from: 0);
  }

  void _animateStep(int newStep) {
    _stepAnim.forward(from: 0);
    setState(() { _step = newStep; _error = null; });
  }

  // ── Step navigation ───────────────────────────────────────────────────────

  Future<void> _nextStep() async {
    if (_step == 1) {
      if (_phoneDigits.length < 9) {
        setState(() => _error = 'Please enter a valid phone number'); return;
      }
      setState(() { _loading = true; _error = null; });
      try {
        await _sendOtp();
        if (mounted) {
          setState(() { _loading = false; _skippedOtp = false; });
          _animateStep(2);
        }
      } catch (e) {
        if (mounted) setState(() {
          _loading = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } else if (_step == 2) {
      final code = _otpCtrl.text.trim();
      if (code.length < 4) {
        setState(() => _error = 'Enter the code we texted you'); return;
      }
      setState(() { _loading = true; _error = null; });
      try {
        _phoneVerifyToken = await ApiService.verifyOtp(_fullPhone, code);
        if (mounted) { setState(() => _loading = false); _animateStep(3); }
      } catch (e) {
        if (mounted) setState(() {
          _loading = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } else if (_step == 3) {
      if (_nameCtrl.text.trim().isEmpty) {
        setState(() => _error = 'Please enter your official name'); return;
      }
      _animateStep(4);
    } else if (_step == 4) {
      // Preferred name is optional — an empty field is a valid answer and
      // means "use my official name".
      _animateStep(5);
    } else if (_step == 5) {
      await _handleEmailStep();
    } else if (_step == 6) {
      if (_passwordCtrl.text.length < 6) {
        setState(() => _error = 'Password must be at least 6 characters'); return;
      }
      if (_passwordCtrl.text != _confirmPasswordCtrl.text) {
        setState(() => _error = 'Both passwords must match'); return;
      }
      _animateStep(7);
    } else if (_step == 7) {
      if (_capturedPhoto == null) {
        setState(() => _error = 'Please take a selfie to continue'); return;
      }
      _animateStep(8);
    } else if (_step == 8) {
      // Biometrics are optional — the user can skip.
      _animateStep(9);
    }
  }

  // ── Email step (optional, verified in place) ──────────────────────────────

  /// Drives step 5's two phases. An empty address is a valid answer and moves
  /// straight on; an address sends a code and swaps the screen to the code
  /// phase; a code on screen verifies it.
  Future<void> _handleEmailStep() async {
    if (_emailCodeSent) {
      final code = _emailOtpCtrl.text.trim();
      if (code.length < 4) {
        setState(() => _error = 'Enter the code we emailed you'); return;
      }
      setState(() { _loading = true; _error = null; });
      try {
        _emailVerifyToken = await ApiService.verifyEmailOtp(
            _emailCtrl.text.trim(), code);
        _emailResendTimer?.cancel();
        _emailOtpExpiryTimer?.cancel();
        if (mounted) { setState(() => _loading = false); _animateStep(6); }
      } catch (e) {
        if (mounted) setState(() {
          _loading = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
      return;
    }

    final email = _emailCtrl.text.trim();
    if (email.isEmpty) { _skipEmail(); return; }
    if (!_looksLikeEmail(email)) {
      setState(() => _error = 'Please enter a valid email address'); return;
    }

    setState(() { _loading = true; _error = null; });
    try {
      await _sendEmailOtp();
      if (mounted) setState(() { _loading = false; _emailCodeSent = true; });
      _stepAnim.forward(from: 0);   // same transition as a step change
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// Mirrors the backend's check rather than trying to out-clever it: the
  /// server decides, and an over-strict client pattern would reject valid
  /// addresses before they ever got there.
  static bool _looksLikeEmail(String v) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim());

  Future<void> _sendEmailOtp() async {
    final data = await ApiService.requestEmailOtp(_emailCtrl.text.trim());
    _startEmailResendCooldown();
    final expiry = data['expires_in_seconds'];
    _startEmailOtpExpiry(expiry is int ? expiry : int.tryParse('$expiry') ?? 0);
  }

  void _startEmailResendCooldown() {
    _emailResendTimer?.cancel();
    setState(() => _emailResendCooldown = _kResendCooldownSeconds);
    _emailResendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _emailResendCooldown--);
      if (_emailResendCooldown <= 0) t.cancel();
    });
  }

  void _startEmailOtpExpiry(int seconds) {
    _emailOtpExpiryTimer?.cancel();
    if (seconds <= 0) { setState(() => _emailOtpExpiresIn = 0); return; }
    setState(() => _emailOtpExpiresIn = seconds);
    _emailOtpExpiryTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _emailOtpExpiresIn--);
      if (_emailOtpExpiresIn <= 0) t.cancel();
    });
  }

  Future<void> _resendEmailOtp() async {
    if (_emailResendCooldown > 0 || _loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      _emailOtpCtrl.clear();
      await _sendEmailOtp();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Back to the address field, e.g. after a typo. The pending code is
  /// abandoned rather than carried over to a different address.
  void _changeEmailAddress() {
    _emailResendTimer?.cancel();
    _emailOtpExpiryTimer?.cancel();
    setState(() {
      _emailCodeSent = false;
      _emailVerifyToken = null;
      _emailResendCooldown = 0;
      _emailOtpExpiresIn = 0;
      _emailOtpCtrl.clear();
      _error = null;
    });
    _stepAnim.forward(from: 0);
  }

  /// Email is optional. Skipping clears anything half-entered so a typed but
  /// unverified address is never silently registered.
  void _skipEmail() {
    _emailResendTimer?.cancel();
    _emailOtpExpiryTimer?.cancel();
    setState(() {
      _emailCtrl.clear();
      _emailOtpCtrl.clear();
      _emailCodeSent = false;
      _emailVerifyToken = null;
      _emailResendCooldown = 0;
      _emailOtpExpiresIn = 0;
      _error = null;
    });
    _animateStep(6);
  }

  /// OTP is optional at signup. Called from Step 1 - skips sending an SMS
  /// entirely and goes straight to Step 3. The phone is still required
  /// (it's the account's login identifier either way); only *proving* it
  /// becomes optional. Verification can be finished later from Profile.
  void _skipPhoneVerification() {
    if (_phoneDigits.length < 9) {
      setState(() => _error = 'Please enter a valid phone number'); return;
    }
    setState(() {
      _phoneVerifyToken = null;
      _skippedOtp = true;
      _error = null;
    });
    _animateStep(3);
  }

  /// Called from Step 2 - a code WAS already sent, the user just chooses
  /// not to enter it right now. _skippedOtp stays false here since Step 2
  /// was genuinely visited, so "Back" from Step 3 still lands there correctly.
  void _skipOtpVerification() {
    setState(() {
      _phoneVerifyToken = null;
      _error = null;
    });
    _animateStep(3);
  }

  void _prevStep() {
    // Within the email step, "back" means the code phase returns to the
    // address field rather than leaving the step entirely.
    if (_step == 5 && _emailCodeSent) { _changeEmailAddress(); return; }
    // If OTP was skipped from Step 1, Step 2 (code entry) was never shown
    // and no code was ever sent - going "back" from Step 3 must return to
    // Step 1, not to an OTP screen that would wrongly claim a code is on its way.
    if (_step == 3 && _skippedOtp) { _animateStep(1); return; }
    if (_step > 1) _animateStep(_step - 1);
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendCooldown = _kResendCooldownSeconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _resendCooldown--);
      if (_resendCooldown <= 0) t.cancel();
    });
  }

  void _startOtpExpiry(int seconds) {
    _otpExpiryTimer?.cancel();
    if (seconds <= 0) { setState(() => _otpExpiresIn = 0); return; }
    setState(() => _otpExpiresIn = seconds);
    _otpExpiryTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _otpExpiresIn--);
      if (_otpExpiresIn <= 0) t.cancel();
    });
  }

  static String _fmtMinSec(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final m = s ~/ 60;
    return '${m.toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// Cooldown label. Reads as plain seconds under a minute ("in 24s") and as
  /// a clock above it ("in 1:58"), so a two-minute wait doesn't display as an
  /// unreadable "in 118s".
  static String _fmtCooldown(int seconds) =>
      seconds >= 60 ? '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}' : '${seconds}s';

  /// Requests a code and arms automatic capture of the SMS that follows.
  ///
  /// The retriever is armed BEFORE the request goes out. Arming covers
  /// exactly one message, and the SMS can arrive within a second or two, so
  /// doing this afterwards is a race the message sometimes wins — which is
  /// precisely the "sometimes it fills, sometimes it doesn't" behaviour this
  /// replaces.
  Future<void> _sendOtp() async {
    await SmsAutofillService.start();
    _listenForSmsCode();
    final data = await ApiService.requestOtp(_fullPhone, appSignature: _appSignature);
    _startResendCooldown();
    final expiry = data['expires_in_seconds'];
    _startOtpExpiry(expiry is int ? expiry : int.tryParse('$expiry') ?? 0);
  }

  /// Pipes a captured code straight into the field. No prompt, no
  /// confirmation — the code is filled and submitted for the user.
  void _listenForSmsCode() {
    _smsSub ??= SmsAutofillService.codes().listen((code) {
      if (!mounted || _step != 2) return;
      _otpCtrl.text = code;
      // OtpCodeField's onCompleted fires off the controller change and calls
      // _nextStep(), so there is deliberately nothing else to do here.
    });
  }

  Future<void> _resendOtp() async {
    if (_resendCooldown > 0 || _loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      _otpCtrl.clear();
      await _sendOtp();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Selfie ────────────────────────────────────────────────────────────────

  Future<void> _openSelfie() async {
    final result = await Navigator.pushNamed(context, '/selfie');
    if (result is String && result.isNotEmpty && mounted) {
      setState(() => _capturedPhoto = result);
    }
  }

  // ── BROKA Biometric - fresh scan, not device stored data ──────────────────

  /// Performs a LIVE biometric scan specifically for BROKA.
  /// This is NOT reading stored fingerprints - it prompts the user to
  /// physically place their finger or look at the camera RIGHT NOW.
  Future<void> _enrollBiometric(String type) async {
    if (!_biometricAvailable) return;
    try {
      setState(() => _loading = true);
      final reason = type == 'fingerprint'
          ? 'Place your finger on the sensor to register your BROKA fingerprint'
          : 'Look at the camera to register your BROKA Face ID';
      final verified = await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          sensitiveTransaction: true, // marks this as a security-critical action
        ),
      );
      if (mounted) {
        setState(() {
          _loading = false;
          if (verified) {
            _chosenBiometric   = type;
            _biometricVerified = true;
            _error = null;
          } else {
            _error = 'Biometric scan not confirmed. Please try again.';
          }
        });
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = 'Biometric error: ${e.message}';
      });
    }
  }

  // ── Biometric login ───────────────────────────────────────────────────────

  Future<void> _biometricLogin() async {
    if (!ApiService.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please log in with your password first'),
        backgroundColor: BrokaColors.warning,
      ));
      return;
    }
    try {
      final ok = await _localAuth.authenticate(
        localizedReason: 'Verify your identity to access BROKA',
        options: const AuthenticationOptions(
            biometricOnly: true, stickyAuth: true),
      );
      if (ok && mounted) {
        GlobalPollerService.instance.start();
        _returnAuthenticated();
      }
    } on PlatformException { /* ignore */ }
  }

  // ── Final submit ──────────────────────────────────────────────────────────

  /// v6.1: AuthScreen is now reached both as the initial post-splash screen
  /// (rare - guests land on Home) and, far more commonly, pushed on top of
  /// whatever screen triggered a sign-up prompt (see lib/utils/auth_gate.dart).
  /// Pop with `true` when there's somewhere to return to, so the caller can
  /// resume the action that triggered sign-up (e.g. land straight in the
  /// Zeno chat instead of dropping back to Home). Only fall back to
  /// replacing with Home when this screen has nothing to pop to.
  void _returnAuthenticated() {
    if (Navigator.canPop(context)) {
      Navigator.pop(context, true);
    } else {
      Navigator.pushReplacementNamed(context, '/home');
    }
  }

  Future<void> _submitRegistration() async {
    // OTP is optional at signup — _phoneVerifyToken is null if the user
    // skipped verification (Step 1 or Step 2). Either way the phone number
    // itself is required; it's always been collected by this point.
    final phone = _fullPhone;
    if (_phoneDigits.length < 9) {
      setState(() => _error = 'Please enter your phone number again.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final data = await ApiService.register(
        phoneVerifyToken: _phoneVerifyToken,
        phone:        phone,
        name:         _nameCtrl.text.trim(),
        nickname:     _nicknameCtrl.text.trim().isEmpty
                          ? null : _nicknameCtrl.text.trim(),
        email:        _emailCtrl.text.trim().isEmpty
                          ? null : _emailCtrl.text.trim(),
        // Present only when the address was actually proven at step 5. The
        // server takes the email from this token when it is set, so a
        // verified address can't be swapped for another in the same call.
        emailVerifyToken: _emailVerifyToken,
        password:     _passwordCtrl.text,
        lat:          -1.286389,
        lng:          36.817223,
        profilePhoto: _capturedPhoto,
      );
      if (data['access_token'] == null) {
        throw Exception(data['detail'] ?? 'Registration failed');
      }
      // If biometric was enrolled, record it on the server
      if (_biometricVerified && _chosenBiometric != 'none') {
        try {
          await ApiService.enrollBiometric(_chosenBiometric);
        } catch (_) { /* non-fatal */ }
      }
      if (mounted) {
        GlobalPollerService.instance.start();
        _returnAuthenticated();
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitLogin() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await ApiService.login(
        phone: _fullPhone, password: _passwordCtrl.text);
      if (data['access_token'] == null) {
        throw Exception(data['detail'] ?? 'Login failed');
      }
      if (mounted) {
        GlobalPollerService.instance.start();
        _returnAuthenticated();
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // The constellation is the tall element here; letting the view resize
      // for the keyboard would squeeze it and make the stars visibly jump
      // every time the field gains focus. The scroll view below handles
      // keeping the focused field visible instead.
      resizeToAvoidBottomInset: false,
      body: ConstellationBackground(
        child: FadeTransition(
          opacity: _fade,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 28,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  _buildLogo(),
                  const SizedBox(height: 28),
                  _buildTabToggle(),
                  const SizedBox(height: 26),
                  FadeTransition(
                    opacity: _stepFade,
                    child: _isLogin ? _buildLoginForm() : _buildRegisterStep(),
                  ),
                  const SizedBox(height: 24),
                  _buildDivider(),
                  const SizedBox(height: 18),
                  _buildSwitchPrompt(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Login form ────────────────────────────────────────────────────────────

  Widget _buildLoginForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Welcome back',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800,
              color: BrokaColors.textHigh, letterSpacing: -0.5)),
      const SizedBox(height: 8),
      const Text('Sign in to continue buying, selling and negotiating on BROKA.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 15, height: 1.45)),
      const SizedBox(height: 24),
      CountryPhoneField(
        controller: _phoneCtrl,
        dialCode: _dialCode,
        onDialCodeChanged: (c) => setState(() => _dialCode = c),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 14),
      _buildPasswordField(),
      const SizedBox(height: 12),
      Align(alignment: Alignment.centerRight,
        child: Text('Forgot password?',
          style: TextStyle(color: BrokaColors.gold,
              fontSize: 13, fontWeight: FontWeight.w700))),
      const SizedBox(height: 22),
      if (_error != null) _buildError(),
      GradientButton(
        height: 58,
        borderRadius: 16,
        colors: _kCtaGradient,
        onPressed: _loading ? null : _submitLogin,
        child: _loading
            ? const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Enter BROKA', style: TextStyle(fontSize: 17,
                    fontWeight: FontWeight.w700, color: Colors.white)),
                SizedBox(width: 10),
                Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
              ]),
      ),
      if (_biometricAvailable) ...[
        const SizedBox(height: 12),
        _buildBiometricLoginButton(),
      ],
    ],
  );

  // ── Registration steps ────────────────────────────────────────────────────

  Widget _buildRegisterStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildStepIndicator(),
      const SizedBox(height: 24),
      if (_step == 1) _buildStep1Phone(),
      if (_step == 2) _buildStep2Otp(),
      if (_step == 3) _buildStep3Name(),
      if (_step == 4) _buildStep4Nickname(),
      if (_step == 5) _buildStep5Email(),
      if (_step == 6) _buildStep6Password(),
      if (_step == 7) _buildStep7Selfie(),
      if (_step == 8) _buildStep8Biometrics(),
      if (_step == 9) _buildStep9Confirm(),
      if (_error != null) ...[const SizedBox(height: 16), _buildError()],
      const SizedBox(height: 24),
      _buildStepButtons(),
    ]);
  }

  /// Total wizard steps. Each one asks a single thing: a long combined form
  /// reads as a wall and is much harder to resume after an interruption.
  static const int _kTotalSteps = 9;

  static const List<String> _kStepTitles = [
    'Phone',          // 1
    'Verify Code',    // 2
    'Your Name',      // 3
    'Preferred Name', // 4
    'Email',          // 5 (optional, verified in place)
    'Password',       // 6
    'Your Photo',     // 7
    'Biometrics',     // 8
    'Confirm',        // 9
  ];

  Widget _buildStepIndicator() {
    const total = _kTotalSteps;
    const titles = _kStepTitles;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: List.generate(total, (i) {
        final done    = i + 1 < _step;
        final current = i + 1 == _step;
        return Expanded(child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            // Sized from the step count rather than fixed: nine circles at
            // the six-step size overflow a narrow phone.
            width: total > 7 ? 18 : 22,
            height: total > 7 ? 18 : 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done || current
                  ? BrokaColors.gold : BrokaColors.bgCard,
              border: Border.all(
                color: done || current
                    ? BrokaColors.gold : BrokaColors.border,
                width: current ? 2 : 1,
              ),
            ),
            child: Center(
              child: done
                  ? Icon(Icons.check_rounded, color: Colors.white,
                      size: total > 7 ? 10 : 12)
                  : Text('${i + 1}', style: TextStyle(
                      color: current ? Colors.white : BrokaColors.textLow,
                      fontSize: total > 7 ? 9 : 10,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          if (i < total - 1) Expanded(child: Container(
            height: 2,
            color: done ? BrokaColors.gold : BrokaColors.border,
          )),
        ]));
      })),
      const SizedBox(height: 10),
      Text(
          _step == 5 && _emailCodeSent ? 'Verify Email' : titles[_step - 1],
          style: const TextStyle(
          color: BrokaColors.textHigh, fontSize: 20,
          fontWeight: FontWeight.w800, letterSpacing: -0.3)),
      const SizedBox(height: 2),
      Text(_stepSubtitle(), style: const TextStyle(
          color: BrokaColors.textMid, fontSize: 13)),
    ]);
  }

  String _stepSubtitle() {
    switch (_step) {
      case 1: return "We'll text you a code to confirm it's really you";
      case 2: return 'Enter the 6-digit code we sent you';
      case 3: return 'The name on your ID';
      case 4: return 'What should Zeno call you?';
      case 5: return _emailCodeSent
          ? 'Enter the 6-digit code we emailed you'
          : 'Optional, but recommended — for receipts and account recovery';
      case 6: return 'Choose something only you would guess';
      case 7: return 'A selfie so buyers and sellers know they\'re dealing with a real person';
      case 8: return 'Set up BROKA-specific biometric security for payments';
      case 9: return 'Review and activate your account';
      default: return '';
    }
  }

  // Step 1 - Phone number
  Widget _buildStep1Phone() => Column(children: [
    CountryPhoneField(
      controller: _phoneCtrl,
      dialCode: _dialCode,
      onDialCodeChanged: (c) => setState(() => _dialCode = c),
      onChanged: (_) => setState(() {}),
      autofocus: true,
    ),
    const SizedBox(height: 10),
    const Padding(
      padding: EdgeInsets.only(left: 4),
      child: Text(
        "We'll text you a 6-digit code to confirm it's you. No email needed.",
        style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.5),
      ),
    ),
    const SizedBox(height: 16),
    Center(
      child: GestureDetector(
        onTap: _loading ? null : _skipPhoneVerification,
        child: const Text('Skip for now — verify later',
            style: TextStyle(color: BrokaColors.textMid,
                fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    ),
  ]);

  // Step 2 - OTP verification.
  //
  // On Android the code arrives on its own: SmsAutofillService captures the
  // SMS through the SMS Retriever API and writes it straight into the field,
  // with no permission and no "Autofill?" prompt. Typing is the fallback, not
  // the expected path. See services/sms_autofill_service.dart.
  Widget _buildStep2Otp() => Column(children: [
    Row(children: [
      const Icon(Icons.sms_outlined, color: BrokaColors.gold, size: 18),
      const SizedBox(width: 10),
      Expanded(
        // The full number, unmasked. The person reading this screen is the
        // one who just typed it, so hiding digits from them only makes a
        // typo harder to spot.
        child: Text('Code sent to $_fullPhone',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 14)),
      ),
      if (_otpExpiresIn > 0) ...[
        const SizedBox(width: 8),
        const Icon(Icons.schedule_rounded, color: BrokaColors.gold, size: 16),
        const SizedBox(width: 5),
        Text(_fmtMinSec(_otpExpiresIn),
            style: const TextStyle(color: BrokaColors.gold, fontSize: 14,
                fontWeight: FontWeight.w700)),
      ],
    ]),
    const SizedBox(height: 22),
    OtpCodeField(
      controller: _otpCtrl,
      enabled: !_loading,
      onChanged: (_) => setState(() {}),   // clears any stale error as they type
      onCompleted: (_) { if (!_loading) _nextStep(); },
    ),
    const SizedBox(height: 20),
    Center(
      child: _resendCooldown > 0
          ? Text('Resend code in ${_fmtCooldown(_resendCooldown)}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 13))
          : GestureDetector(
              onTap: _loading ? null : _resendOtp,
              child: const Text('Resend code',
                  style: TextStyle(color: BrokaColors.gold,
                      fontSize: 14, fontWeight: FontWeight.w700)),
            ),
    ),
    const SizedBox(height: 14),
    Center(
      child: GestureDetector(
        onTap: _loading ? null : _skipOtpVerification,
        child: const Text('Skip for now — verify later',
            style: TextStyle(color: BrokaColors.textMid,
                fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    ),
  ]);

  // Step 3 - Official name
  Widget _buildStep3Name() => Column(children: [
    _field(_nameCtrl, 'Official Name', Icons.person_outline_rounded,
        autofocus: true, onChanged: (_) => setState(() {})),
    const SizedBox(height: 10),
    const Padding(
      padding: EdgeInsets.only(left: 4),
      child: Text('As it appears on your ID — used for trust & verification',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.5)),
    ),
  ]);

  // Step 4 - Preferred name (optional)
  Widget _buildStep4Nickname() => Column(children: [
    _field(_nicknameCtrl, 'Preferred Name (optional)', Icons.badge_outlined,
        autofocus: true, onChanged: (_) => setState(() {})),
    const SizedBox(height: 10),
    const Padding(
      padding: EdgeInsets.only(left: 4),
      child: Text(
        'This is how Zeno, your AI assistant, will address you. '
        'Leave it blank and Zeno uses your official name.',
        style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.5),
      ),
    ),
    const SizedBox(height: 16),
    Center(
      child: GestureDetector(
        onTap: _loading ? null : () => _animateStep(5),
        child: const Text('Skip — use my official name',
            style: TextStyle(color: BrokaColors.textMid,
                fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    ),
  ]);

  // Step 5 - Email (optional), verified in place.
  //
  // Two phases on one screen rather than two wizard steps: the address and
  // the code that proves it are one task, and someone who skips the address
  // should never see a code screen for it at all.
  Widget _buildStep5Email() =>
      _emailCodeSent ? _buildEmailVerifyPhase() : _buildEmailEntryPhase();

  Widget _buildEmailEntryPhase() => Column(children: [
    _field(_emailCtrl, 'Email (optional)', Icons.alternate_email,
        type: TextInputType.emailAddress, autofocus: true,
        onChanged: (_) => setState(() {})),
    const SizedBox(height: 10),
    const Padding(
      padding: EdgeInsets.only(left: 4),
      child: Text(
        'Recommended. It is how you recover your account if you lose your '
        'phone number, and where your receipts go.',
        style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.5),
      ),
    ),
    // Only worth showing once there is something to skip: with the field
    // empty the primary button already reads "Skip", and two controls doing
    // the same thing side by side just asks the user to pick between them.
    if (_emailCtrl.text.trim().isNotEmpty) ...[
      const SizedBox(height: 16),
      Center(
        child: GestureDetector(
          onTap: _loading ? null : _skipEmail,
          child: const Text('Skip for now — add it later',
              style: TextStyle(color: BrokaColors.textMid,
                  fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ),
    ],
  ]);

  Widget _buildEmailVerifyPhase() => Column(children: [
    Row(children: [
      const Icon(Icons.mark_email_unread_outlined,
          color: BrokaColors.gold, size: 18),
      const SizedBox(width: 10),
      Expanded(
        child: Text('Code sent to ${_emailCtrl.text.trim()}',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 14)),
      ),
      if (_emailOtpExpiresIn > 0) ...[
        const SizedBox(width: 8),
        const Icon(Icons.schedule_rounded, color: BrokaColors.gold, size: 16),
        const SizedBox(width: 5),
        Text(_fmtMinSec(_emailOtpExpiresIn),
            style: const TextStyle(color: BrokaColors.gold, fontSize: 14,
                fontWeight: FontWeight.w700)),
      ],
    ]),
    const SizedBox(height: 22),
    OtpCodeField(
      controller: _emailOtpCtrl,
      enabled: !_loading,
      onChanged: (_) => setState(() {}),
      onCompleted: (_) { if (!_loading) _nextStep(); },
    ),
    const SizedBox(height: 20),
    Center(
      child: _emailResendCooldown > 0
          ? Text('Resend code in ${_fmtCooldown(_emailResendCooldown)}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 13))
          : GestureDetector(
              onTap: _loading ? null : _resendEmailOtp,
              child: const Text('Resend code',
                  style: TextStyle(color: BrokaColors.gold,
                      fontSize: 14, fontWeight: FontWeight.w700)),
            ),
    ),
    const SizedBox(height: 14),
    Center(
      child: GestureDetector(
        onTap: _loading ? null : _changeEmailAddress,
        child: const Text('Use a different email',
            style: TextStyle(color: BrokaColors.textMid,
                fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    ),
    const SizedBox(height: 10),
    Center(
      child: GestureDetector(
        onTap: _loading ? null : _skipEmail,
        child: const Text('Skip for now — add it later',
            style: TextStyle(color: BrokaColors.textMid,
                fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    ),
  ]);

  // Step 6 - Password + confirmation
  Widget _buildStep6Password() => Column(children: [
    _buildPasswordField(),
    const SizedBox(height: 14),
    TextField(
      controller: _confirmPasswordCtrl,
      obscureText: _obscureConfirm,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: BrokaColors.textHigh),
      decoration: InputDecoration(
        labelText: 'Confirm Password',
        prefixIcon: const Icon(Icons.lock_outline_rounded,
            color: BrokaColors.textLow, size: 18),
        suffixIcon: GestureDetector(
          onTap: () => setState(() => _obscureConfirm = !_obscureConfirm),
          child: Icon(_obscureConfirm
              ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: BrokaColors.textLow, size: 18)),
      ),
    ),
    const SizedBox(height: 10),
    Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        _passwordMismatch
            ? 'Both passwords must match'
            : 'At least 6 characters.',
        style: TextStyle(
          color: _passwordMismatch ? BrokaColors.danger : BrokaColors.textLow,
          fontSize: 11,
          height: 1.5,
        ),
      ),
    ),
  ]);

  /// Only true once the confirmation has something in it — nagging about a
  /// mismatch before the second field is touched is just noise.
  bool get _passwordMismatch =>
      _confirmPasswordCtrl.text.isNotEmpty &&
      _passwordCtrl.text != _confirmPasswordCtrl.text;

  // Step 7 - Selfie
  Widget _buildStep7Selfie() => Column(children: [
    GestureDetector(
      onTap: _openSelfie,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            BrokaColors.gold.withOpacity(0.08), BrokaColors.bgCard,
          ]),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _capturedPhoto != null
                ? BrokaColors.gold : BrokaColors.border,
            width: _capturedPhoto != null ? 2 : 1,
          ),
        ),
        child: _capturedPhoto != null
            ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                ClipOval(child: Image.memory(
                    base64Decode(_capturedPhoto!),
                    width: 80, height: 80, fit: BoxFit.cover)),
                const SizedBox(width: 16),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Selfie captured ✓',
                      style: TextStyle(color: BrokaColors.neonGreen,
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text('Tap to retake',
                      style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
                ]),
              ])
            : Column(children: [
                Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: BrokaColors.gold.withOpacity(0.1),
                    border: Border.all(
                        color: BrokaColors.gold.withOpacity(0.4)),
                  ),
                  child: const Icon(Icons.camera_front_rounded,
                      color: BrokaColors.gold, size: 32),
                ),
                const SizedBox(height: 12),
                const Text('Take Profile Selfie',
                    style: TextStyle(color: BrokaColors.textHigh,
                        fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 4),
                const Text('Front camera only - no uploads allowed',
                    style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
              ]),
      ),
    ),
    const SizedBox(height: 16),
    Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.gold.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.2)),
      ),
      child: const Row(children: [
        Icon(Icons.info_outline_rounded, color: BrokaColors.neonBlue, size: 16),
        SizedBox(width: 10),
        Expanded(child: Text(
          'Your selfie is stored securely and shown to other traders '
          'so they know they\'re dealing with a verified real person.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 11, height: 1.5),
        )),
      ]),
    ),
  ]);

  // Step 5 - BROKA Biometrics (fresh live capture)
  Widget _buildStep8Biometrics() => Column(children: [
    // Explanation banner
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BrokaColors.gold.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.shield_rounded, color: BrokaColors.gold, size: 18),
          SizedBox(width: 8),
          Text('BROKA Biometric Security',
              style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 14, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 8),
        const Text(
          'BROKA will capture your biometric LIVE right now - this is '
          'not using stored phone data. Your scan is linked specifically '
          'to your BROKA account and will be required to approve payments.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.6),
        ),
      ]),
    ),
    const SizedBox(height: 20),

    // State 1: Hardware not supported at all
    if (!_biometricAvailable)
      _buildBioInfoBox(
        icon: Icons.phonelink_erase_rounded,
        iconColor: BrokaColors.textLow,
        borderColor: BrokaColors.border,
        title: 'Biometrics not available',
        body: 'This device does not have a fingerprint sensor or Face ID. '
            'You can continue with password security.',
      )

    // State 2: Hardware exists but nothing enrolled in device settings
    else if (!_biometricEnrolled)
      Column(children: [
        _buildBioInfoBox(
          icon: Icons.fingerprint_rounded,
          iconColor: Colors.amber,
          borderColor: Colors.amber.withOpacity(0.4),
          title: 'Biometrics not set up yet',
          body: 'Your phone has a fingerprint sensor but no fingerprints have been registered in your device settings yet. To use BROKA biometrics: 1. Go to Settings > Security > Fingerprint (or Face ID) 2. Register your fingerprint or face 3. Come back here and tap Refresh',
        ),
        const SizedBox(height: 14),
        GestureDetector(
          onTap: () async {
            await _checkBiometrics();
            if (mounted) setState(() {});
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BrokaColors.gold.withOpacity(0.5)),
            ),
            child: const Row(mainAxisAlignment: MainAxisAlignment.center,
                children: [
              Icon(Icons.refresh_rounded,
                  color: BrokaColors.gold, size: 18),
              SizedBox(width: 8),
              Text('Refresh - I have set it up',
                  style: TextStyle(color: BrokaColors.gold,
                      fontWeight: FontWeight.w700, fontSize: 14)),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        _biometricTile(
          type: 'none',
          icon: Icons.lock_outline_rounded,
          title: 'Skip - use password only',
          subtitle: 'You can set up biometrics later in your profile',
          isSkip: true,
        ),
      ])

    // State 3: Hardware present AND biometrics enrolled - show scan options
    else
      Column(children: [
        // IMPORTANT notice about live scan
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: BrokaColors.gold.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: BrokaColors.gold.withOpacity(0.3)),
          ),
          child: const Row(children: [
            Icon(Icons.touch_app_rounded,
                color: BrokaColors.neonBlue, size: 16),
            SizedBox(width: 10),
            Expanded(child: Text(
              'Tap your preferred method below. '
              'You will be prompted to PHYSICALLY scan your finger or face right now.',
              style: TextStyle(color: BrokaColors.textMid,
                  fontSize: 11, height: 1.5),
            )),
          ]),
        ),
        if (_availableTypes.contains(BiometricType.fingerprint) ||
            _availableTypes.contains(BiometricType.strong) ||
            _availableTypes.isEmpty) // show fingerprint if list is empty (some devices)
          _biometricTile(
            type: 'fingerprint',
            icon: Icons.fingerprint_rounded,
            title: 'Scan Fingerprint',
            subtitle: 'Place your finger on the sensor when the prompt appears',
          ),
        const SizedBox(height: 10),
        if (_availableTypes.contains(BiometricType.face))
          _biometricTile(
            type: 'face',
            icon: Icons.face_rounded,
            title: 'Scan Face',
            subtitle: 'Look directly at the camera when prompted',
          ),
        const SizedBox(height: 10),
        _biometricTile(
          type: 'none',
          icon: Icons.lock_outline_rounded,
          title: 'Password Only',
          subtitle: 'Skip biometrics - can be set up later in profile',
          isSkip: true,
        ),
        if (_biometricVerified) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: BrokaColors.neonGreen.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: BrokaColors.neonGreen.withOpacity(0.4)),
            ),
            child: Row(children: [
              const Icon(Icons.verified_rounded,
                  color: BrokaColors.neonGreen, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Text(
                '${_chosenBiometric == "fingerprint" ? "Fingerprint" : "Face"} '
                'successfully captured and registered for BROKA!',
                style: const TextStyle(color: BrokaColors.neonGreen,
                    fontSize: 13, fontWeight: FontWeight.w700),
              )),
            ]),
          ),
        ],
      ]),
  ]);

  Widget _biometricTile({
    required String type,
    required IconData icon,
    required String title,
    required String subtitle,
    bool isSkip = false,
  }) {
    final selected = _chosenBiometric == type;
    final verified = _biometricVerified && selected && !isSkip;
    return GestureDetector(
      onTap: () async {
        if (isSkip) {
          setState(() {
            _chosenBiometric   = 'none';
            _biometricVerified = false;
            _error = null;
          });
        } else {
          await _enrollBiometric(type);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected && !isSkip
              ? BrokaColors.gold.withOpacity(0.1)
              : BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: verified
                ? BrokaColors.neonGreen
                : selected && !isSkip
                    ? BrokaColors.gold
                    : BrokaColors.border,
            width: selected || verified ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSkip
                  ? BrokaColors.bgCard
                  : BrokaColors.gold.withOpacity(0.15),
              border: Border.all(
                color: isSkip
                    ? BrokaColors.border
                    : BrokaColors.gold.withOpacity(0.4)),
            ),
            child: Icon(icon,
                color: isSkip ? BrokaColors.textMid : BrokaColors.gold,
                size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(
                  color: isSkip ? BrokaColors.textMid : BrokaColors.textHigh,
                  fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 11)),
            ],
          )),
          if (!isSkip && _loading && _chosenBiometric == type)
            const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: BrokaColors.gold))
          else if (verified)
            const Icon(Icons.check_circle_rounded,
                color: BrokaColors.neonGreen, size: 22)
          else
            const Icon(Icons.arrow_forward_ios_rounded,
                color: BrokaColors.textLow, size: 14),
        ]),
      ),
    );
  }


  Widget _buildBioInfoBox({
    required IconData icon,
    required Color iconColor,
    required Color borderColor,
    required String title,
    required String body,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: borderColor),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: iconColor, size: 22),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: const TextStyle(
            color: BrokaColors.textHigh,
            fontSize: 14, fontWeight: FontWeight.w700))),
      ]),
      const SizedBox(height: 10),
      Text(body, style: const TextStyle(
          color: BrokaColors.textMid, fontSize: 12, height: 1.6)),
    ]),
  );


  // Step 9 - Confirmation
  Widget _buildStep9Confirm() => Column(children: [
    // Summary card
    Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Account Summary',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        // Selfie preview
        Row(children: [
          ClipOval(child: Image.memory(
              base64Decode(_capturedPhoto!),
              width: 52, height: 52, fit: BoxFit.cover)),
          const SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_nameCtrl.text.trim(),
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontSize: 16, fontWeight: FontWeight.w700)),
              if (_nicknameCtrl.text.isNotEmpty)
                Text('aka ${_nicknameCtrl.text.trim()}',
                    style: const TextStyle(color: BrokaColors.textMid,
                        fontSize: 12)),
            ],
          )),
        ]),
        const SizedBox(height: 14),
        const Divider(color: BrokaColors.border, height: 1),
        const SizedBox(height: 14),
        _summaryRow(Icons.phone_outlined, _fullPhone),
        if (_emailCtrl.text.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          _summaryRow(Icons.email_outlined, _emailCtrl.text.trim()),
        ],
        const SizedBox(height: 8),
        _summaryRow(
          _biometricVerified
              ? (_chosenBiometric == 'fingerprint'
                  ? Icons.fingerprint_rounded : Icons.face_rounded)
              : Icons.lock_outline_rounded,
          _biometricVerified
              ? '${_chosenBiometric == "fingerprint" ? "Fingerprint" : "Face ID"} registered ✓'
              : 'Password security only',
          color: _biometricVerified ? BrokaColors.neonGreen : BrokaColors.textMid,
        ),
      ]),
    ),
    const SizedBox(height: 20),
    GradientButton(
      onPressed: _loading ? null : _submitRegistration,
      child: _loading
          ? const SizedBox(width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Activate Account', style: TextStyle(fontSize: 15,
                  fontWeight: FontWeight.w700, color: Colors.white)),
              SizedBox(width: 8),
              Icon(Icons.rocket_launch_rounded, color: Colors.white, size: 18),
            ]),
    ),
  ]);

  Widget _summaryRow(IconData icon, String value, {Color? color}) =>
    Row(children: [
      Icon(icon, size: 15, color: color ?? BrokaColors.textMid),
      const SizedBox(width: 8),
      Expanded(child: Text(value, style: TextStyle(
          color: color ?? BrokaColors.textMid, fontSize: 13))),
    ]);

  // ── Step navigation buttons ───────────────────────────────────────────────

  String _continueLabel() {
    switch (_step) {
      case 1: return 'Send Code';
      case 2: return 'Verify';
      case 5: return _emailCodeSent
          ? 'Verify'
          : (_emailCtrl.text.trim().isEmpty ? 'Skip' : 'Send Code');
      case 8: return _biometricVerified ? 'Continue' : 'Skip for now';
      default: return 'Continue';
    }
  }

  Widget _buildStepButtons() {
    if (_step == _kTotalSteps) return const SizedBox.shrink(); // final step has its own CTA
    return Row(children: [
      if (_step > 1) ...[
        GestureDetector(
          onTap: _prevStep,
          child: Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: BrokaColors.bgCard.withOpacity(0.55),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.arrow_back_rounded, color: BrokaColors.textMid, size: 20),
              SizedBox(width: 8),
              Text('Back', style: TextStyle(color: BrokaColors.textMid,
                  fontWeight: FontWeight.w600, fontSize: 16)),
            ]),
          ),
        ),
        const SizedBox(width: 12),
      ],
      Expanded(
        child: GradientButton(
          height: 58,
          borderRadius: 16,
          colors: _kCtaGradient,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          onPressed: _loading ? null : _nextStep,
          child: _loading
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text(_continueLabel(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17,
                            fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.arrow_forward_rounded,
                      color: Colors.white, size: 20),
                ]),
        ),
      ),
    ]);
  }

  // ── Shared widgets ────────────────────────────────────────────────────────

  Widget _buildLogo() => Row(children: [
    Container(
      width: 44, height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        boxShadow: const [BrokaColors.glowGold],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Image.asset(
          'assets/images/broka_icon.png',
          fit: BoxFit.cover,
        ),
      ),
    ),
    const SizedBox(width: 12),
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ShaderMask(
        shaderCallback: (b) => const LinearGradient(
            colors: [BrokaColors.gold, BrokaColors.neonBlue])
            .createShader(b),
        child: const Text('BROKA', style: TextStyle(
            fontSize: 22, fontWeight: FontWeight.w900,
            color: Colors.white, letterSpacing: 3)),
      ),
      const Text('INTELLIGENT COMMERCE',
          style: TextStyle(fontSize: 8, letterSpacing: 3,
              color: BrokaColors.textLow, fontWeight: FontWeight.w600)),
    ]),
  ]);

  Widget _buildTabToggle() => Container(
    padding: const EdgeInsets.all(5),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard.withOpacity(0.5),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: BrokaColors.border.withOpacity(0.7)),
    ),
    child: Row(children: [
      _tab('Login',          _isLogin,  () => _switchMode(true)),
      _tab('Create Account', !_isLogin, () => _switchMode(false)),
    ]),
  );

  Widget _buildPasswordField() => TextField(
    controller: _passwordCtrl,
    obscureText: _obscure,
    style: const TextStyle(color: BrokaColors.textHigh),
    decoration: InputDecoration(
      labelText: 'Password',
      prefixIcon: const Icon(Icons.lock_outline_rounded,
          color: BrokaColors.textLow, size: 18),
      suffixIcon: GestureDetector(
        onTap: () => setState(() => _obscure = !_obscure),
        child: Icon(_obscure
            ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: BrokaColors.textLow, size: 18)),
    ),
  );

  Widget _buildBiometricLoginButton() => GestureDetector(
    onTap: _biometricLogin,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.45)),
      ),
      child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.fingerprint, color: BrokaColors.gold, size: 24),
        SizedBox(width: 12),
        Text('Login with biometrics',
            style: TextStyle(color: BrokaColors.gold,
                fontWeight: FontWeight.w600, fontSize: 16)),
      ]),
    ),
  );

  Widget _buildError() => Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: BrokaColors.danger.withOpacity(0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.danger.withOpacity(0.3)),
    ),
    child: Row(children: [
      const Icon(Icons.error_outline, color: BrokaColors.danger, size: 16),
      const SizedBox(width: 10),
      Expanded(child: Text(_error!,
          style: const TextStyle(color: BrokaColors.danger, fontSize: 12))),
    ]),
  );

  Widget _buildDivider() => Row(children: [
    Expanded(child: Container(height: 1,
        color: BrokaColors.border.withOpacity(0.5))),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Text('or', style: TextStyle(
          color: BrokaColors.textLow.withOpacity(0.7), fontSize: 12))),
    Expanded(child: Container(height: 1,
        color: BrokaColors.border.withOpacity(0.5))),
  ]);

  Widget _buildSwitchPrompt() => Center(child: GestureDetector(
    onTap: () => _switchMode(!_isLogin),
    // Text.rich, not RichText: RichText ignores DefaultTextStyle entirely, so
    // this one line was rendering in the platform's default sans while every
    // other string on the screen used the theme's serif.
    child: Text.rich(TextSpan(
      style: const TextStyle(fontSize: 15, color: BrokaColors.textMid),
      children: [
        TextSpan(text: _isLogin ? 'New to BROKA? ' : 'Already a trader? '),
        TextSpan(text: _isLogin ? 'Create account' : 'Sign in',
            style: const TextStyle(color: BrokaColors.gold,
                fontWeight: FontWeight.w700)),
      ],
    )),
  ));

  Widget _tab(String label, bool active, VoidCallback onTap) => Expanded(
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: active ? const LinearGradient(
              colors: _kCtaGradient,
              begin: Alignment.centerLeft, end: Alignment.centerRight) : null,
          borderRadius: BorderRadius.circular(26),
          boxShadow: active ? const [BrokaColors.glowGold] : null,
        ),
        child: Text(label, textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                color: active ? Colors.white : BrokaColors.textMid)),
      ),
    ),
  );

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType type = TextInputType.text,
       bool autofocus = false,
       ValueChanged<String>? onChanged}) =>
    TextField(
      controller: ctrl, keyboardType: type,
      autofocus: autofocus,
      onChanged: onChanged,
      style: const TextStyle(color: BrokaColors.textHigh),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: BrokaColors.textLow, size: 18),
      ),
    );
}
