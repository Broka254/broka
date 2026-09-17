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
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../main.dart';
import '../widgets/gradient_button.dart';
import '../services/api_service.dart';
import '../services/global_poller_service.dart';
import '../widgets/particle_field.dart';

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

  // Phone verification (steps 1-2) — OTP is optional at signup; the user
  // can skip it from either step and verify later from Profile.
  String? _phoneVerifyToken;
  bool   _skippedOtp = false; // true only if Step 2 was never reached (see _prevStep)
  int _resendCooldown = 0;
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

  late AnimationController _bgAnim, _fadeCtrl, _stepAnim;
  late Animation<double>   _fade, _stepFade;

  @override
  void initState() {
    super.initState();
    _bgAnim   = AnimationController(vsync: this,
        duration: const Duration(seconds: 12))..repeat(reverse: true);
    _fadeCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 600))..forward();
    _stepAnim = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 350))..forward();
    _fade     = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _stepFade = CurvedAnimation(parent: _stepAnim, curve: Curves.easeOut);
    _checkBiometrics();
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
    } on PlatformException { /* hardware not supported */ }
  }

  @override
  void dispose() {
    _bgAnim.dispose(); _fadeCtrl.dispose(); _stepAnim.dispose();
    _resendTimer?.cancel();
    _phoneCtrl.dispose(); _otpCtrl.dispose(); _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _nameCtrl.dispose(); _nicknameCtrl.dispose();
    super.dispose();
  }

  void _switchMode(bool toLogin) {
    _resendTimer?.cancel();
    setState(() {
      _isLogin = toLogin;
      _error   = null;
      _step    = 1;
      _otpCtrl.clear();
      _phoneVerifyToken   = null;
      _skippedOtp         = false;
      _resendCooldown     = 0;
      _capturedPhoto      = null;
      _chosenBiometric    = 'none';
      _biometricVerified  = false;
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
      final phone = _phoneCtrl.text.trim();
      if (phone.length < 9) {
        setState(() => _error = 'Please enter a valid phone number'); return;
      }
      setState(() { _loading = true; _error = null; });
      try {
        await ApiService.requestOtp(phone);
        _startResendCooldown();
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
        _phoneVerifyToken = await ApiService.verifyOtp(_phoneCtrl.text.trim(), code);
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
      if (_passwordCtrl.text.length < 6) {
        setState(() => _error = 'Password must be at least 6 characters'); return;
      }
      _animateStep(4);
    } else if (_step == 4) {
      if (_capturedPhoto == null) {
        setState(() => _error = 'Please take a selfie to continue'); return;
      }
      _animateStep(5);
    } else if (_step == 5) {
      // Step 5 (biometrics) is optional - user can skip
      _animateStep(6);
    }
  }

  /// OTP is optional at signup. Called from Step 1 - skips sending an SMS
  /// entirely and goes straight to Step 3. The phone is still required
  /// (it's the account's login identifier either way); only *proving* it
  /// becomes optional. Verification can be finished later from Profile.
  void _skipPhoneVerification() {
    final phone = _phoneCtrl.text.trim();
    if (phone.length < 9) {
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
    // If OTP was skipped from Step 1, Step 2 (code entry) was never shown
    // and no code was ever sent - going "back" from Step 3 must return to
    // Step 1, not to an OTP screen that would wrongly claim a code is on its way.
    if (_step == 3 && _skippedOtp) { _animateStep(1); return; }
    if (_step > 1) _animateStep(_step - 1);
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendCooldown = 30);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _resendCooldown--);
      if (_resendCooldown <= 0) t.cancel();
    });
  }

  Future<void> _resendOtp() async {
    if (_resendCooldown > 0) return;
    setState(() { _loading = true; _error = null; });
    try {
      await ApiService.requestOtp(_phoneCtrl.text.trim());
      _startResendCooldown();
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
    final phone = _phoneCtrl.text.trim();
    if (phone.length < 9) {
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
        phone: _phoneCtrl.text.trim(), password: _passwordCtrl.text);
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
      body: Stack(children: [
        Positioned.fill(child: AnimatedBuilder(
          animation: _bgAnim,
          builder: (_, __) => Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(
                  sin(_bgAnim.value * 2 * pi) * 0.3,
                  cos(_bgAnim.value * 2 * pi) * 0.2 - 0.3,
                ),
                radius: 1.1,
                colors: const [
                  Color(0xFF0A0616), Color(0xFF050310), Color(0xFF03040A),
                ],
              ),
            ),
          ),
        )),
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        FadeTransition(
          opacity: _fade,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  _buildLogo(),
                  const SizedBox(height: 32),
                  _buildTabToggle(),
                  const SizedBox(height: 28),
                  FadeTransition(
                    opacity: _stepFade,
                    child: _isLogin ? _buildLoginForm() : _buildRegisterStep(),
                  ),
                  const SizedBox(height: 24),
                  _buildDivider(),
                  const SizedBox(height: 20),
                  _buildSwitchPrompt(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // ── Login form ────────────────────────────────────────────────────────────

  Widget _buildLoginForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Welcome Back',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800,
              color: BrokaColors.textHigh, letterSpacing: -0.5)),
      const SizedBox(height: 4),
      const Text('Access the AI-powered trading network',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
      const SizedBox(height: 28),
      _field(_phoneCtrl, 'Phone Number', Icons.phone_outlined,
          type: TextInputType.phone),
      const SizedBox(height: 14),
      _buildPasswordField(),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerRight,
        child: Text('Forgot password?',
          style: TextStyle(color: BrokaColors.gold.withOpacity(0.8),
              fontSize: 12, fontWeight: FontWeight.w600))),
      const SizedBox(height: 24),
      if (_error != null) _buildError(),
      GradientButton(
        onPressed: _loading ? null : _submitLogin,
        child: _loading
            ? const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Access Network', style: TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w700, color: Colors.white)),
                SizedBox(width: 8),
                Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 18),
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
      if (_step == 3) _buildStep3BasicInfo(),
      if (_step == 4) _buildStep4Selfie(),
      if (_step == 5) _buildStep5Biometrics(),
      if (_step == 6) _buildStep6Confirm(),
      if (_error != null) ...[const SizedBox(height: 16), _buildError()],
      const SizedBox(height: 24),
      _buildStepButtons(),
    ]);
  }

  Widget _buildStepIndicator() {
    const total = 6;
    final titles = ['Phone', 'Verify Code', 'Basic Info', 'Your Photo', 'Biometrics', 'Confirm'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: List.generate(total, (i) {
        final done    = i + 1 < _step;
        final current = i + 1 == _step;
        return Expanded(child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 22, height: 22,
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
                  ? const Icon(Icons.check_rounded, color: Colors.white, size: 12)
                  : Text('${i + 1}', style: TextStyle(
                      color: current ? Colors.white : BrokaColors.textLow,
                      fontSize: 10, fontWeight: FontWeight.w700)),
            ),
          ),
          if (i < total - 1) Expanded(child: Container(
            height: 2,
            color: done ? BrokaColors.gold : BrokaColors.border,
          )),
        ]));
      })),
      const SizedBox(height: 10),
      Text(titles[_step - 1], style: const TextStyle(
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
      case 3: return 'Tell us who you are';
      case 4: return 'A selfie so buyers and sellers know they\'re dealing with a real person';
      case 5: return 'Set up BROKA-specific biometric security for payments';
      case 6: return 'Review and activate your account';
      default: return '';
    }
  }

  // Step 1 - Phone number
  Widget _buildStep1Phone() => Column(children: [
    _field(_phoneCtrl, 'Phone Number', Icons.phone_outlined,
        type: TextInputType.phone),
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

  // Step 2 - OTP verification (autofilled by the OS where supported)
  Widget _buildStep2Otp() => Column(children: [
    Text('Code sent to ${_phoneCtrl.text.trim()}',
        style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
    const SizedBox(height: 20),
    AutofillGroup(
      child: TextField(
        controller: _otpCtrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 6,
        autofillHints: const [AutofillHints.oneTimeCode],
        style: const TextStyle(color: BrokaColors.textHigh, fontSize: 26,
            fontWeight: FontWeight.w800, letterSpacing: 10),
        decoration: const InputDecoration(
          counterText: '',
          hintText: '------',
          hintStyle: TextStyle(color: BrokaColors.textLow, letterSpacing: 10),
        ),
        onChanged: (v) {
          setState(() {}); // refresh so a stray _error clears as they type
          if (v.trim().length == 6 && !_loading) _nextStep();
        },
      ),
    ),
    const SizedBox(height: 18),
    Center(
      child: _resendCooldown > 0
          ? Text('Resend code in ${_resendCooldown}s',
              style: const TextStyle(color: BrokaColors.textLow, fontSize: 12))
          : GestureDetector(
              onTap: _loading ? null : _resendOtp,
              child: Text('Resend code',
                  style: TextStyle(color: BrokaColors.gold.withOpacity(0.9),
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ),
    ),
    const SizedBox(height: 12),
    Center(
      child: GestureDetector(
        onTap: _loading ? null : _skipOtpVerification,
        child: const Text('Skip for now — verify later',
            style: TextStyle(color: BrokaColors.textMid,
                fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    ),
  ]);

  // Step 3 - Basic info
  Widget _buildStep3BasicInfo() => Column(children: [
    _field(_nameCtrl, 'Official Name', Icons.person_outline_rounded),
    const SizedBox(height: 4),
    const Padding(
      padding: EdgeInsets.only(left: 4, bottom: 10),
      child: Text('As it appears on your ID — used for trust & verification',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
    ),
    _field(_nicknameCtrl, 'Preferred Name (optional)', Icons.badge_outlined),
    const SizedBox(height: 4),
    const Padding(
      padding: EdgeInsets.only(left: 4, bottom: 10),
      child: Text('This is how Zeno will address you',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
    ),
    _field(_emailCtrl, 'Email (optional)', Icons.alternate_email,
        type: TextInputType.emailAddress),
    const SizedBox(height: 14),
    _buildPasswordField(),
  ]);

  // Step 4 - Selfie
  Widget _buildStep4Selfie() => Column(children: [
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
  Widget _buildStep5Biometrics() => Column(children: [
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


  // Step 6 - Confirmation
  Widget _buildStep6Confirm() => Column(children: [
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
        _summaryRow(Icons.phone_outlined, _phoneCtrl.text.trim()),
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
      case 5: return _biometricVerified ? 'Continue' : 'Skip for now';
      default: return 'Continue';
    }
  }

  Widget _buildStepButtons() {
    if (_step == 6) return const SizedBox.shrink(); // step 6 has its own CTA
    return Row(children: [
      if (_step > 1) ...[
        GestureDetector(
          onTap: _prevStep,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.arrow_back_rounded, color: BrokaColors.textMid, size: 18),
              SizedBox(width: 6),
              Text('Back', style: TextStyle(color: BrokaColors.textMid,
                  fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
        const SizedBox(width: 12),
      ],
      Expanded(
        child: GradientButton(
          onPressed: _loading ? null : _nextStep,
          child: _loading
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_continueLabel(),
                      style: const TextStyle(fontSize: 15,
                          fontWeight: FontWeight.w700, color: Colors.white)),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward_rounded,
                      color: Colors.white, size: 18),
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
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(children: [
      _tab('Login',   _isLogin,  () => _switchMode(true)),
      _tab('Sign Up', !_isLogin, () => _switchMode(false)),
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
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.4)),
      ),
      child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.fingerprint, color: BrokaColors.gold, size: 22),
        SizedBox(width: 10),
        Text('Login with Biometrics',
            style: TextStyle(color: BrokaColors.gold,
                fontWeight: FontWeight.w700, fontSize: 15)),
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
    child: RichText(text: TextSpan(
      style: const TextStyle(fontSize: 14, color: BrokaColors.textMid),
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
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          gradient: active ? const LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.goldDim],
              begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
          borderRadius: BorderRadius.circular(12),
          boxShadow: active ? const [BrokaColors.glowGold] : null,
        ),
        child: Text(label, textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                color: active ? Colors.white : BrokaColors.textLow)),
      ),
    ),
  );

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType type = TextInputType.text}) =>
    TextField(
      controller: ctrl, keyboardType: type,
      style: const TextStyle(color: BrokaColors.textHigh),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: BrokaColors.textLow, size: 18),
      ),
    );
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF8B5CF6).withOpacity(0.03)
      ..strokeWidth = 0.5;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }
  @override
  bool shouldRepaint(_) => false;
}
