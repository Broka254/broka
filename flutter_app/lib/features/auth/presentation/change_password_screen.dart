// Settings > Change password: the current password, then a new one.
//
// There was no way to change a password at all. POST /auth/password/change
// checks the current one, sets the new one, signs every other phone on the
// account out and gives this phone a fresh session. Someone who no longer
// knows the current password resets it with an SMS code to the account's
// number instead (PasswordResetScreen).
//
// Pops with true once the password is changed.
import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/gradient_button.dart';
import '../../../widgets/wizard_scaffold.dart';
import 'password_reset_screen.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    String? problem;
    if (_currentCtrl.text.isEmpty) {
      problem = 'Enter your current password';
    } else if (_newCtrl.text.length < 6) {
      problem = 'Your new password must be at least 6 characters';
    } else if (_newCtrl.text != _confirmCtrl.text) {
      problem = 'Both new passwords must match';
    } else if (_newCtrl.text == _currentCtrl.text) {
      problem = 'Choose a password different from your current one';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiService.changePassword(
          currentPassword: _currentCtrl.text, newPassword: _newCtrl.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException
            ? e.message
            : "Couldn't reach BROKA, so your password wasn't changed. Try again when you're online.");
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _forgotCurrent() async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PasswordResetScreen(
        phone: ApiService.currentUserPhone,
        lockPhone: ApiService.currentUserPhone != null,
        animateBackground: widget.animateBackground,
      ),
    ));
    if (done == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 20, 0),
              child: Row(children: [
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: BrokaColors.textHigh, size: 19),
                  onPressed: _saving ? null : () => Navigator.maybePop(context),
                ),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text('Change password',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: BrokaColors.textHigh,
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const WizardStepHeader(
                    title: 'Choose a new password',
                    subtitle: 'Every other phone signed in to your account will be signed out.',
                  ),
                  const SizedBox(height: 22),
                  _field(_currentCtrl, 'Current password', const Key('change-current'),
                      AutofillHints.password),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const Key('change-forgot'),
                      onPressed: _saving ? null : _forgotCurrent,
                      child: const Text('Forgot it? Reset with an SMS code',
                          style: TextStyle(color: BrokaColors.gold,
                              fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  _field(_newCtrl, 'New password', const Key('change-new'),
                      AutofillHints.newPassword),
                  const SizedBox(height: 14),
                  _field(_confirmCtrl, 'Confirm new password', const Key('change-confirm'),
                      AutofillHints.newPassword),
                  const SizedBox(height: 22),
                  if (_error != null) ...[
                    WizardErrorBanner(_error!),
                    const SizedBox(height: 12),
                  ],
                  GradientButton(
                    key: const Key('change-save'),
                    height: 58,
                    borderRadius: 16,
                    colors: kWizardCtaGradient,
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Save new password',
                            style: TextStyle(fontSize: 17,
                                fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, Key key, String hint) => TextField(
        key: key,
        controller: ctrl,
        obscureText: _obscure,
        enabled: !_saving,
        autofillHints: [hint],
        style: const TextStyle(color: BrokaColors.textHigh),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.lock_outline_rounded, color: BrokaColors.textLow, size: 18),
          suffixIcon: IconButton(
            tooltip: _obscure ? 'Show passwords' : 'Hide passwords',
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                color: BrokaColors.textLow, size: 18),
          ),
        ),
      );
}
