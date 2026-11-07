import 'package:flutter/widgets.dart';

/// Tells a screen when the user came back to it (RouteAware.didPopNext) -
/// whichever way they left: the bottom nav, a notification tap that pushed a
/// chat over it, a deep link. Home uses it to decide whether anything it
/// shows needs refreshing, instead of refetching on every return.
final RouteObserver<ModalRoute<void>> appRouteObserver = RouteObserver<ModalRoute<void>>();
