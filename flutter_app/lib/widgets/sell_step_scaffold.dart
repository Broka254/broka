// BROKA - Sell Wizard Step Scaffold
//
// Shared chrome for every screen in the multi-step "new listing" flow
// (Photos -> Basics -> Description -> Price -> Location -> Review) -
// back button, "NEW LISTING" title + step progress, scrollable body,
// optional banner/error, and the bottom action button. Each step screen
// owns its own fields; this just keeps the surrounding frame identical
// and in one place instead of duplicated six times.
import 'package:flutter/material.dart';
import '../main.dart';
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
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: BrokaColors.headerGradColors,
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: BrokaColors.bgCard,
                    border: Border.all(color: BrokaColors.border),
                  ),
                  child: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: BrokaColors.textMid, size: 16),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('NEW LISTING', style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800,
                      color: BrokaColors.textHigh)),
                  const SizedBox(height: 2),
                  Text('Step $step of $totalSteps · $title', style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600,
                      color: BrokaColors.textLow)),
                ],
              )),
            ]),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: step / totalSteps,
                minHeight: 4,
                backgroundColor: BrokaColors.border,
                valueColor: const AlwaysStoppedAnimation<Color>(BrokaColors.gold),
              ),
            ),
          ),

          if (topBanner != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: topBanner,
            ),

          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: child,
          )),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(children: [
              if (error != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(12),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: BrokaColors.danger.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: BrokaColors.danger.withOpacity(0.3)),
                  ),
                  child: Text(error!,
                      style: const TextStyle(color: BrokaColors.danger, fontSize: 12)),
                ),
              GradientButton(
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
    );
  }
}

Widget sellStepLabel(String text) => Text(text,
    style: const TextStyle(
        color: BrokaColors.textLow,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2));
