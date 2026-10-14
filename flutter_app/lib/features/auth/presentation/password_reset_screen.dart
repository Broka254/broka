// Forgotten password: the account's phone number, the SMS code sent to it,
// then a new password.
//
// The login screen's "Forgot password?" was a label that did nothing, so a
// forgotten password meant a lost account. The number is the account, so a
// code texted to it is the proof: POST /auth/password/forgot sends it,
// /forgot/verify swaps the right code for a short-lived reset token, and
// /reset spends that token on the new password and signs this phone in
// (every other phone on the account is signed out).
//
// Also reached from Settings > Change password, for someone signed in who
// has forgotten the current one - with the number fixed to the account's.
//
// Says how it went before it closes (2026-10-09). It used to pop the moment
// the server answered: from the login screen that landed someone on Home
// with no word that their password had changed, and a failure at the last
// step read like any other error. Now a fourth screen says "Password
// reset"; a refusal says the password was not changed, and why; and an
// answer that never arrived says so, rather than guessing either way.
//
// Pops with true once the new password is set and this phone is signed in.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../services/sms_autofill_service.dart';
import '../../../widgets/country_phone_field.dart';
import '../../../widgets/otp_code_field.dart';
import '../../../widgets/wizard_scaffold.dart';

/// Splits "+254712345678" into a dial code the picker knows and the rest.
/// A number with no known dial code is left whole under the default.
(String dialCode, String local) splitPhone(String? e164) {
  final p = (e164 ?? '').trim();
  for (final c in kPhoneCountries) {
    if (p.startsWith(c.dialCode)) return (c.dialCode, p.substring(c.dialCode.length));
  }
  return (kPhoneCountries.first.dialCode, p);
}

