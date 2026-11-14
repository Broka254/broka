// A call kept going while its screen is out of the way - WhatsApp's
// "minimise" (the arrows at the top left of its call screen).
//
// The call screen owned the call (its State holds the WebRtcService, the
// timers, the ring), so leaving the screen ended the call: Back hung up, and
// there was no way to check a listing or the chat while talking. Now the
// screen's minimise button - and Back - hands the very same call widget,
// State and all, to CallDockHost, which shows it as a small pill over every
// screen. Tapping the pill opens the call screen again with that widget in
// it. Nothing about the call is rebuilt on either move: the widget carries
// a GlobalKey, and Flutter moves its element between the two places within
// one frame.
//
// One call at a time, as ActiveCall already insists.
import 'package:flutter/widgets.dart';

class CallDock extends ChangeNotifier {
  CallDock._();
  static final CallDock instance = CallDock._();

  /// The call widget the pill is showing, or the one on its way back into
  /// the call screen ([_handingBack]).
  Widget? _docked;
  bool _handingBack = false;
  NavigatorState? _navigator;

  /// A CallDockHost is in the tree: without one there is nowhere to put the
  /// call, and minimising is not offered (widget tests that open the call
  /// screen alone).
  int _hosts = 0;
  bool get hostReady => _hosts > 0;

  /// A call is minimised to the pill.
  bool get hasCall => _docked != null && !_handingBack;

  /// What the pill draws - null while nothing is minimised, and during the
  /// one frame a call moves back to its screen.
  Widget? get pill => _handingBack ? null : _docked;

  /// Whether [call] is the call the pill holds: its old screen must stop
  /// drawing it then, or it would be in two places.
  bool holds(Widget call) => identical(_docked, call) && !_handingBack;

  void attachHost() => _hosts++;
  void detachHost() => _hosts = _hosts > 0 ? _hosts - 1 : 0;

  /// The call screen's minimise: [call] goes to the pill. [navigator] is
  /// where its screen opens again.
  void dock(Widget call, NavigatorState navigator) {
    _docked = call;
    _handingBack = false;
    _navigator = navigator;
    notifyListeners();
  }

  /// The pill's tap: the call screen opens again with this call in it.
  /// False when there is no call, or nowhere to open it.
  bool expand() {
    final nav = _navigator;
    if (_docked == null || _handingBack || nav == null || !nav.mounted) return false;
    _handingBack = true;
    // The pill lets go of the call in the same frame as the new screen
    // takes it (VoipCallScreen's initState, via takeBack).
    notifyListeners();
    nav.pushNamed('/voip-call', arguments: const {resumeArg: true});
    return true;
  }

  /// The call screen opening: the minimised call, when [expand] sent it.
  Widget? takeBack() {
    if (!_handingBack) return null;
    final call = _docked;
    _docked = null;
    _handingBack = false;
    return call;
  }

  /// The call is over while minimised: the pill goes, and the call widget
  /// with it - its dispose ends what is left of the call.
  void release(Widget call) {
    if (!identical(_docked, call)) return;
    _docked = null;
    _handingBack = false;
    notifyListeners();
  }

  /// [call] was disposed: forget it without a word. Listeners can't be
  /// told while the tree is being torn down, and nothing is left to draw.
  void forget(Widget call) {
    if (!identical(_docked, call)) return;
    _docked = null;
    _handingBack = false;
  }

  /// The argument the pill's tap opens '/voip-call' with.
  static const resumeArg = 'resumeDockedCall';

  @visibleForTesting
  void reset() {
    _docked = null;
    _handingBack = false;
    _navigator = null;
    _hosts = 0;
  }
}
