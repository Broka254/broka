// Doing what Zeno said it would.
//
// Every action here is something the user could have done with a tap or two
// - open a screen, search, open a chat - except calls, and a call goes
// through exactly the path the negotiation room's call button uses:
// ApiService.initiateCall, then the VoIP screen. There is still only one
// place in the app that can ring a phone (ZENO_ACTIONS.md), and it is only
// reached from a confirmation the user tapped: the assistant's screens call
// [call] from a button, never from a reply.
//
// Everything here works from a NavigatorState as well as a BuildContext:
// Zeno's session (zeno_session.dart) lives above the Navigator, where
// there is no route context to look one up from.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../screens/listing_search_screen.dart';
import '../../screens/zeno_screen.dart';
import '../../services/api_service.dart';
import '../../services/notification_service.dart';
import '../safe_payment/payments_shown.dart';
import 'domain/zeno_action.dart';

class ZenoActionRunner {
  const ZenoActionRunner._();

  /// Screen id -> named route, for the screens that have one. 'home',
  /// 'search' and 'buying_agent' are handled in [run].
  static const routes = <String, String>{
    'inbox': '/inbox',
    'sell': '/sell',
    'menu': '/menu',
    'profile': '/profile',
    'settings': '/settings',
    'seller_dashboard': '/seller-dashboard',
    'deal_history': '/deal-history',
    'verify': '/verify',
    'market_insights': '/zeno-insights',
    'how_broka_works': '/how-broka-works',
    // sellerDashboardOrSetup's own gate decides what a non-business seller
    // sees; /store-setup asks the business questions first (main.dart).
    'store_setup': '/store-setup',
    'my_store': '/store-manage',
    'start_selling': '/start-selling',
    'escrow_services': '/escrow-services',
  };

  /// Screens that lead to a payment: not opened while payments are hidden
  /// (payments_shown.dart), whatever Zeno - or an older server - names.
  static const paymentDestinations = {'verify', 'escrow_services', 'deal_history'};

  /// What the action chip says while it happens.
  static String label(ZenoAction a) => switch (a.type) {
        ZenoActionType.navigate => 'Opening ${kZenoDestinations[a.destination] ?? 'it'}',
        ZenoActionType.search => 'Searching "${a.query}"',
        ZenoActionType.findForMe => 'Buying Agent: "${a.query}"',
        ZenoActionType.openChat => a.target == null
            ? 'Which chat?'
            : 'Chat with ${a.target!.firstName}',
        ZenoActionType.call => a.target == null
            ? 'Who should I call?'
            : '${a.video ? 'Video call' : 'Call'} ${a.target!.firstName}',
        ZenoActionType.guide => a.guide?.title ?? 'Guide',
      };

  static IconData icon(ZenoAction a) => switch (a.type) {
        ZenoActionType.navigate => switch (a.destination) {
            'home' => Icons.home_rounded,
            'inbox' => Icons.forum_rounded,
            'sell' => Icons.add_a_photo_rounded,
            'menu' => Icons.menu_rounded,
            'profile' => Icons.person_rounded,
            'settings' => Icons.settings_rounded,
            'search' => Icons.search_rounded,
            'buying_agent' => Icons.radar_rounded,
            'seller_dashboard' => Icons.storefront_rounded,
            'deal_history' => Icons.receipt_long_rounded,
            'verify' => Icons.verified_user_rounded,
            'market_insights' => Icons.insights_rounded,
            'store_setup' || 'my_store' => Icons.store_mall_directory_rounded,
            'start_selling' => Icons.sell_rounded,
            'escrow_services' => Icons.shield_rounded,
            _ => Icons.help_rounded,
          },
        ZenoActionType.search => Icons.search_rounded,
        ZenoActionType.findForMe => Icons.radar_rounded,
        ZenoActionType.openChat => Icons.chat_bubble_rounded,
        ZenoActionType.call => a.video ? Icons.videocam_rounded : Icons.call_rounded,
        ZenoActionType.guide => Icons.auto_awesome_rounded,
      };

  static IconData destinationIcon(String destination) =>
      icon(ZenoAction(type: ZenoActionType.navigate, destination: destination));

