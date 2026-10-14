import 'package:flutter/material.dart';
import '../main.dart' show BrokaColors;
import '../services/api_service.dart';
import '../widgets/constellation_background.dart';
import '../widgets/zeno_avatar.dart';

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
    // Home dims behind it the way Zeno's screens do, not to a flat grey.
    barrierColor: Colors.black.withOpacity(0.62),
    isScrollControlled: true,
    builder: (_) => _AuthPromptSheet(reason: reason),
  );

  if (wantsToProceed != true) return false;
  if (!context.mounted) return false;

  final authed = await Navigator.pushNamed(context, '/auth');
  return authed == true;
}

/// The sheet, drawn in Home's own language (2026-10-14).
///
/// It was a flat grey card (0xFF14181F) with a flat blue (0xFF5B8DEF) button -
/// two colours that exist nowhere else in BROKA, over a Home whose every
/// other surface is the violet-to-blue sky, glass cards edged in neon blue
/// and gradient buttons. So it read as a system dialog dropped on the app.
/// Now: the same constellation sky as Home and Zeno's screens, the same
/// blue-edged panel as Home's "Need my help?" card, the brand gradient on
/// the one button that matters, and a badge for what is being unlocked.
class _AuthPromptSheet extends StatelessWidget {
  final String reason;
  const _AuthPromptSheet({required this.reason});

  /// What the account opens, as a picture: Zeno's face for Zeno, otherwise
  /// the brand gradient with an icon - from the same words the callers
  /// pass as [reason] ("to see your messages", "to sell something"...).
  Widget _badge() {
    final r = reason.toLowerCase();
    if (r.contains('zeno')) return const ZenoAvatar(size: 54, glow: true);
    final icon = r.contains('message')
        ? Icons.chat_bubble_rounded
        : r.contains('sell')
            ? Icons.sell_rounded
            : r.contains('menu')
                ? Icons.grid_view_rounded
                : Icons.person_add_alt_1_rounded;
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [BrokaColors.neonPurple, BrokaColors.neonBlue],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.45), blurRadius: 18)],
      ),
      child: Icon(icon, color: Colors.white, size: 27),
    );
  }

  @override
  Widget build(BuildContext context) {
    const radius = 26.0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.40)),
            boxShadow: [
              BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.16), blurRadius: 28, spreadRadius: 1),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius - 1),
            // The sky sits behind the content and is sized by it: handed the
            // sheet's unbounded height directly, its expanding Stack would
            // have nothing to expand to.
            child: Stack(children: [
              const Positioned.fill(
                child: ConstellationBackground(animate: false, child: SizedBox.shrink()),
              ),
              // Zeno's violet washing down from the top, as on its screens.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.7, -1.0),
                        radius: 1.3,
                        colors: [BrokaColors.neonPurple.withOpacity(0.22), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: BrokaColors.neonBlue.withOpacity(0.38),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(children: [
                      _badge(),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            const TextSpan(text: 'Create a free account '),
                            TextSpan(
                              text: reason,
                              style: const TextStyle(color: BrokaColors.neonCyan),
                            ),
                          ]),
                          style: const TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 20,
                            height: 1.22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    const Text(
                      'Takes less than a minute. All it needs:',
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 14, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    const Wrap(spacing: 8, runSpacing: 8, children: [
                      _StepChip(icon: Icons.phone_iphone_rounded, label: 'Your phone number'),
                      _StepChip(icon: Icons.photo_camera_rounded, label: 'A photo'),
                      _StepChip(icon: Icons.lock_rounded, label: 'A password'),
                    ]),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: const LinearGradient(
                            colors: [BrokaColors.neonPurple, BrokaColors.neonBlue],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                                color: BrokaColors.neonBlue.withOpacity(0.40), blurRadius: 20, spreadRadius: 1),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            key: const Key('auth-gate-continue'),
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => Navigator.pop(context, true),
                            child: const Center(
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Text('Continue',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.6)),
                                SizedBox(width: 8),
                                Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        key: const Key('auth-gate-not-now'),
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Not now',
                            style: TextStyle(color: BrokaColors.textMid, fontSize: 15)),
                      ),
                    ),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One thing the sign-up asks for, as Home's small blue-edged pills.
class _StepChip extends StatelessWidget {
  const _StepChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.86),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.38)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: BrokaColors.neonCyan),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
}