class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({
    super.key,
    this.phone,
    this.lockPhone = false,
    this.animateBackground = true,
  });

  /// The number to start from, E.164: what was typed on the login screen,
  /// or the signed-in account's.
  final String? phone;

  /// True when signed in: the code goes to the account's own number, and
  /// that is not something to edit here.
  final bool lockPhone;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  static const _sPhone = 0;
  static const _sCode = 1;
  static const _sPassword = 2;
  static const _sDone = 3;

  static const _resendWait = 60;

  int _step = _sPhone;
  bool _loading = false;
  String? _error;

  late String _dialCode;
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;

  String? _resetToken;
  String? _appSignature;
  StreamSubscription<String>? _smsSub;
  Timer? _resendTimer;
  int _resendIn = 0;

  String get _fullPhone => composeE164(_dialCode, _phoneCtrl.text);
  String get _phoneDigits => _phoneCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');

  @override
  void initState() {
    super.initState();
    final (dial, local) = splitPhone(widget.phone);
    _dialCode = dial;
    _phoneCtrl.text = local;
    // Asked ahead, as signup does: a code requested without it comes in a
    // plain SMS the retriever can never match.
    SmsAutofillService.appSignature().then((sig) {
      if (mounted) _appSignature = sig;
    });
  }

  @override
  void dispose() {
    _smsSub?.cancel();
    SmsAutofillService.stop();
    _resendTimer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  String _reason(Object e) => e is ApiException
      ? e.message
      : "Couldn't reach BROKA. Check your connection and try again.";

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = _reason(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Steps ──────────────────────────────────────────────────────────────────

  void _next() {
    switch (_step) {
      case _sPhone:
        if (_phoneDigits.length < 9) {
          setState(() => _error = 'Enter the phone number you signed up with');
          return;
        }
        _run(() async {
          await _sendCode();
          if (mounted) setState(() => _step = _sCode);
        });
      case _sCode:
        if (_codeCtrl.text.trim().length < 6) {
          setState(() => _error = 'Enter the 6-digit code we texted you');
          return;
        }
        _run(() async {
          final token = await ApiService.verifyPasswordReset(_fullPhone, _codeCtrl.text.trim());
          if (!mounted) return;
          setState(() {
            _resetToken = token;
            _step = _sPassword;
          });
        });
      case _sPassword:
        if (_passwordCtrl.text.length < 6) {
          setState(() => _error = 'Password must be at least 6 characters');
          return;
        }
        if (_passwordCtrl.text != _confirmCtrl.text) {
          setState(() => _error = 'Both passwords must match');
          return;
        }
        _saveNewPassword();
      case _sDone:
        _finish();
    }
  }

  Future<void> _saveNewPassword() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ApiService.resetPassword(resetToken: _resetToken!, newPassword: _passwordCtrl.text);
      if (!mounted) return;
      _passwordCtrl.clear();
      _confirmCtrl.clear();
      setState(() => _step = _sDone);
    } on ApiException catch (e) {
      if (!mounted) return;
      // A 4xx is the server refusing: nothing was changed. Anything else
      // (a 5xx, a timeout) may have been saved before the answer was lost.
      setState(() => _error = e.statusCode < 500
          ? 'Your password was not changed. ${e.message}'
          : _unconfirmed);
    } catch (_) {
      if (mounted) setState(() => _error = _unconfirmed);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static const _unconfirmed = "We couldn't confirm your new password was saved. Try signing in "
      "with it - if that doesn't work, your old password still stands: request a new code.";

  /// Back on the screen it came from, signed in with the new password.
  void _finish() => Navigator.pop(context, true);

  void _back() {
    setState(() {
      _error = null;
      if (_step == _sCode) {
        _codeCtrl.clear();
        _step = _sPhone;
      } else if (_step == _sPassword) {
        // The code is spent; a new password needs a new one.
        _codeCtrl.clear();
        _resetToken = null;
        _step = _sCode;
      }
    });
  }

  /// Arms automatic capture BEFORE asking for the code: arming covers one
  /// message, and the SMS can beat the response back.
  Future<void> _sendCode() async {
    await SmsAutofillService.start();
    _smsSub ??= SmsAutofillService.codes().listen((code) {
      if (mounted && _step == _sCode && !_loading) _codeCtrl.text = code;
    });
    _appSignature ??= await SmsAutofillService.appSignature();
    await ApiService.requestPasswordReset(_fullPhone, appSignature: _appSignature);
    _codeCtrl.clear();
    _startResendWait();
  }

  void _startResendWait() {
    _resendTimer?.cancel();
    setState(() => _resendIn = _resendWait);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final done = _step == _sDone;
    final (title, subtitle) = switch (_step) {
      _sPhone => ('Reset your password', "We'll text a code to the number on your account"),
      _sCode => ('Enter the code', 'It proves this number is yours'),
      _sPassword => ('Choose a new password', 'At least 6 characters. Other phones will be signed out.'),
      _ => ('Password reset', 'Your new password is saved'),
    };
    // Done, every way out - Continue, the close button, the back gesture -
    // returns signed in.
    return PopScope(
      canPop: !done,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && done) _finish();
      },
      child: WizardScaffold(
        flowTitle: 'Forgot password',
        position: done ? _sPassword : _step,
        total: 3,
        title: title,
        subtitle: subtitle,
        onNext: _next,
        onBack: _step == _sPhone || done ? null : _back,
        onClose: done ? _finish : null,
        nextLabel: switch (_step) {
          _sPhone => 'Send code',
          _sCode => 'Verify',
          _sPassword => 'Save password',
          _ => 'Continue',
        },
        nextIcon: done ? Icons.check_rounded : Icons.arrow_forward_rounded,
        loading: _loading,
        error: _error,
        animateBackground: widget.animateBackground,
        child: switch (_step) {
          _sPhone => _phoneStep(),
          _sCode => _codeStep(),
          _sPassword => _passwordStep(),
          _ => _doneStep(),
        },
      ),
    );
  }

  Widget _doneStep() => Container(
        key: const Key('reset-done'),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: BrokaColors.success.withOpacity(0.10),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.success.withOpacity(0.45)),
        ),
        child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.check_circle_rounded, color: BrokaColors.success, size: 30),
          SizedBox(width: 14),
          Expanded(
            child: Text(
              "You're signed in with your new password. Any other phone that was signed "
              'in to your account has been signed out.',
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 14, height: 1.5),
            ),
          ),
        ]),
      );

  Widget _phoneStep() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CountryPhoneField(
          key: const Key('reset-phone'),
          controller: _phoneCtrl,
          dialCode: _dialCode,
          enabled: !widget.lockPhone && !_loading,
          autofocus: !widget.lockPhone && _phoneCtrl.text.isEmpty,
          onDialCodeChanged: (c) => setState(() => _dialCode = c),
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 10),
        const Text(
          'Use the number you signed up with. Standard SMS rates may apply.',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5, height: 1.5),
        ),
      ]);

  Widget _codeStep() => Column(children: [
        Row(children: [
          const Icon(Icons.sms_outlined, color: BrokaColors.gold, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Code sent to $_fullPhone',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 14)),
          ),
        ]),
        const SizedBox(height: 22),
        OtpCodeField(
          key: const Key('reset-code'),
          controller: _codeCtrl,
          enabled: !_loading,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onCompleted: (_) {
            if (!_loading) _next();
          },
        ),
        const SizedBox(height: 20),
        Center(
          child: _resendIn > 0
              ? Text('Resend code in ${_resendIn}s',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 13))
              : TextButton(
                  onPressed: _loading ? null : () => _run(_sendCode),
                  child: const Text('Resend code',
                      style: TextStyle(color: BrokaColors.gold,
                          fontSize: 14, fontWeight: FontWeight.w700)),
                ),
        ),
      ]);

  Widget _passwordStep() => Column(children: [
        _passwordField(_passwordCtrl, 'New password', const Key('reset-new-password')),
        const SizedBox(height: 14),
        _passwordField(_confirmCtrl, 'Confirm new password', const Key('reset-confirm-password')),
      ]);

  Widget _passwordField(TextEditingController ctrl, String label, Key key) => TextField(
        key: key,
        controller: ctrl,
        obscureText: _obscure,
        enabled: !_loading,
        autofillHints: const [AutofillHints.newPassword],
        style: const TextStyle(color: BrokaColors.textHigh),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.lock_outline_rounded, color: BrokaColors.textLow, size: 18),
          suffixIcon: IconButton(
            tooltip: _obscure ? 'Show password' : 'Hide password',
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                color: BrokaColors.textLow, size: 18),
          ),
        ),
      );
}
