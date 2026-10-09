// Whether this build shows payments (2026-10-09: off for now).
//
// BROKA takes no deal payments (the server's IN_APP_PAYMENTS_ENABLED is
// off) and stopped selling the Verified badge (VERIFIED_BADGE_ENABLED). The
// "Pay with escrow" callouts, the Home pill, the pay buttons in both chats,
// the cart's escrow note, the Menu's escrow and receipts rows, Zeno's
// "Help me pay with escrow" opener and Profile's "Get verified" were all
// asking people to pay for something, everywhere, while there was nothing
// to pay BROKA for. They are out of sight, not deleted: the screens stay,
// and nothing leads to them.
//
// A deal already paid through BROKA's escrow still shows its release,
// refund and dispute steps: that money is real and has to finish.
//
// To bring them back: build with --dart-define=PAYMENTS_SHOWN=true (and turn
// the server's switches back on for what should be sold again).

/// Read by every screen that leads to a payment. Not const only so a test
/// can switch the hidden screens back on and keep checking them; the app
/// never writes it.
bool paymentsShown = const bool.fromEnvironment('PAYMENTS_SHOWN', defaultValue: false);
