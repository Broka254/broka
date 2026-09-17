import 'package:flutter/material.dart';
import '../services/api_service.dart';

/// Call this before any account-gated action (Sell, talk to Zeno,
/// negotiate/inbox, view/edit profile, upgrade to seller...).
///
/// If the user is already logged in, returns `true` immediately — no UI
/// shown. If not, shows a short "create an account to continue" sheet, and
/// — only if they choose to proceed — pushes the auth screen.
///
/// Returns `true` if the user is authenticated by the end of the call
/// (either already was, or just completed sign-up/login), `false`
/// otherwise. The caller is responsible for resuming the original action
/// when this returns `true` — that's what makes "tap Talk to Zeno → sign up
/// → land straight in the chat" work, instead of dropping back to Home.
Future<bool> requireAuth(BuildContext context, {String reason = 'to continue'}) async {
  if (ApiService.isLoggedIn) return true;

  final wantsToProceed = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _AuthPromptSheet(reason: reason),
  );

  if (wantsToProceed != true) return false;
  if (!context.mounted) return false;

  final authed = await Navigator.pushNamed(context, '/auth');
  return authed == true;
}

class _AuthPromptSheet extends StatelessWidget {
  final String reason;
  const _AuthPromptSheet({required this.reason});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        decoration: BoxDecoration(
          color: const Color(0xFF14181F),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(
              'Create a free account $reason',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Takes less than a minute — just your phone number, a photo, and a password.',
              style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF5B8DEF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now', style: TextStyle(color: Colors.white54)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
