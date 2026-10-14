// BROKA — motion system
//
// One place that decides how long things take and how they ease.
//
// The app already runs 76 AnimationControllers across 13 screens, each
// picking its own duration and curve inline. That is not a shortage of
// animation — it is a shortage of agreement. Two cards that fade at 200ms
// and 350ms next to each other read as jank rather than as style, and
// nothing about the motion says "BROKA" because no two pieces of it move
// the same way.
//
// These are the only numbers. Pick the one that matches the SIZE of the
// change, not the screen you happen to be on:
//
//   instant  — state flips the user caused and is watching for (a toggle,
//              a tick changing). Fast enough to feel like causation.
//   quick    — an element entering or leaving within a screen.
//   standard — a screen transition, a sheet, anything that moves far.
//   slow     — ambient, looping, decorative. Never blocks input.
//
// CURVES. easeOutCubic for things arriving (fast, then settles — reads as
// physical), easeInCubic for things leaving (the reverse), and
// easeOutBack ONLY for a deliberate accent. Overshoot everywhere is how an
// interface starts to feel like a toy.

import 'package:flutter/material.dart';

class BrokaMotion {
  const BrokaMotion._();

  static const instant  = Duration(milliseconds: 120);
  static const quick    = Duration(milliseconds: 220);
  static const standard = Duration(milliseconds: 340);
  static const slow     = Duration(milliseconds: 900);

  /// Entering: decelerates into place.
  static const enter = Curves.easeOutCubic;

  /// Leaving: accelerates away.
  static const exit = Curves.easeInCubic;

  /// Accent only — a confirmation, a success state. Not for lists.
  static const accent = Curves.easeOutBack;

  /// Ambient loops (glow, pulse, the constellation background).
  static const ambient = Curves.easeInOut;

  /// Gap between consecutive items in a staggered list.
  ///
  /// 45ms: at 60fps that is under three frames, so eight items finish
  /// within about a third of a second. Larger values look choreographed
  /// on a phone — the user is already reading item one while item six is
  /// still arriving, which reads as slow rather than as polished.
  static const stagger = Duration(milliseconds: 45);

  /// How many items get a stagger before they all animate together.
  ///
  /// Without a cap, item 40 in a grid waits 1.8 seconds to appear. The
  /// effect is for the first screenful; beyond that it is just latency.
  static const maxStaggerIndex = 8;

  /// Respect the OS "reduce motion" setting.
  ///
  /// Not optional politeness: vestibular disorders make large sliding and
  /// scaling transitions genuinely unpleasant, and the platform switch is
  /// how those users say so. Every widget in motion_widgets.dart checks
  /// this and degrades to a plain cut or a fade.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Duration that collapses to nothing when motion is reduced.
  static Duration of(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;
}

/// Shared-axis page transition: the new screen rises and fades in while the
/// old one sinks and fades out, both on the same vertical axis.
///
/// Wired into ThemeData.pageTransitionsTheme, so every `Navigator.push` in
/// the app gets it without touching a single call site. Before this the app
/// used the platform default on every route except three hand-rolled
/// PageRouteBuilders, which is why navigation had no identity of its own.
///
/// Deliberately subtle — 24 logical pixels of travel. A screen transition is
/// punctuation, not a sentence; anything larger competes with the content
/// arriving underneath it.
class BrokaPageTransition extends PageTransitionsBuilder {
  const BrokaPageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (BrokaMotion.reduced(context)) return child;

    final enter = CurvedAnimation(parent: animation, curve: BrokaMotion.enter);
    final leave = CurvedAnimation(
        parent: secondaryAnimation, curve: BrokaMotion.exit);

    return FadeTransition(
      opacity: enter,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.035), end: Offset.zero)
            .animate(enter),
        child: SlideTransition(
          // The outgoing screen moves the opposite way and a third as far,
          // so the two feel connected instead of like two unrelated slides.
          position: Tween(begin: Offset.zero, end: const Offset(0, -0.012))
              .animate(leave),
          child: child,
        ),
      ),
    );
  }
}
