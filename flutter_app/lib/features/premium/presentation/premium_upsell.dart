// BROKA - what the app does when a premium feature is refused.
//
// The server refuses with a 402 whose detail says why in words ("You've
// used this month's 20 AI cover tries on BROKA Pro. They renew on 12 Oct -
// or move up to Elite for 60 a month.") and which plan would do
// ("upgrade_to"). The words are shown as they are; this sheet only adds
// the way to the plans.
import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';

/// A premium feature's refusal (backend api/domains/premium/entitlements.py).
bool isPlanRefusal(int? statusCode) => statusCode == 402;

/// The plan the refusal suggests, when it says (ApiException.details).
String? upgradeToOf(ApiException e) => e.details?['upgrade_to'] as String?;

/// Shows why, and offers the plans. Resolves true if the user went to see
/// them - what they have left may have changed, so the caller re-checks.
Future<bool> showPremiumUpsell(BuildContext context, {required String message, String? upgradeTo}) async {
  final open = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: BrokaColors.bgCard,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    // Scrollable: the server writes the message, and the ones that say
    // what a feature does for a sale run to several lines - on a short
    // phone an unscrollable column overflowed and cut off the buttons.
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(color: BrokaColors.border, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 18),
          const Icon(Icons.workspace_premium_rounded, color: BrokaColors.gold, size: 44),
          const SizedBox(height: 10),
          const Text('BROKA Premium',
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(message,
              key: const Key('upsell-message'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 13.5, height: 1.4)),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              key: const Key('upsell-see-plans'),
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: BrokaColors.gold,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('See plans', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
            ),
          ),
          TextButton(
            key: const Key('upsell-not-now'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now', style: TextStyle(color: BrokaColors.textMid)),
          ),
        ]),
      ),
    ),
  );
  if (open != true || !context.mounted) return false;
  await Navigator.of(context).pushNamed('/premium', arguments: upgradeTo);
  return true;
}
