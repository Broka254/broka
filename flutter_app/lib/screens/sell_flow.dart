// The sell wizard's steps, in order, and how to move between them.
//
// One place for the order (2026-09-25 overhaul): each screen used to push
// the next one by name, so inserting a step meant editing its neighbours
// and the "Step n of 7" string in all of them. It also decides where a
// restored draft reopens: Android can kill BROKA whenever the seller is in
// another app (the camera, the gallery, an M-Pesa message), and the draft
// used to reopen at Photos with the rest of the steps to click through
// again. Now it reopens at the step the seller was on - as far as the
// draft is complete, so a restored draft can never skip a step it hasn't
// actually filled in.
import 'package:flutter/material.dart';

import '../services/sell_wizard_data.dart';
import '../utils/handover.dart';
import '../utils/land_size.dart';
import '../utils/price_format.dart';
import '../utils/price_unit.dart';
import 'sell_category_screen.dart';
import 'sell_description_screen.dart';
import 'sell_details_screen.dart';
import 'sell_location_screen.dart';
import 'sell_price_screen.dart';
import 'sell_review_screen.dart';
import 'sell_showcase_screen.dart';
import 'sell_stock_screen.dart';
import 'sell_zeno_alert_screen.dart';

class SellFlow {
  SellFlow._();

  static const photos = 1;
  static const category = 2;
  static const details = 3;
  static const description = 4;
  static const price = 5;
  static const stock = 6;
  static const location = 7;
  static const showcase = 8;
  static const review = 9;
  static const goLive = 10;

  static const titles = <String>[
    'Photos',
    'Category',
    'Details',
    'Description',
    'Price',
    'Stock & delivery',
    'Location',
    'Cover image',
    'Review',
    'Go live',
  ];

  static int get total => titles.length;

  /// How recently a draft must have been saved for its restore to reopen
  /// at the step it was on (SellPhotosScreen). Android kills a
  /// backgrounded app within minutes; a draft older than this was left.
  static const resumeWindow = Duration(minutes: 30);

  static String title(int step) => titles[step - 1];

  static Widget screenFor(int step, SellWizardData data) {
    switch (step) {
      case category:
        return SellCategoryScreen(data: data);
      case details:
        return SellDetailsScreen(data: data);
      case description:
        return SellDescriptionScreen(data: data);
      case price:
        return SellPriceScreen(data: data);
      case stock:
        return SellStockScreen(data: data);
      case location:
        return SellLocationScreen(data: data);
      case showcase:
        return SellShowcaseScreen(data: data);
      case review:
        return SellReviewScreen(data: data);
      case goLive:
        return SellZenoAlertScreen(data: data);
    }
    throw ArgumentError.value(step, 'step', 'Photos is the flow root, not a pushed step');
  }

  /// Opens the step after [from], recording it as the one to resume at.
  static Future<void> next(BuildContext context, SellWizardData data, {required int from}) {
    final to = from + 1;
    data.resumeStep = to;
    data.persist();
    return Navigator.of(context).push(_route(screenFor(to, data)));
  }

  /// A screen inside a step (the Category step's types of item), with the
  /// wizard's own transition.
  static Route<void> stepRoute(Widget page) => _route(page);

  static Route<void> _route(Widget page, {bool instant = false}) => PageRouteBuilder<void>(
        transitionDuration: instant ? Duration.zero : const Duration(milliseconds: 380),
        reverseTransitionDuration: instant ? Duration.zero : const Duration(milliseconds: 300),
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, animation, __, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween(begin: const Offset(0.06, 0), end: Offset.zero).animate(curved),
              child: child,
            ),
          );
        },
      );

  /// Whether everything [step] asks for is filled in.
  static bool isComplete(int step, SellWizardData data) {
    switch (step) {
      case photos:
        return data.verifiedPhotos.isNotEmpty;
      case category:
        return data.categoryId != null &&
            (data.subcategoryId != null || data.category.toLowerCase() == 'other');
      case details:
        return data.name.trim().length >= 3 &&
            (!data.isLand || LandSize.problem(data.attributes) == null);
      case description:
        return data.description.trim().length >= SellWizardData.minDescriptionLength;
      case price:
        final amount = parseKesInput(data.price);
        return amount != null && amount > 0 && amount <= maxListingPriceKes &&
            (data.isAuction || data.priceNegotiable != null);
      case stock:
        final count = int.tryParse(data.quantity);
        return (data.isAuction || (count != null && count >= 1)) &&
            (data.deliveryAvailable != null || !isDeliverableCategory(data.category));
      case location:
        return data.county.trim().isNotEmpty && data.subcounty.trim().isNotEmpty;
    }
    return true;
  }

  /// The step a restored draft reopens at: the one it was on, or the first
  /// step before it that isn't complete.
  static int resumableStep(SellWizardData data) {
    final wanted = data.resumeStep.clamp(photos, goLive);
    for (var step = photos; step < wanted; step++) {
      if (!isComplete(step, data)) return step;
    }
    return wanted;
  }

  /// Rebuilds the wizard's stack up to [resumableStep] on top of the
  /// Photos screen, instantly, so Back still walks through every step.
  static void resume(BuildContext context, SellWizardData data) {
    final target = resumableStep(data);
    data.resumeStep = target;
    _stackTo(context, data, target, animateLast: false);
  }

  /// The step the wizard opens at once Zeno has filled a listing in
  /// (ZenoAutolistScreen): the first one that still needs the seller -
  /// how many, where - or Review when nothing does. Never past Price for
  /// what is usually sold per bag, kg or month: Zeno priced the whole
  /// item, and only the seller knows what one unit is.
  static int stepAfterZeno(SellWizardData data) {
    var target = review;
    for (var step = category; step < review; step++) {
      if (!isComplete(step, data)) {
        target = step;
        break;
      }
    }
    if (target > price && !data.isAuction &&
        PriceUnits.usuallyPerUnit(data.category, data.subcategoryName)) {
      target = price;
    }
    return target;
  }

  /// Opens the wizard at [stepAfterZeno], with every step before it under
  /// it so Back walks through what Zeno wrote - the seller sees and can
  /// change all of it before Go live.
  static void openAfterZeno(BuildContext context, SellWizardData data) {
    final target = stepAfterZeno(data);
    data.resumeStep = target;
    data.persist();
    _stackTo(context, data, target, animateLast: true);
  }

  static void _stackTo(BuildContext context, SellWizardData data, int target,
      {required bool animateLast}) {
    final navigator = Navigator.of(context);
    for (var step = category; step <= target; step++) {
      navigator.push(_route(screenFor(step, data), instant: !(animateLast && step == target)));
    }
  }
}
