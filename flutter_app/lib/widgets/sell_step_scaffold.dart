// BROKA - Sell Wizard Step Scaffold
//
// Shared chrome for every screen in the multi-step "new listing" flow
// (sell_flow.dart has the steps) - back button, "NEW LISTING" title + step
// progress, scrollable body, optional banner/error, and the bottom action
// button. Each step screen owns its own fields; this keeps the surrounding
// frame identical and in one place.
//
// 2026-09-25: the backdrop is Home's glowing ConstellationBackground, so
// listing an item reads as part of the same app rather than a flat form
// bolted onto it. It stands still when the phone asks for reduced motion
// (MediaQuery.disableAnimations) - an ambient loop is decoration, and
// some people get motion-sick from exactly that.
//
// 2026-10-08:
//   * Back always leads somewhere. A step that is the app's only screen
//     (as Photos was when the splash screen reopened a saved draft) had
//     nothing under it, so Back - the button and Android's - did nothing,
//     and a seller could only go forward. There it now goes Home.
//   * One spacing rhythm for every step (SellGap), and more air around the
//     subtitle and banners: sellers found the steps cramped.
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/sell_wizard_data.dart';
import 'constellation_background.dart';
import 'gradient_button.dart';

class SellStepScaffold extends StatelessWidget {
  final int step;
  final int totalSteps;
  final String title;
  final Widget child;
  final VoidCallback? onNext;
  final String nextLabel;
  final bool loading;
  final String? error;
  final Widget? topBanner;

  /// One line under the title saying what this step is for.
  final String? subtitle;

  /// The draft this step edits. When given, going Back records the step
  /// the seller returned to, so a restored draft reopens there.
  final SellWizardData? data;

  /// Replaces the NEXT button (the final step draws its own).
  final Widget? bottom;

  /// The step a restored draft reopens at after Back leaves this screen:
  /// the one before it, unless a step has two screens (Category, then the
  /// type of item) and Back stays within it.
  final int? resumeOnBack;

  const SellStepScaffold({
    super.key,
    required this.step,
    required this.totalSteps,
    required this.title,
    required this.child,
    required this.onNext,
    this.nextLabel = 'NEXT',
    this.loading = false,
    this.error,
    this.topBanner,
    this.subtitle,
    this.data,
    this.bottom,
    this.resumeOnBack,
  });

  /// Nothing under this step: Back goes Home instead of nowhere.
  static void _home(BuildContext context) =>
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);

  void _back(BuildContext context) {
    if (loading) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isFirst) {
      _home(context);
      return;
    }
    Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final isFirst = ModalRoute.of(context)?.isFirst ?? false;
    return PopScope(
      // The app's only screen must not close the app on Android's Back:
      // it goes Home (onPopInvokedWithResult) like the button does.
      canPop: !loading && !isFirst,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (isFirst && !loading) _home(context);
          return;
        }
        final draft = data;
        if (draft == null || step <= 1) return;
        draft.resumeStep = resumeOnBack ?? step - 1;
        draft.persist();
      },
      child: Scaffold(
        backgroundColor: BrokaColors.bg,
        body: ConstellationBackground(
          animate: !still,
          child: SafeArea(child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Row(children: [
                Semantics(
                  button: true,
                  label: isFirst ? 'Back to Home' : 'Back',
                  child: GestureDetector(
                    key: const Key('sell-back'),
                    onTap: loading ? null : () => _back(context),
                    child: Container(
                      width: 42, height: 42,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: BrokaColors.bgCard.withOpacity(0.7),
                        border: Border.all(color: BrokaColors.border),
                      ),
                      child: const Icon(Icons.arrow_back_ios_new_rounded,
                          color: BrokaColors.textMid, size: 16),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('NEW LISTING', style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.6,
                        color: BrokaColors.gold)),
                    const SizedBox(height: 2),
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w800,
                            color: BrokaColors.textHigh, letterSpacing: -0.2)),
                  ],
                )),
                _StepBadge(step: step, total: totalSteps),
              ]),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _GlowProgress(fraction: step / totalSteps, animate: !still),
            ),

            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(subtitle!, style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 13, height: 1.5)),
                ),
              ),

            if (topBanner != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: topBanner,
              ),

            Expanded(child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 32),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: child,
            )),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(12),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: BrokaColors.danger.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: BrokaColors.danger.withOpacity(0.35)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.error_outline_rounded, color: BrokaColors.danger, size: 16),
                      const SizedBox(width: 8),
                      Expanded(child: Text(error!,
                          style: const TextStyle(color: BrokaColors.danger, fontSize: 12))),
                    ]),
                  ),
                bottom ?? GradientButton(
                  onPressed: loading ? null : onNext,
                  child: loading
                      ? const SizedBox(
                          width: 22, height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(nextLabel,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ])),
        ),
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.step, required this.total});
  final int step;
  final int total;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: BrokaColors.gold.withOpacity(0.12),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.35)),
        ),
        child: Text('$step / $total', style: const TextStyle(
            color: BrokaColors.textHigh, fontSize: 11.5, fontWeight: FontWeight.w800)),
      );
}