  /// Does [action]. Returns whether anything happened.
  ///
  /// Calls are refused here: they go through [call], from a button.
  static Future<bool> run(BuildContext context, ZenoAction action) =>
      runOn(Navigator.of(context), action);

  /// [run], on [nav]. With [replace], the screen opened takes the place of
  /// the top one instead of going on top of it: "open my dashboard", then
  /// "now my inbox", is one screen swapped for another, not a stack to back
  /// out of (zeno_session.dart decides when).
  static Future<bool> runOn(NavigatorState nav, ZenoAction action, {bool replace = false}) async {
    Future<void> push(Route<void> route) async {
      if (replace) {
        unawaited(nav.pushReplacement(route));
      } else {
        unawaited(nav.push(route));
      }
    }

    Future<void> pushNamed(String name, {Object? arguments}) async {
      if (replace) {
        unawaited(nav.pushReplacementNamed(name, arguments: arguments));
      } else {
        unawaited(nav.pushNamed(name, arguments: arguments));
      }
    }

    switch (action.type) {
      case ZenoActionType.navigate:
        final dest = action.destination;
        if (dest == 'home') {
          nav.popUntil((r) => r.isFirst);
          return true;
        }
        if (dest == 'search') {
          await push(MaterialPageRoute(builder: (_) => const ListingSearchScreen()));
          return true;
        }
        if (dest == 'buying_agent') {
          await push(MaterialPageRoute(builder: (_) => const ZenoScreen(mode: ZenoMode.buyingAgent)));
          return true;
        }
        if (!paymentsShown && paymentDestinations.contains(dest)) return false;
        final route = routes[dest];
        if (route == null) return false;
        await pushNamed(route);
        return true;
      case ZenoActionType.search:
        await push(MaterialPageRoute(builder: (_) => ListingSearchScreen(initialQuery: action.query)));
        return true;
      case ZenoActionType.findForMe:
        await push(MaterialPageRoute(
            builder: (_) => ZenoScreen(mode: ZenoMode.buyingAgent, initialQuery: action.query)));
        return true;
      case ZenoActionType.openChat:
        final c = action.target;
        if (c == null) return false;
        // The inbox's arguments, by id: the negotiation room loads the
        // listing itself (NegotiateScreen._restoreFromListingId).
        await pushNamed('/negotiate',
            arguments: {'listingId': c.listingId, 'role': c.role, 'buyer_id': c.buyerId});
        return true;
      case ZenoActionType.call:
      case ZenoActionType.guide:
        return false;
    }
  }

  /// A guide step's "Take me there".
  static Future<bool> openDestination(NavigatorState nav, String destination, {bool replace = false}) =>
      runOn(nav, ZenoAction(type: ZenoActionType.navigate, destination: destination), replace: replace);

  /// Places the call the user just confirmed.
  static Future<bool> call(BuildContext context, ZenoContact c, {required bool video}) =>
      callOn(Navigator.of(context), c, video: video);

  /// [call], on [nav].
  static Future<bool> callOn(NavigatorState nav, ZenoContact c, {required bool video}) async {
    final messenger = ScaffoldMessenger.maybeOf(nav.context);
    final info = await ApiService.initiateCall(
      listingId: c.listingId,
      listingName: c.listingName,
      callType: video ? 'video' : 'audio',
      // The seller has to say which buyer; a buyer's call goes to the
      // listing's seller (calls.py initiate_call).
      calleeId: c.role == 'seller' ? c.buyerId : null,
    );
    if (!nav.mounted) return false;
    if (info == null) {
      messenger?.showSnackBar(const SnackBar(content: Text("Couldn't start the call right now.")));
      return false;
    }
    final refused = info['refused'];
    if (refused is Map<String, dynamic>) {
      await NotificationService.instance.handleCallRefused(messenger, refused);
      return false;
    }
    unawaited(nav.pushNamed('/voip-call', arguments: {
      'roomId': info['room_id'],
      'userId': ApiService.currentUserId ?? '',
      'callToken': info['call_token'],
      'isCaller': true,
      'peerName': c.peerName,
      'peerId': c.peerId,
      'listingName': c.listingName,
      'listingId': c.listingId,
      'buyerId': c.buyerId,
      'callerRole': c.role,
      'callType': video ? 'video' : 'audio',
    }));
    return true;
  }
}
