// BROKA - step-by-step wizard chrome
//
// The look of account signup (lib/screens/auth_screen.dart), shared: the
// glowing constellation behind everything, a progress indicator, a large
// step title with a one-line explanation, the step's own content, an error
// banner, and Back / Continue buttons.
//
// Signup uses the pieces directly (it has its own logo and sign-in toggle
// around them); flows that are only a wizard - store setup - use
// [WizardScaffold], which adds the screen frame. Either way the progress
// bar, header, buttons and error banner are the same widgets, so the two
// flows can't drift apart visually.
import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;
import 'constellation_background.dart';
import 'gradient_button.dart';
import '../core/errors/user_facing_error.dart';

/// Violet into blue: the primary call-to-action gradient of the wizard
/// flows.
const List<Color> kWizardCtaGradient = [Color(0xFF8B5CF6), Color(0xFF3B82F6)];

/// Step progress. Up to ten steps are numbered dots joined by lines; past
/// that the dots get too small to read, so it's a bar with "Step n of m".
class WizardProgress extends StatelessWidget {
  const WizardProgress({super.key, required this.position, required this.total});

  /// 0-based index of the current step; -1 when off the path.
  final int position;
  final int total;

  @override
  Widget build(BuildContext context) =>
      total > 10 ? _bar() : _dots();

  Widget _dots() {
    return Row(children: List.generate(total, (i) {
      final done    = i < position;
      final current = i == position;
      return Expanded(child: Row(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: total > 7 ? 18 : 22,
          height: total > 7 ? 18 : 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done || current ? BrokaColors.gold : BrokaColors.bgCard,
            border: Border.all(
              color: done || current ? BrokaColors.gold : BrokaColors.border,
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
    }));
  }

  Widget _bar() {
    final done = position < 0 ? 0.0 : (position + 1) / total;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('Step ${position + 1} of $total',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12,
                fontWeight: FontWeight.w600)),
        const Spacer(),
        Text('${(done * 100).round()}%',
            style: const TextStyle(color: BrokaColors.gold, fontSize: 12,
                fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(children: [
          Container(height: 6, color: BrokaColors.bgCard),
          LayoutBuilder(builder: (_, c) => AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: 6,
            width: c.maxWidth * done,
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: kWizardCtaGradient),
            ),
          )),
        ]),
      ),
    ]);
  }
}

/// A step's title and its one-line explanation.
class WizardStepHeader extends StatelessWidget {
  const WizardStepHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(
          color: BrokaColors.textHigh, fontSize: 20,
          fontWeight: FontWeight.w800, letterSpacing: -0.3)),
      if (subtitle != null && subtitle!.isNotEmpty) ...[
        const SizedBox(height: 2),
        Text(subtitle!, style: const TextStyle(
            color: BrokaColors.textMid, fontSize: 13)),
      ],
    ]);
  }
}

/// Back (when there is somewhere to go back to) and the gradient Continue
/// button. [onNext] null disables Continue; [loading] shows a spinner in it.
class WizardNavButtons extends StatelessWidget {
  const WizardNavButtons({
    super.key,
    required this.onNext,
    this.onBack,
    this.nextLabel = 'Continue',
    this.nextIcon = Icons.arrow_forward_rounded,
    this.loading = false,
  });

  final VoidCallback? onNext;
  final VoidCallback? onBack;
  final String nextLabel;
  final IconData? nextIcon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      if (onBack != null) ...[
        Semantics(
          button: true,
          label: 'Back',
          child: GestureDetector(
            onTap: loading ? null : onBack,
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
        ),
        const SizedBox(width: 12),
      ],
      Expanded(
        child: GradientButton(
          height: 58,
          borderRadius: 16,
          colors: kWizardCtaGradient,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          onPressed: loading ? null : onNext,
          child: loading
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text(nextLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17,
                            fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                  if (nextIcon != null) ...[
                    const SizedBox(width: 10),
                    Icon(nextIcon, color: Colors.white, size: 20),
                  ],
                ]),
        ),
      ),
    ]);
  }
}

/// The red "something went wrong" box under a step.
class WizardErrorBanner extends StatelessWidget {
  const WizardErrorBanner(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
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
      Expanded(child: Text(sanitizeErrorText(message),
          style: const TextStyle(color: BrokaColors.danger, fontSize: 12))),
    ]),
  );
}

/// A whole wizard screen: constellation background, a top bar with a
/// close button and the flow's name, progress, the step header, the
/// step's content (scrolling), and the buttons pinned under it.
class WizardScaffold extends StatelessWidget {
  const WizardScaffold({
    super.key,
    required this.flowTitle,
    required this.position,
    required this.total,
    required this.title,
    required this.child,
    required this.onNext,
    this.subtitle,
    this.onBack,
    this.onClose,
    this.nextLabel = 'Continue',
    this.nextIcon = Icons.arrow_forward_rounded,
    this.loading = false,
    this.error,
    this.animateBackground = true,
  });

  /// Shown in the top bar, e.g. "Set up your store".
  final String flowTitle;
  final int position;
  final int total;
  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onNext;
  final VoidCallback? onBack;

  /// The top bar's close button. Defaults to popping the route.
  final VoidCallback? onClose;
  final String nextLabel;
  final IconData? nextIcon;
  final bool loading;
  final String? error;

  /// False renders one still frame of the background (tests).
  final bool animateBackground;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: animateBackground,
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 20, 0),
              child: Row(children: [
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid),
                  onPressed: loading
                      ? null
                      : (onClose ?? () => Navigator.of(context).maybePop()),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(flowTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textHigh,
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                WizardProgress(position: position, total: total),
                const SizedBox(height: 14),
                WizardStepHeader(title: title, subtitle: subtitle),
              ]),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                child: child,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (error != null) ...[
                  WizardErrorBanner(error!),
                  const SizedBox(height: 12),
                ],
                WizardNavButtons(
                  onNext: onNext,
                  onBack: onBack,
                  nextLabel: nextLabel,
                  nextIcon: nextIcon,
                  loading: loading,
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