/// The step progress: a violet-to-blue bar that grows from where the
/// previous step left it, with a soft glow at its leading edge.
class _GlowProgress extends StatelessWidget {
  const _GlowProgress({required this.fraction, required this.animate});
  final double fraction;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? (fraction - 0.1).clamp(0.0, 1.0) : fraction, end: fraction),
      duration: animate ? const Duration(milliseconds: 650) : Duration.zero,
      curve: Curves.easeOutCubic,
      builder: (_, value, __) => LayoutBuilder(builder: (_, c) => Stack(children: [
        Container(
          height: 5,
          decoration: BoxDecoration(
            color: BrokaColors.border.withOpacity(0.8),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        Container(
          height: 5,
          width: c.maxWidth * value,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
            boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.55), blurRadius: 10)],
          ),
        ),
      ])),
    );
  }
}

Widget sellStepLabel(String text) => Text(text,
    style: const TextStyle(
        color: BrokaColors.textMid,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.3));

/// The sell wizard's vertical rhythm (2026-10-08): the same gaps on every
/// step, so a section reads as a section and a label stays with its field.
class SellGap {
  SellGap._();

  /// Between sections of a step: a card and the next label, two questions.
  static const section = SizedBox(height: 28);

  /// Between a section's label and what it labels.
  static const label = SizedBox(height: 12);

  /// Between items of one list, or a field and its hint.
  static const item = SizedBox(height: 12);
}

/// A frosted card for grouping a step's fields over the constellation.
class SellCard extends StatelessWidget {
  const SellCard({super.key, required this.child, this.padding = const EdgeInsets.all(16),
      this.highlight = false});
  final Widget child;
  final EdgeInsets padding;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.72),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: highlight ? BrokaColors.gold.withOpacity(0.6) : BrokaColors.border),
          boxShadow: highlight ? [BrokaColors.glowGold] : null,
        ),
        child: child,
      );
}

/// Two-or-more big choice cards (Fixed price / Open to offers; delivery
/// yes / no). [selected] null means not answered yet.
class SellChoiceCard extends StatelessWidget {
  const SellChoiceCard({
    super.key,
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.accent = BrokaColors.gold,
  });
  final String emoji;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: title,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: selected
                ? LinearGradient(colors: [accent.withOpacity(0.28), BrokaColors.bgCard.withOpacity(0.85)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight)
                : null,
            color: selected ? null : BrokaColors.bgCard.withOpacity(0.72),
            border: Border.all(color: selected ? accent : BrokaColors.border, width: selected ? 1.6 : 1),
            boxShadow: selected ? [BoxShadow(color: accent.withOpacity(0.35), blurRadius: 18)] : null,
          ),
          child: Row(children: [
            AnimatedScale(
              scale: selected ? 1.12 : 1,
              duration: const Duration(milliseconds: 220),
              child: Text(emoji, style: const TextStyle(fontSize: 26)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(
                  color: selected ? Colors.white : BrokaColors.textHigh,
                  fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(subtitle, style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 11.5, height: 1.35)),
            ])),
            const SizedBox(width: 8),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 22, height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? accent : Colors.transparent,
                border: Border.all(color: selected ? accent : BrokaColors.textMid, width: 1.5),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                  : null,
            ),
          ]),
        ),
      ),
    );
  }
}
