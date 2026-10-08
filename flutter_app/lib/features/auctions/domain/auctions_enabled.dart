// Whether this build offers auctions (2026-10-08: off for launch).
//
// A winning bid is paid through BROKA's own escrow, and BROKA holds no
// payments for launch - no outside escrow service takes a bid's money or
// closes an auction. So auctions are out of sight, not deleted: the Auction
// House, the bid screen and every auction widget stay in the app, and
// nothing leads to them. The server refuses them too (backend
// AUCTIONS_ENABLED, api/domains/auctions/paused.py), so an older build that
// still offers "Auction" is told why instead of posting a listing nobody
// can see.
//
// To bring them back: switch the server on, then build with
// --dart-define=AUCTIONS_ENABLED=true.
const bool kAuctionsEnabled = bool.fromEnvironment('AUCTIONS_ENABLED', defaultValue: false);
